/* ospi_tool.c
 *
 * Board OSPI tool (VEK385), run by BL31 in place of wolfBoot: OT_MODE_SCAN,
 * MAP (read only) or WRITE, through hal/wolfhal.c. Ends with "OT-DONE rc=n".
 *
 * Copyright (C) 2026 wolfSSL Inc.
 *
 * This file is part of wolfBoot.
 *
 * wolfBoot is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * wolfBoot is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335, USA
 */

#include <stdint.h>
#include <string.h>

#include "versal2.h"
#include "wolfHAL_board.h"
#include "aarch64_arch.h"
#include <wolfHAL/wolfHAL.h>
#include <wolfHAL/platform/amd/versal2.h>
#include <wolfHAL/flash/spimem_nor_flash.h>
#include <wolfHAL/spimem/versal2_ospi_dma.h>

/* Partition layout. Must match config/examples/versal2_vek385.config. */
#define WOLFBOOT_PARTITION_BOOT_ADDRESS   0x1DC0000UL
#define WOLFBOOT_PARTITION_UPDATE_ADDRESS 0x49C0000UL
#define WOLFBOOT_PARTITION_SWAP_ADDRESS   0xFA40000UL
#define WOLFBOOT_PARTITION_SIZE           0x2C00000UL
#define WOLFBOOT_SECTOR_SIZE              0x20000UL
#define WOLFBOOT_DTS_BOOT_ADDRESS         0x7600000UL
#define WOLFBOOT_DTS_UPDATE_ADDRESS       0x7E00000UL
#define OT_DTS_SIZE                       0x100000UL

/* Signed image header (IMAGE_HEADER_SIZE=512 in the config). */
#define OT_IMAGE_HEADER_SIZE 512
#define OT_WOLFBOOT_MAGIC    0x464C4F57UL /* "WOLF" */

#ifndef OT_SRC
#define OT_SRC 0x30000000UL
#endif

#define OT_CHUNK 0x10000 /* 64 KB per read */

/* Real timing from the generic timer, as in the board file: the flash
 * timeouts (erase up to seconds) depend on it. */
void hal_delay_us(uint32_t us)
{
    uint64_t deadline = timer_deadline_us(us);

    while (!timer_expired(deadline)) {
    }
}

/* Our own memset, memcpy and memcmp, since there is no C library here. */
void *memset(void *dst, int c, unsigned long n)
{
    uint8_t *d = dst;

    while (n-- > 0) {
        *d++ = (uint8_t)c;
    }
    return dst;
}

void *memcpy(void *dst, const void *src, unsigned long n)
{
    uint8_t *d = dst;
    const uint8_t *s = src;

    while (n-- > 0) {
        *d++ = *s++;
    }
    return dst;
}

int memcmp(const void *a, const void *b, unsigned long n)
{
    const uint8_t *x = a, *y = b;

    while (n-- > 0) {
        if (*x != *y) {
            return (int)*x - (int)*y;
        }
        x++;
        y++;
    }
    return 0;
}

/* wolfHAL timeout tick: the generic timer in microseconds. */
static uint32_t ot_tick_us(void)
{
    return (uint32_t)((timer_get_count() * 1000000ULL) / timer_get_freq());
}

static whal_Timeout ot_uart_timeout = { 1000000U, 0, ot_tick_us };
static whal_Timeout ot_ospi_timeout = { 1000000U, 0, ot_tick_us };
static whal_Timeout ot_flash_timeout = { 60000000U, 0, ot_tick_us };

/* UART1 on the wolfHAL PL011 driver, set up as in hal/boards/vek385. */
static whal_Pl011_Uart_Cfg ot_uart_cfg = {
    WHAL_PL011_UART_IBRD(DEBUG_UART_CLK_HZ, DEBUG_UART_BAUD),
    WHAL_PL011_UART_FBRD(DEBUG_UART_CLK_HZ, DEBUG_UART_BAUD),
    WHAL_PL011_UART_LCRH_8N1_FIFO,
    &ot_uart_timeout
};
static whal_Uart ot_uart = {
    WHAL_VERSAL2_UART1_BASE, WHAL_VERSAL2_UART_DRIVER, &ot_uart_cfg
};

