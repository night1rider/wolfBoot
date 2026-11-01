/*OSPI_TEST_CORE_BEGIN*/

/* Forward declaration for the delay helper (defined below on target,
 * provided by the test harness on the host). */
void hal_delay_us(uint32_t us);

/* Timeout for a STIG command (plain spin; the QEMU model and real
 * hardware both complete a STIG burst in far fewer iterations). */
#ifndef OSPI_STIG_TIMEOUT
#define OSPI_STIG_TIMEOUT         100000000
#endif
/* Budget for a flash operation (erase) to complete: iterations of a
 * 1 us delay. The MT35XU02GCBA worst cases (datasheet Table 48, p74-75):
 * tSE 128 KB erase <= 1 s, tSSE 32 KB <= 1 s, tSSE 4 KB <= 400 ms,
 * tPP page program <= 1.8 ms. 60 s covers the slowest documented erase
 * with a wide margin. */
#ifndef OSPI_WAIT_READY_TIMEOUT
#define OSPI_WAIT_READY_TIMEOUT   60000000
#endif
/* Budget for a DMA read transfer to complete (1 us delay iterations). */
#ifndef OSPI_DMA_TIMEOUT
#define OSPI_DMA_TIMEOUT          60000000
#endif
/* NOR page program size (MT35XU02G): 256 bytes (datasheet Table 21:
 * PAGE PROGRAM "1 to 256" bytes; AM028 dev_size bytes_per_device_page).
 * Erase granularities are 4 KB / 32 KB / 128 KB - the device has no
 * 64 KB erase (0xDC is the 128 KB sector erase). */
#define OSPI_FLASH_PAGE_SIZE      256
#define OSPI_ERASE_4K             0x1000
#define OSPI_ERASE_32K            0x8000
#define OSPI_ERASE_128K           0x20000

/* Opcode allow-list (task list, section 6): the only opcodes the STIG
 * function may issue. Anything not listed here - including every
 * non-volatile protect/pin/lock/config opcode - is refused. */
static const uint8_t ospi_op_allowed_list[] = {
    /* read ID */
    0x9F, 0x9E,
    /* status / flag status */
    0x05, 0x70, 0x50,
    /* write enable / disable */
    0x06, 0x04,
    /* read (3- and 4-byte address families) */
    0x03, 0x0B, 0x13, 0x0C, 0x7C, 0xCC, 0x8B, 0xCB, 0xFD,
    /* page program */
    0x02, 0x12, 0x82, 0x84, 0xC2, 0x8E,
    /* erase (4 KB / 32 KB / 128 KB, 3- and 4-byte address) */
    0x20, 0x21, 0x52, 0x5C, 0xD8, 0xDC,
    /* 4-byte address mode */
    0xB7, 0xE9,
    /* volatile configuration */
    0x81, 0x85,
    /* reset enable / reset */
    0x66, 0x99,
    /* SFDP */
    0x5A,
};

static int ospi_op_allowed(uint8_t opcode)
{
    int i;

    for (i = 0; i < (int)(sizeof(ospi_op_allowed_list) /
                         sizeof(ospi_op_allowed_list[0])); i++) {
        if (ospi_op_allowed_list[i] == opcode)
            return 1;
    }
    return 0;
}

/* Address guard: only the wolfBoot partitions may be programmed or
 * erased. The range [addr, addr+len) must lie completely inside one of
 * them, so neither AMD's Image Selector / Image Recovery / metadata
 * areas (0x000000-0x015BFFFF), the BOOT.BIN reservation at the start of
 * Bank A (0x015C0000-0x01DBFFFF; run 13 layout decision - the partition
 * start addresses are set by the config, so the reservation is refused
 * simply by not being inside a partition), Bank B, nor the tail past
 * the end of a partition can be touched. The SWAP partition size is the
 * config's WOLFBOOT_SECTOR_SIZE; it is a variable (initialized to that
 * value) so the host unit test can exercise a smaller sector geometry at
 * run time (WOLFBOOT_SECTOR_SIZE=0x400, as `make run` does for all unit
 * tests). Target behavior is unchanged. */