#ifdef WOLFBOOT_OSPI_DMA
/* Cache upkeep around the DMA read, like in the board file. */
static void ot_dcache_clean_inval(void *buf, size_t len)
{
    uintptr_t addr = (uintptr_t)buf;
    uintptr_t p = addr & ~(uintptr_t)(CACHE_LINE_SIZE - 1);

    for (; p < addr + len; p += CACHE_LINE_SIZE) {
        __asm__ volatile("dc civac, %0" : : "r"(p) : "memory");
    }
    __asm__ volatile("dsb sy" : : : "memory");
}

static void ot_dcache_inval(void *buf, size_t len)
{
    uintptr_t addr = (uintptr_t)buf;
    uintptr_t p = addr & ~(uintptr_t)(CACHE_LINE_SIZE - 1);

    for (; p < addr + len; p += CACHE_LINE_SIZE) {
        __asm__ volatile("dc ivac, %0" : : "r"(p) : "memory");
    }
    __asm__ volatile("dsb sy" : : : "memory");
}

static whal_Timeout ot_dma_timeout = { 60000000U, 0, ot_tick_us };
static whal_Versal2_OspiDma_Ctx ot_dma_ctx = {
    WHAL_VERSAL2_OSPI_BASE,
    WHAL_VERSAL2_OSPI_DMA_SRC_RD_ADDR,
    WHAL_VERSAL2_OSPI_DMA_DST_CTRL,
    ot_dcache_clean_inval,
    ot_dcache_inval,
    &ot_dma_timeout
};
static const whal_CadenceOspi_SpiMem_Dma ot_dma = {
    whal_Versal2_OspiDma_Arm, whal_Versal2_OspiDma_Wait, &ot_dma_ctx,
    CACHE_LINE_SIZE
};
#define OT_DMA_HOOK (&ot_dma)
#else
#define OT_DMA_HOOK NULL
#endif

/* The flash devices, set up as in hal/boards/vek385. */
static whal_CadenceOspi_SpiMem_Cfg ot_ospi_cfg = {
    WHAL_VERSAL2_OSPI_DEV_SIZE_VEK385,
    VERSAL2_OSPI_BAUD_DIV_32,
    VERSAL2_OSPI_CS_LINES,
    VERSAL2_OSPI_RD_CAPTURE,
    WHAL_VERSAL2_OSPI_IND_TRIG_BASE,
    WHAL_VERSAL2_OSPI_IND_TRIG_RANGE,
    WHAL_VERSAL2_OSPI_SRAM_PARTITION,
    WHAL_VERSAL2_OSPI_DMA_PERIPH_CFG,
    OT_DMA_HOOK,
    &ot_ospi_timeout
};
static whal_SpiMem versal2_ospi = {
    WHAL_VERSAL2_OSPI_BASE, WHAL_VERSAL2_OSPI_DRIVER, &ot_ospi_cfg
};
static whal_SpiMemNor_Flash_Cfg ot_flash_cfg = {
    &versal2_ospi, 0x10000000, 256, 0x20000, 4,
    OSPI_OP_READ4, 0, OSPI_OP_PAGE_PROGRAM4, OSPI_OP_ERASE4_128K,
    WHAL_SPIMEM_NOR_FLAG_FSR | WHAL_SPIMEM_NOR_FLAG_RESET |
        WHAL_SPIMEM_NOR_FLAG_RESET_OCTAL_DTR |
        WHAL_SPIMEM_NOR_FLAG_MICRON_VCFG_1BIT,
    VERSAL2_FLASH_JEDEC_ID, &ot_flash_timeout
};
static whal_Flash versal2_flash = {
    0, &whal_SpiMemNor_Flash_Driver, &ot_flash_cfg
};

/* The real ext_flash code, copied out of hal/wolfhal.c by the
 * Makefile. */
#undef BOARD_EXT_FLASH_DEV
#define BOARD_EXT_FLASH_DEV (&versal2_flash)
#include "wolfhal_ext_flash_extract.h"

/* A device with no DMA, to read the same data with STIG only. */
#if defined(WOLFBOOT_OSPI_DMA) && defined(OT_MODE_SCAN)
static whal_CadenceOspi_SpiMem_Cfg ot_ospi_stig_cfg = {
    WHAL_VERSAL2_OSPI_DEV_SIZE_VEK385,
    VERSAL2_OSPI_BAUD_DIV_32,
    VERSAL2_OSPI_CS_LINES,
    VERSAL2_OSPI_RD_CAPTURE,
    WHAL_VERSAL2_OSPI_IND_TRIG_BASE,
    WHAL_VERSAL2_OSPI_IND_TRIG_RANGE,
    WHAL_VERSAL2_OSPI_SRAM_PARTITION,
    WHAL_VERSAL2_OSPI_DMA_PERIPH_CFG,
    NULL,
    &ot_ospi_timeout
};
static whal_SpiMem ot_ospi_stig = {
    WHAL_VERSAL2_OSPI_BASE, WHAL_VERSAL2_OSPI_DRIVER, &ot_ospi_stig_cfg
};
#endif

static void uart_putc(char c)
{
    if (c == '\n') {
        uart_putc('\r');
    }
    (void)whal_Uart_Send(&ot_uart, &c, 1);
}

static void putstr(const char *s)
{
    while (*s) {
        uart_putc(*s++);
    }
}

static void puthex(uint32_t v)
{
    static const char h[] = "0123456789ABCDEF";
    int i;

    putstr("0x");
    for (i = 28; i >= 0; i -= 4) {
        uart_putc(h[(v >> i) & 0xF]);
    }
}

static void putdec(uint32_t v)
{
    char b[11];
    int i = 10;

    b[i] = 0;
    do {
        b[--i] = (char)('0' + (v % 10));
        v /= 10;
    } while (v != 0);
    putstr(&b[i]);
}

#if defined(OT_MODE_SCAN) || defined(OT_MODE_WRITE)
/* CRC32 (IEEE, reflected), one bit at a time. Slow but small. */
static uint32_t crc32_update(uint32_t crc, const uint8_t *p, uint32_t len)
{
    uint32_t i;
    int b;

    for (i = 0; i < len; i++) {
        crc ^= p[i];
        for (b = 0; b < 8; b++) {
            if (crc & 1) {
                crc = (crc >> 1) ^ 0xEDB88320UL;
            }
            else {
                crc >>= 1;
            }
        }
    }
    return crc;
}
#endif

static uint8_t buf[OT_CHUNK] __attribute__((aligned(CACHE_LINE_SIZE)));

static int ospi_tool_init(void)
{
    uint8_t id[3] = { 0, 0, 0 };

    /* Same setup as vek385_ospi_init() in the board file. */
    if (whal_SpiMem_Init(&versal2_ospi) != WHAL_SUCCESS) {
        putstr("OT INIT: FAIL (controller)\n");
        return -1;
    }

    /* The NOR driver checks the ID (resets the flash and retries if
     * needed) and clears old flag status error bits. */
    if (whal_Flash_Init(&versal2_flash) != WHAL_SUCCESS) {
        (void)whal_SpiMemNor_Flash_ReadId(&versal2_flash, id);
        if (id[0] == 0x00 || id[0] == 0xFF) {
            putstr("OT ID: FAIL (no flash response)\n");
        }
        else {
            putstr("OT ID: UNEXPECTED\n");
        }
        return -1;
    }
    putstr("OT ID: 2C 5B 1C OK (Micron MT35XU02G)\n");
    return 0;
}

#ifdef OT_MODE_SCAN
/* Scan one region: erased or not, first non-0xFF offset, number of
 * 128 KB sectors that are not erased, CRC32. */