static uint32_t ospi_swap_size = (uint32_t)WOLFBOOT_SECTOR_SIZE;
static int ospi_range_in_partition(uint32_t base, uint32_t size,
                                   uint32_t addr, uint32_t len)
{
    uint32_t end;

    if (len == 0)
        return 0;
    /* base + size must not wrap. */
    if (size > UINT32_MAX - base)
        return 0;
    end = base + size;
    /* The whole range [addr, addr+len) must sit inside [base, end).
     * Check the start against both ends first so the final compare
     * (end - addr) cannot underflow. */
    if (addr < base)
        return 0;
    if (addr > end)
        return 0;
    if (len > end - addr)
        return 0;
    return 1;
}

static int ospi_addr_guard_ok(uint32_t addr, uint32_t len)
{
    if (ospi_range_in_partition((uint32_t)WOLFBOOT_PARTITION_BOOT_ADDRESS,
                                (uint32_t)WOLFBOOT_PARTITION_SIZE, addr, len))
        return 1;
#ifdef WOLFBOOT_PARTITION_UPDATE_ADDRESS
    if (WOLFBOOT_PARTITION_UPDATE_ADDRESS != 0 &&
        ospi_range_in_partition((uint32_t)WOLFBOOT_PARTITION_UPDATE_ADDRESS,
                                (uint32_t)WOLFBOOT_PARTITION_SIZE, addr, len))
        return 1;
#endif
#ifdef WOLFBOOT_PARTITION_SWAP_ADDRESS
    if (WOLFBOOT_PARTITION_SWAP_ADDRESS != 0 &&
        ospi_range_in_partition((uint32_t)WOLFBOOT_PARTITION_SWAP_ADDRESS,
                                ospi_swap_size, addr, len))
        return 1;
#endif
    return 0;
}

/* Size in flash bytes of the region an erase opcode covers (Micron
 * MT35XU02GCBA, Table 21): 4 KB / 32 KB subsector and 128 KB sector.
 * Both the 3-byte (20h/52h/D8h) and 4-byte (21h/5Ch/DCh) forms erase the
 * same sizes. */
static uint32_t ospi_erase_op_size(uint8_t opcode)
{
    switch (opcode) {
        case 0x20: case 0x21:
            return OSPI_ERASE_4K;
        case 0x52: case 0x5C:
            return OSPI_ERASE_32K;
        case 0xD8: case 0xDC:
            return OSPI_ERASE_128K;
        default:
            return 0;
    }
}

/* Page program opcodes (write data at the given address). */
static int ospi_op_is_program(uint8_t opcode)
{
    switch (opcode) {
        case 0x02: case 0x12: case 0x82: case 0x84:
        case 0xC2: case 0x8E:
            return 1;
        default:
            return 0;
    }
}

/*
 * Issue one STIG (single-trigger) flash command.
 *
 * opcode  SPI opcode (must be in the allow-list)
 * addr    flash address (4-byte addressed device)
 * naddr   number of address bytes sent (0 for address-less commands)
 * wdata   write data, up to 8 bytes (STIG limit)
 * rdata   read data, up to 8 bytes
 *
 * Program and erase commands are additionally checked against the
 * address guard. Returns 0 on success, -1 on refusal or timeout.
 */
static int ospi_stig(uint8_t opcode, uint32_t addr, int naddr,
                     const uint8_t *wdata, int wlen,
                     uint8_t *rdata, int rlen)
{
    uint32_t ctrl = (uint32_t)opcode << OSPI_FCC_CMD_OPCODE_SHIFT;
    uint32_t span;
    int timeout;

    if (ospi_op_allowed(opcode) == 0)
        return -1;
    if (naddr < 0 || naddr > OSPI_STIG_MAX_ADDR_BYTES)
        return -1;
    if (wlen < 0 || wlen > OSPI_STIG_MAX_WR_DATA_BYTES)
        return -1;
    if (rlen < 0 || rlen > OSPI_STIG_MAX_RD_DATA_BYTES)
        return -1;

    /* Guard the region this command would modify. Erase opcodes modify
     * a fixed-size region; program opcodes modify the write data range. */
    span = ospi_erase_op_size(opcode);
    if (span == 0 && ospi_op_is_program(opcode)) {
        span = (wlen > 0) ? (uint32_t)wlen : 1;
        if (span > (uint32_t)(OSPI_FLASH_PAGE_SIZE - (addr % OSPI_FLASH_PAGE_SIZE)))
            return -1;   /* page program must not cross a page */
    }
    if (span != 0 && ospi_addr_guard_ok(addr, span) == 0)
        return -1;

    if (naddr > 0) {
        ctrl |= OSPI_FCC_ENB_COMD_ADDR;
        ctrl |= ((uint32_t)(naddr - 1) << OSPI_FCC_NUM_ADDR_BYTES_SHIFT);
    }
    if (wlen > 0) {
        ctrl |= OSPI_FCC_ENB_WRITE_DATA;
        ctrl |= ((uint32_t)(wlen - 1) << OSPI_FCC_NUM_WR_DATA_BYTES_SHIFT);
        if (wdata == NULL)
            return -1;
    }
    if (rlen > 0) {
        ctrl |= OSPI_FCC_ENB_READ_DATA;
        ctrl |= ((uint32_t)(rlen - 1) << OSPI_FCC_NUM_RD_DATA_BYTES_SHIFT);
        if (rdata == NULL)
            return -1;
    }

    ospi_reg_write(OSPI_R_FLASH_CMD_ADDR_REG, addr);
    if (wlen > 0) {
        uint32_t lo = 0, hi = 0;
        int i;

        for (i = 0; i < wlen && i < 4; i++)
            lo |= (uint32_t)wdata[i] << (8 * i);
        for (i = 4; i < wlen; i++)
            hi |= (uint32_t)wdata[i] << (8 * (i - 4));
        ospi_reg_write(OSPI_R_FLASH_WR_DATA_LOWER_REG, lo);
        if (wlen > 4)
            ospi_reg_write(OSPI_R_FLASH_WR_DATA_UPPER_REG, hi);
    }
    ospi_reg_write(OSPI_R_FLASH_CMD_CTRL_REG, ctrl | OSPI_FCC_CMD_EXEC);

    timeout = OSPI_STIG_TIMEOUT;
    while ((ospi_reg_read(OSPI_R_FLASH_CMD_CTRL_REG) &
            OSPI_FCC_CMD_EXEC_STATUS) != 0) {
        if (timeout-- == 0)
            return -1;
    }

    if (rlen > 0) {
        uint64_t v = (uint64_t)ospi_reg_read(OSPI_R_FLASH_RD_DATA_LOWER_REG);

        v |= (uint64_t)ospi_reg_read(OSPI_R_FLASH_RD_DATA_UPPER_REG) << 32;
        {
            int i;

            for (i = 0; i < rlen; i++)
                rdata[i] = (uint8_t)(v >> (8 * i));
        }
    }
    return 0;
}

/* Wait until the flash reports ready (flag status register, bit 7). */
static int ospi_wait_ready(void)
{
    int timeout = OSPI_WAIT_READY_TIMEOUT;
    uint8_t st;

    while (timeout > 0) {
        if (ospi_stig(0x70, 0, 0, NULL, 0, &st, 1) != 0)
            return -1;
        if (st & OSPI_FLAG_STATUS_READY)
            return 0;
        hal_delay_us(1);
        timeout--;
    }
    return -1;
}

/* Program up to one 256-byte NOR page. The caller must not cross a page
 * boundary. Each 8-byte STIG burst is a separate PP command, so the
 * write enable is issued before every burst. */
static int ospi_page_program(uint32_t addr, const uint8_t *data, int len)
{
    int off;

    if (data == NULL || len <= 0 || len > OSPI_FLASH_PAGE_SIZE)
        return -1;
    if ((addr % OSPI_FLASH_PAGE_SIZE) + (uint32_t)len > OSPI_FLASH_PAGE_SIZE)
        return -1;

    for (off = 0; off < len; off += OSPI_STIG_MAX_WR_DATA_BYTES) {
        int n = len - off;

        if (n > OSPI_STIG_MAX_WR_DATA_BYTES)
            n = OSPI_STIG_MAX_WR_DATA_BYTES;
        if (ospi_stig(0x06, 0, 0, NULL, 0, NULL, 0) != 0)
            return -1;
        if (ospi_stig(0x12, addr + (uint32_t)off, 4,
                      data + off, n, NULL, 0) != 0)
            return -1;
    }
    return ospi_wait_ready();
}

/* Erase one 4 KB / 32 KB / 128 KB region with the matching native
 * 4-byte erase opcode. */