static int scan_region(const char *name, uint32_t base, uint32_t size)
{
    uint32_t off, i;
    uint32_t crc = 0xFFFFFFFFUL;
    uint32_t first = 0xFFFFFFFFUL;
    uint32_t dirty = 0;
    int sec_dirty = 0;

    for (off = 0; off < size; off += OT_CHUNK) {
        if (ext_flash_read(base + off, buf, OT_CHUNK) != OT_CHUNK) {
            putstr("OT-SCAN "); putstr(name); putstr(": READ FAIL at ");
            puthex(base + off); uart_putc('\n');
            return -1;
        }
        crc = crc32_update(crc, buf, OT_CHUNK);
        for (i = 0; i < OT_CHUNK; i++) {
            if (buf[i] != 0xFF) {
                if (first == 0xFFFFFFFFUL) {
                    first = off + i;
                }
                sec_dirty = 1;
                break;
            }
        }
        if (((off + OT_CHUNK) % WOLFBOOT_SECTOR_SIZE) == 0) {
            if (sec_dirty) {
                dirty++;
            }
            sec_dirty = 0;
        }
    }
    putstr("OT-SCAN "); putstr(name); putstr(" base="); puthex(base);
    putstr(" size="); puthex(size);
    if (first == 0xFFFFFFFFUL) {
        putstr(" erased=yes");
    }
    else {
        putstr(" erased=no first="); puthex(first);
        putstr(" dirty_sectors="); putdec(dirty);
    }
    putstr(" crc32="); puthex(crc ^ 0xFFFFFFFFUL); uart_putc('\n');
    return 0;
}

#ifdef WOLFBOOT_OSPI_DMA
/* The first 64 KB of BOOT read with DMA and with STIG must match. */
static uint8_t buf2[OT_CHUNK];

static int dma_vs_stig(void)
{
    whal_SpiMemOp op = WHAL_SPIMEM_OP_INIT_1BIT;

    if (ext_flash_read(WOLFBOOT_PARTITION_BOOT_ADDRESS, buf, OT_CHUNK) !=
            OT_CHUNK) {
        putstr("OT DMA-VS-STIG: FAIL (DMA read)\n");
        return -1;
    }
    op.opcode = OSPI_OP_READ4;
    op.addrBytes = 4;
    op.addr = WOLFBOOT_PARTITION_BOOT_ADDRESS;
    op.dir = WHAL_SPIMEM_DIR_IN;
    op.data = buf2;
    op.dataSz = OT_CHUNK;
    if (whal_SpiMem_Exec(&ot_ospi_stig, &op) != WHAL_SUCCESS) {
        putstr("OT DMA-VS-STIG: FAIL (STIG read)\n");
        return -1;
    }
    if (memcmp(buf, buf2, OT_CHUNK) != 0) {
        putstr("OT DMA-VS-STIG: FAIL (mismatch)\n");
        return -1;
    }
    putstr("OT DMA-VS-STIG: OK (64 KB match)\n");
    return 0;
}
#endif

static int run(void)
{
    int rc = 0;

#ifdef WOLFBOOT_OSPI_DMA
    if (dma_vs_stig() != 0) {
        rc = 1;
    }
#endif
    if (scan_region("BOOT", WOLFBOOT_PARTITION_BOOT_ADDRESS,
                    WOLFBOOT_PARTITION_SIZE) != 0) {
        rc = 1;
    }
    if (scan_region("UPDATE", WOLFBOOT_PARTITION_UPDATE_ADDRESS,
                    WOLFBOOT_PARTITION_SIZE) != 0) {
        rc = 1;
    }
    if (scan_region("DTS_BOOT", WOLFBOOT_DTS_BOOT_ADDRESS,
                    OT_DTS_SIZE) != 0) {
        rc = 1;
    }
    if (scan_region("DTS_UPDATE", WOLFBOOT_DTS_UPDATE_ADDRESS,
                    OT_DTS_SIZE) != 0) {
        rc = 1;
    }
    if (scan_region("SWAP", WOLFBOOT_PARTITION_SWAP_ADDRESS,
                    WOLFBOOT_SECTOR_SIZE) != 0) {
        rc = 1;
    }
    return rc;
}
#endif /* OT_MODE_SCAN */