static int ospi_erase_region(uint32_t addr, uint32_t len)
{
    uint8_t opcode;

    switch (len) {
        case OSPI_ERASE_4K:
            opcode = 0x21;
            break;
        case OSPI_ERASE_32K:
            opcode = 0x5C;
            break;
        case OSPI_ERASE_128K:
            opcode = 0xDC;
            break;
        default:
            return -1;
    }
    if (addr % len != 0)
        return -1;

    if (ospi_stig(0x06, 0, 0, NULL, 0, NULL, 0) != 0)
        return -1;
    if (ospi_stig(opcode, addr, 4, NULL, 0, NULL, 0) != 0)
        return -1;
    return ospi_wait_ready();
}

/* Read the 3-byte JEDEC ID (READ ID 9Fh; datasheet Table 18/23,
 * p29-30, 37). A device that is busy or in an unknown I/O mode does not
 * decode the command (datasheet p37), so the caller treats a failure as
 * "mode unknown" and falls back to a reset. */
static int ospi_read_jedec_id(uint8_t id[3])
{
    uint8_t raw[4];

    if (id == NULL)
        return -1;
    memset(raw, 0, sizeof(raw));
    if (ospi_stig(0x9F, 0, 0, NULL, 0, raw, 4) != 0)
        return -1;
    id[0] = raw[0];
    id[1] = raw[1];
    id[2] = raw[2];
    return 0;
}

/* Volatile reset: return the flash to its power-on default mode
 * (1-bit SDR Extended SPI, 3-byte addressing; datasheet p36:
 * RESET ENABLE 66h followed by RESET MEMORY 99h). The native 4-byte
 * opcodes used by this driver then work regardless of the state the PLM
 * left the flash in. */
static int ospi_flash_reset(void)
{
    if (ospi_stig(0x66, 0, 0, NULL, 0, NULL, 0) != 0)
        return -1;
    if (ospi_stig(0x99, 0, 0, NULL, 0, NULL, 0) != 0)
        return -1;
    return ospi_wait_ready();
}

/* Explicitly set 1-bit SDR (Extended SPI) mode with the VOLATILE
 * configuration register only (WRITE VOLATILE CONFIG 81h; datasheet
 * Table 7, p21: register 0x00 = I/O mode, 0xFF = Extended SPI). The
 * nonvolatile form (B1h) is never used. Register 0x05 (4-byte
 * addressing) is left at its POR value: the driver's native 4-byte
 * opcodes do not depend on it. */
static int ospi_flash_set_1bit_sdr_volatile(void)
{
    uint8_t wdata[4];

    /* 81h WRITE VOLATILE CONFIGURATION REGISTER (datasheet Figure 21):
     * opcode + 4-byte address + data. The least-significant address byte
     * selects the configuration register (Table 7) and the first data
     * byte carries its value; the remaining data bytes are padding
     * (reserved registers are not affected). I/O mode register 00h =
     * FFh selects Extended SPI (1-bit SDR), the power-on default, from
     * which the 9Fh ID read is guaranteed to work. */
    wdata[0] = OSPI_VCFG_VAL_EXT_SPI_1BIT;
    wdata[1] = 0xFF;   /* padding */
    wdata[2] = 0xFF;
    wdata[3] = 0xFF;
    if (ospi_stig(0x06, 0, 0, NULL, 0, NULL, 0) != 0)
        return -1;
    if (ospi_stig(0x81, OSPI_VCFG_ADDR_IO_MODE, 4, wdata, 4, NULL, 0) != 0)
        return -1;
    return ospi_wait_ready();
}

/* Flash mode detection (plan Q4 / datasheet p36-37): try to read the ID
 * in the mode the flash is currently in; on failure, reset the device to
 * its power-on default and explicitly force 1-bit SDR with the volatile
 * configuration register only, then read the ID again. Returns 0 with
 * id[] valid, or -1 when no flash answers at all. */
static int ospi_flash_mode_detect(uint8_t id[3])
{
    int ok;

    if (id == NULL)
        return -1;

    /* Attempt 1: the flash answers in the mode it is left in. */
    if (ospi_read_jedec_id(id) == 0 &&
        !(id[0] == 0x00 && id[1] == 0x00 && id[2] == 0x00) &&
        !(id[0] == 0xFF && id[1] == 0xFF && id[2] == 0xFF))
        return 0;

    /* Attempt 2: back to a known volatile mode, then identify. */
    ok = ospi_flash_reset();
    if (ospi_flash_set_1bit_sdr_volatile() != 0)
        ok = -1;
    if (ospi_read_jedec_id(id) == 0 &&
        !(id[0] == 0x00 && id[1] == 0x00 && id[2] == 0x00) &&
        !(id[0] == 0xFF && id[1] == 0xFF && id[2] == 0xFF))
        return (ok == 0) ? 0 : 1;   /* 1 = detected, but reset misbehaved */
    return -1;
}