#ifdef OT_MODE_WRITE
#ifndef OT_DST
#error "OT_MODE_WRITE needs OT_DST (BOOT or UPDATE partition address)"
#endif

static int run(void)
{
    const uint8_t *src = (const uint8_t *)OT_SRC;
    uint32_t magic, size, len, elen, off;
    uint32_t crc = 0xFFFFFFFFUL;

    magic = (uint32_t)src[0] | ((uint32_t)src[1] << 8) |
            ((uint32_t)src[2] << 16) | ((uint32_t)src[3] << 24);
    size = (uint32_t)src[4] | ((uint32_t)src[5] << 8) |
           ((uint32_t)src[6] << 16) | ((uint32_t)src[7] << 24);
    if (magic != OT_WOLFBOOT_MAGIC) {
        putstr("OT-WRITE: FAIL (no WOLF header at "); puthex(OT_SRC);
        putstr(")\n");
        return 1;
    }
    len = OT_IMAGE_HEADER_SIZE + size;
    if (size > WOLFBOOT_PARTITION_SIZE ||
            len > WOLFBOOT_PARTITION_SIZE - WOLFBOOT_SECTOR_SIZE) {
        putstr("OT-WRITE: FAIL (image too big)\n");
        return 1;
    }
    /* Erase whole sectors; the last sector (trailer) is not touched. */
    elen = (len + WOLFBOOT_SECTOR_SIZE - 1) & ~(WOLFBOOT_SECTOR_SIZE - 1);
    putstr("OT-WRITE: dst="); puthex(OT_DST); putstr(" len=");
    putdec(len); putstr(" erase="); puthex(elen); uart_putc('\n');

    for (off = 0; off < elen; off += WOLFBOOT_SECTOR_SIZE) {
        if (ext_flash_erase(OT_DST + off, (int)WOLFBOOT_SECTOR_SIZE) !=
                (int)WOLFBOOT_SECTOR_SIZE) {
            putstr("OT-WRITE: ERASE FAIL\n");
            return 1;
        }
    }
    putstr("OT-WRITE: ERASE OK\n");
    if (ext_flash_write(OT_DST, src, (int)len) != (int)len) {
        putstr("OT-WRITE: PROGRAM FAIL\n");
        return 1;
    }
    putstr("OT-WRITE: PROGRAM OK\n");

    for (off = 0; off < len; off += OT_CHUNK) {
        uint32_t n = len - off;

        if (n > OT_CHUNK) {
            n = OT_CHUNK;
        }
        if (ext_flash_read(OT_DST + off, buf, (int)n) != (int)n) {
            putstr("OT-WRITE: READBACK FAIL (read error)\n");
            return 1;
        }
        if (memcmp(buf, src + off, n) != 0) {
            putstr("OT-WRITE: READBACK FAIL (mismatch near ");
            puthex(OT_DST + off); putstr(")\n");
            return 1;
        }
        crc = crc32_update(crc, buf, n);
    }
    putstr("OT-WRITE: READBACK OK crc32="); puthex(crc ^ 0xFFFFFFFFUL);
    uart_putc('\n');
    return 0;
}
#endif /* OT_MODE_WRITE */

#ifdef OT_MODE_MAP
/* Map the 256 MB flash, read only: used 128 KB ranges, their first bytes,
 * and boot headers (0x584C4E58 at +0x14) on 32 KB steps. */
#define OT_FLASH_SIZE   0x10000000UL
#define OT_HDR_STEP     0x8000UL
#define OT_XLNX         0x584C4E58UL /* "XLNX" as a little-endian word */
#define OT_MAX_RANGES   64