#ifdef WOLFBOOT_OSPI_DMA
/*
 * DMA read path (AM026 p706-709, "DMA Programming Model"; identical
 * register sequence to the AMD xospipsv driver, XOspiPsv_Dma_Read /
 * Config_Dma / Config_IndirectAhb). Flash -> SRC DMA -> internal SRAM ->
 * DST DMA -> system memory; the transfer is word-aligned on both ends
 * and completes when the DST channel's DONE (bit 1) is set (W1C).
 *
 * Note on DST_SIZE: AM026 p707 says "number of words", but the xospipsv
 * driver and the QEMU CSU DMA model both program it in bytes; this
 * driver follows the driver + model (bytes).
 */
static int ospi_dma_read(uint32_t addr, uint8_t *buf, int len)
{
    uint64_t dst;
    int timeout;
    uint32_t sts;

    if (buf == NULL || len <= 0)
        return -1;
    /* DMA start address 4-byte aligned, length in 4-byte words (AM026
     * p706-707, xospipsv). */
    if ((addr & 3) != 0 || ((uint32_t)len & 3) != 0)
        return -1;

    dst = (uint64_t)(uintptr_t)buf;

    /* Enable the DMA interface (CONFIG bit 15, AM028 CONFIG register).
     * On the board the PLM leaves the OSPI configured at boot and the
     * read-modify-write is a no-op; QEMU has no PLM, so without this
     * the model never moves the indirect-read data to the DMA engine
     * and the transfer times out (verified in run 2, Q4 DMA probe). */
    ospi_reg_write(OSPI_R_CONFIG,
                   ospi_reg_read(OSPI_R_CONFIG) | OSPI_CFG_ENB_DMA_IF);

    /* One-shot DMA configuration (values from AM026 Table 223 and
     * xospipsv_hw.h). */
    ospi_reg_write(OSPI_R_DMA_PERIPH_CONFIG_REG, OSPI_DMA_PERIPH_CFG_64B_4B);
    ospi_reg_write(OSPI_R_SRAM_PARTITION_CFG_REG, OSPI_SRAM_PARTITION_DMA_READ);
    ospi_reg_write(OSPI_R_IND_RD_XFER_WATERMARK_REG, 0);

    /* DST channel: destination in system memory (word aligned). */
    ospi_reg_write(OSPI_R_DMA_DST_ADDR, (uint32_t)dst);
    ospi_reg_write(OSPI_R_DMA_DST_ADDR_MSB, (uint32_t)(dst >> 32));
    ospi_reg_write(OSPI_R_DMA_SRC_RD_ADDR, OSPI_IND_AHB_TRIG_BASE);
    ospi_reg_write(OSPI_R_DMA_DST_CTRL, OSPI_DMA_DST_CTRL_DEF);

    /* Indirect read setup: flash address + byte count, AHB trigger range
     * (64-byte fixed SRC burst, no 4 KB boundary crossing at the DAC
     * base). */
    ospi_reg_write(OSPI_R_IND_AHB_ADDR_TRIG_REG, OSPI_IND_AHB_TRIG_BASE);
    ospi_reg_write(OSPI_R_IND_TRIG_ADDR_RANGE_REG, OSPI_IND_TRIG_RANGE_64B);
    ospi_reg_write(OSPI_R_IND_RD_XFER_START_REG, addr);
    ospi_reg_write(OSPI_R_IND_RD_XFER_NUM_BYTES_REG, (uint32_t)len);

    /* Writing the DST size starts the transfer (xospipsv order); then
     * trigger the indirect read. */
    ospi_reg_write(OSPI_R_DMA_DST_SIZE, (uint32_t)len);
    ospi_reg_write(OSPI_R_IND_RD_XFER_CTRL_REG, OSPI_IND_RD_START);

    /* Wait for the DST channel to report DONE (bit 1), then clear it.
     * Any error bit (BRESP/timeout/overflow) fails the transfer. */
    timeout = OSPI_DMA_TIMEOUT;
    while (timeout > 0) {
        sts = ospi_reg_read(OSPI_R_DMA_DST_I_STS);
        if (sts & OSPI_DMA_DST_I_STS_DONE)
            break;
        if (sts & ((uint32_t)(OSPI_DMA_DST_I_STS_AXI_BRESP_ERR | \
                              OSPI_DMA_DST_I_STS_TIMEOUT_STRM | \
                              OSPI_DMA_DST_I_STS_TIMEOUT_MEM | \
                              OSPI_DMA_DST_I_STS_FIFO_OVERFLOW)))
            return -1;
        hal_delay_us(1);
        timeout--;
    }
    if (timeout == 0)
        return -1;
    ospi_reg_write(OSPI_R_DMA_DST_I_STS, sts);   /* W1C */
    return 0;
}
#endif /* WOLFBOOT_OSPI_DMA */

/* Public EXT_FLASH API (A/B boot over OSPI). Included in the testable
 * core so the host unit tests drive the real write/erase paths against
 * the emulated flash. */
int ext_flash_read(uintptr_t address, uint8_t *data, int len)
{
    uint32_t addr = (uint32_t)address;
    int off;

    if (data == NULL || len <= 0)
        return 0;

#ifdef WOLFBOOT_OSPI_DMA
    /* DMA path (off by default; see the file header and BUILD.md):
     * one word-aligned transfer for the whole request. */
    if (((uintptr_t)address & 3) == 0 && ((uintptr_t)len & 3) == 0) {
        if (ospi_dma_read(addr, data, len) == 0)
            return len;
        return -1;   /* no silent fallback: a broken DMA must be visible */
    }
#endif

    for (off = 0; off < len; off += OSPI_STIG_MAX_RD_DATA_BYTES) {
        int n = len - off;

        if (n > OSPI_STIG_MAX_RD_DATA_BYTES)
            n = OSPI_STIG_MAX_RD_DATA_BYTES;
        if (ospi_stig(0x13, addr + (uint32_t)off, 4, NULL, 0,
                      data + off, n) != 0)
            return -1;
    }
    return len;
}

int ext_flash_write(uintptr_t address, const uint8_t *data, int len)
{
    uint32_t addr = (uint32_t)address;
    int off;

    if (data == NULL || len <= 0)
        return 0;

    /* Split at 256-byte NOR page boundaries; a page program must never
     * cross one (the flash write pointer wraps at the page end). */
    off = 0;
    while (off < len) {
        uint32_t in_page = OSPI_FLASH_PAGE_SIZE - (addr % OSPI_FLASH_PAGE_SIZE);
        int chunk = len - off;

        if (chunk > (int)in_page)
            chunk = (int)in_page;
        if (ospi_page_program(addr + (uint32_t)off, data + off, chunk) != 0)
            return -1;
        off += chunk;
    }
    return len;
}

int ext_flash_erase(uintptr_t address, int len)
{
    uint32_t addr = (uint32_t)address;
    uint32_t total = (uint32_t)len;

    if (len <= 0)
        return 0;
    if (addr % OSPI_ERASE_4K != 0 || total % OSPI_ERASE_4K != 0)
        return -1;

    while (total > 0) {
        uint32_t chunk;

        /* Erase with the largest granularity the device supports that
         * the remaining length still divides by and the current address
         * is aligned to: 128 KB sector (0xDC), 32 KB (0x5C), 4 KB
         * (0x21). The MT35XU02GCBA has no 64 KB erase. */
        if ((addr % OSPI_ERASE_128K) == 0 && total >= OSPI_ERASE_128K &&
                (total % OSPI_ERASE_128K) == 0)
            chunk = OSPI_ERASE_128K;
        else if ((addr % OSPI_ERASE_32K) == 0 && total >= OSPI_ERASE_32K &&
                (total % OSPI_ERASE_32K) == 0)
            chunk = OSPI_ERASE_32K;
        else
            chunk = OSPI_ERASE_4K;
        if (ospi_erase_region(addr, chunk) != 0)
            return -1;
        addr += chunk;
        total -= chunk;
    }
    return len;
}

/*OSPI_TEST_CORE_END*/