static void dump_bytes(uint32_t addr, const uint8_t *p, uint32_t n)
{
    static const char h[] = "0123456789ABCDEF";
    uint32_t i;

    putstr("OT-MAP   "); puthex(addr); uart_putc(':');
    for (i = 0; i < n; i++) {
        uart_putc(' ');
        uart_putc(h[p[i] >> 4]);
        uart_putc(h[p[i] & 0xF]);
    }
    uart_putc('\n');
}

static int chunk_erased(const uint8_t *p, uint32_t n)
{
    const uint64_t *w = (const uint64_t *)p;
    uint32_t i;

    for (i = 0; i < n / 8; i++) {
        if (w[i] != 0xFFFFFFFFFFFFFFFFULL) {
            return 0;
        }
    }
    return 1;
}

static void find_headers(uint32_t addr, const uint8_t *p, uint32_t n)
{
    uint32_t off, v;

    for (off = 0; off < n; off += OT_HDR_STEP) {
        v = (uint32_t)p[off + 0x14] | ((uint32_t)p[off + 0x15] << 8) |
            ((uint32_t)p[off + 0x16] << 16) | ((uint32_t)p[off + 0x17] << 24);
        if (v == OT_XLNX) {
            putstr("OT-MAP boot header at "); puthex(addr + off); uart_putc('\n');
        }
    }
}

static int run(void)
{
    uint32_t addr, start = 0;
    uint32_t i;
    uint32_t ranges = 0, dirty = 0;
    int in_range = 0, sec_dirty = 0;

    putstr("OT-MAP flash size="); puthex(OT_FLASH_SIZE); uart_putc('\n');
    for (addr = 0; addr < OT_FLASH_SIZE; addr += OT_CHUNK) {
        if (ext_flash_read(addr, buf, OT_CHUNK) != OT_CHUNK) {
            putstr("OT-MAP: READ FAIL at "); puthex(addr); uart_putc('\n');
            return 1;
        }
        if (chunk_erased(buf, OT_CHUNK) == 0) {
            if (in_range == 0) {
                in_range = 1;
                start = addr;
                if (ranges < OT_MAX_RANGES) {
                    i = 0;
                    while (buf[i] == 0xFF) {
                        i++;
                    }
                    i &= ~0xFUL;
                    if (i > OT_CHUNK - 32) {
                        i = OT_CHUNK - 32;
                    }
                    dump_bytes(addr + i, buf + i, 32);
                }
            }
            sec_dirty = 1;
            find_headers(addr, buf, OT_CHUNK);
        }
        if (((addr + OT_CHUNK) % WOLFBOOT_SECTOR_SIZE) != 0) {
            continue;
        }
        if (sec_dirty) {
            dirty++;
        }
        else if (in_range) {
            in_range = 0;
            if (ranges < OT_MAX_RANGES) {
                putstr("OT-MAP used "); puthex(start); putstr(" - ");
                puthex(addr + OT_CHUNK - WOLFBOOT_SECTOR_SIZE - 1); uart_putc('\n');
            }
            ranges++;
        }
        sec_dirty = 0;
    }
    if (in_range) {
        if (ranges < OT_MAX_RANGES) {
            putstr("OT-MAP used "); puthex(start); putstr(" - ");
            puthex(OT_FLASH_SIZE - 1); uart_putc('\n');
        }
        ranges++;
    }
    putstr("OT-MAP ranges="); putdec(ranges);
    putstr(" used_sectors="); putdec(dirty); uart_putc('\n');
    return 0;
}
#endif /* OT_MODE_MAP */

int main(void)
{
    int rc;

    (void)whal_Uart_Init(&ot_uart);
    putstr("\nOT-START ospi_tool EL");
    putdec(current_el());
    uart_putc('\n');

    if (ospi_tool_init() != 0) {
        rc = 1;
    }
    else {
        rc = run();
    }

    putstr("OT-DONE rc=");
    putdec((uint32_t)rc);
    uart_putc('\n');
    for (;;) {
        __asm__ volatile ("wfi");
    }
    return 0;
}
