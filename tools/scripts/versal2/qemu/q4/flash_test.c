/* flash_test.c
 *
 * Q4 QEMU check for TARGET=versal2 (run 2): exercise the REAL OSPI
 * driver core (the OSPI_TEST_CORE block of hal/versal2.c, extracted
 * verbatim) inside QEMU 11.1.3's amd-versal2-virt machine:
 *
 *   1. flash ID read (9Fh) via ospi_flash_mode_detect()
 *      (expected 2C 5B 1C - Micron MT35XU02GCBA / QEMU mt35xu02gbba);
 *   2. 128 KB sector erase (0xDC) of a test sector inside the UPDATE
 *      partition via ospi_erase_region();
 *   3. read back the erased region (0x13) and verify 0xFF;
 *   4. program two 256-byte pages with patterns (0x12 via
 *      ext_flash_write / ospi_page_program);
 *   5. read both pages back (ext_flash_read) and compare;
 *   6. (DMA variant only, -DWOLFBOOT_OSPI_DMA=1) one 1 KB ospi_dma_read()
 *      transfer and compare - this is the empirical QEMU CSU DMA probe.
 *
 * The test prints markers on UART1 (0xF1930000); the final marker is
 * "Q4-TEST-DONE rc=<n>". The QEMU test script greps the markers and,
 * additionally, verifies the programmed pattern in the backing flash
 * file from the host.
 *
 * This is a QEMU-only test artifact: it is never part of the wolfBoot
 * build or image.
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

/* Partition geometry: config/examples/versal2_vek385.config (must match,
 * run-13 layout: BOOT 0x1DC0000 after the 8 MB BOOT.BIN reservation.
 * Old run 3-12 values, kept for reference:
 *   #define WOLFBOOT_PARTITION_BOOT_ADDRESS   0x19C0000UL
 *   #define WOLFBOOT_PARTITION_UPDATE_ADDRESS 0x4600000UL) */
#define WOLFBOOT_PARTITION_BOOT_ADDRESS   0x1DC0000UL
#define WOLFBOOT_PARTITION_UPDATE_ADDRESS 0x49C0000UL
#define WOLFBOOT_PARTITION_SWAP_ADDRESS   0xFA40000UL
#define WOLFBOOT_PARTITION_SIZE           0x2C00000UL
#define WOLFBOOT_SECTOR_SIZE              0x10000UL

/* OSPI register accessors - identical to hal/versal2.c (target). */
static inline uint32_t ospi_reg_read(uint32_t off)
{
    return OSPI_REG(off);
}

static inline void ospi_reg_write(uint32_t off, uint32_t val)
{
    OSPI_REG(off) = val;
}

void hal_delay_us(uint32_t us)
{
    /* Timing is irrelevant for correctness (the driver only uses this
     * for timeout budgets); a bounded nop loop keeps QEMU fast. */
    uint32_t i;

    for (i = 0; i < us * 10; i++)
        __asm__ volatile ("nop");
}

/* freestanding replacements for the two libc helpers the core uses */
void *memset(void *dst, int c, unsigned long n)
{
    uint8_t *d = dst;

    while (n-- > 0)
        *d++ = (uint8_t)c;
    return dst;
}

int memcmp(const void *a, const void *b, unsigned long n)
{
    const uint8_t *x = a, *y = b;

    while (n-- > 0)
        if (*x != *y)
            return (int)*x - (int)*y;
    return 0;
}

/* The real, extracted safety-critical block from hal/versal2.c. */
#include "versal2_ospi_extract.h"

/* ------------------------------------------------------------------ */
/* Minimal UART1 output - uses the PL011 register macros from         */
/* hal/versal2.h (VERSAL2_UART1_BASE = 0xF1930000, same as the        */
/* trampoline); same initialization sequence as trampoline.S.         */
/* ------------------------------------------------------------------ */

static void uart_init(void)
{
    UART_CR = 0;
    UART_IBRD = 67;
    UART_FBRD = 32;
    UART_LCR = 0x60;
    UART_CR = 0x203;
}

static void putc(char c)
{
    while (UART_FR & (1 << 5))
        ;
    UART_DR = (uint32_t)(unsigned char)c;
}

static void putstr(const char *s)
{
    while (*s)
        putc(*s++);
}

static void puthex8(uint8_t v)
{
    static const char h[] = "0123456789ABCDEF";

    putc(h[(v >> 4) & 0xF]);
    putc(h[v & 0xF]);
}

#ifdef WOLFBOOT_OSPI_DMA
static void puthex(uint32_t v)
{
    static const char h[] = "0123456789ABCDEF";
    int i;

    for (i = 28; i >= 0; i -= 4)
        putc(h[(v >> i) & 0xF]);
}
#endif

/* Test sector: 128 KB inside the UPDATE partition, well clear of the
 * partition start where real update images are placed. Program 16 pages
 * (4 KB) so the DMA path can be probed both within (1 KB, the QEMU OSPI
 * SRAM size) and beyond (4 KB) the model's internal SRAM. */
#define Q4_TSEC   ((uint32_t)WOLFBOOT_PARTITION_UPDATE_ADDRESS + 0x200000)
#define Q4_PAGES  16
#define Q4_PGSZ   OSPI_FLASH_PAGE_SIZE
#define Q4_TOTAL  (Q4_PAGES * Q4_PGSZ)   /* 4096 */

static uint8_t wrbuf[Q4_TOTAL];
static uint8_t rdbuf[Q4_TOTAL];

int main(void)
{
    int rc = 0;
    int i;
    uint32_t cfg;
    uint8_t id[3];
    uint8_t erd[8];
    int det;

    uart_init();
    putstr("Q4-TEST-START\n");

    /* Controller bring-up - the same register sequence ospi_init()
     * performs (hal/versal2.c): enable SPI, full 2Gb/4-address-byte
     * device size, 0x13/0x12 as the default read/program opcodes. */
    cfg = ospi_reg_read(OSPI_R_CONFIG);
    ospi_reg_write(OSPI_R_CONFIG, cfg | OSPI_CFG_ENB_SPI);
    hal_delay_us(10);
    ospi_reg_write(OSPI_R_DEV_SIZE_CONFIG_REG, OSPI_DEV_SIZE_VERSAL2);
    ospi_reg_write(OSPI_R_DEV_INSTR_RD_CONFIG, 0x13);
    ospi_reg_write(OSPI_R_DEV_INSTR_WR_CONFIG, 0x12);

    /* 1. Flash ID (9Fh), with the mode-detection fallback. */
    det = ospi_flash_mode_detect(id);
    if (det < 0) {
        putstr("Q4 ID: FAIL (no flash response)\n");
        rc = 1;
    }
    else {
        putstr("Q4 ID: ");
        puthex8(id[0]); putstr(" "); puthex8(id[1]); putstr(" ");
        puthex8(id[2]);
        if (id[0] == 0x2C && id[1] == 0x5B && id[2] == 0x1C) {
            putstr(" OK (Micron MT35XU02G)\n");
        }
        else {
            putstr(" UNEXPECTED\n");
            rc = 1;
        }
    }

    /* 2. Erase the 128 KB test sector (must use the 0xDC sector erase). */
    if (ospi_erase_region(Q4_TSEC, OSPI_ERASE_128K) != 0) {
        putstr("Q4 ERASE: FAIL\n");
        rc = 1;
    }
    else {
        putstr("Q4 ERASE: OK\n");
    }

    /* 3. Erased region must read back as 0xFF (8-byte STIG read). */
    if (ospi_stig(0x13, Q4_TSEC, 4, NULL, 0, erd, 8) != 0) {
        putstr("Q4 ERASED-READ: FAIL (read error)\n");
        rc = 1;
    }
    else {
        int allff = 1;

        for (i = 0; i < 8; i++)
            if (erd[i] != 0xFF)
                allff = 0;
        if (allff)
            putstr("Q4 ERASED-READ: OK\n");
        else {
            putstr("Q4 ERASED-READ: FAIL (not 0xFF)\n");
            rc = 1;
        }
    }

    /* 4. Program two 256-byte pages with distinct patterns. */
    for (i = 0; i < Q4_PAGES * Q4_PGSZ; i++)
        wrbuf[i] = (uint8_t)((i / Q4_PGSZ == 0) ? (i * 0x11) : (0xA5 ^ i));
    if (ext_flash_write(Q4_TSEC, wrbuf, sizeof(wrbuf)) != (int)sizeof(wrbuf)) {
        putstr("Q4 PROGRAM: FAIL\n");
        rc = 1;
    }
    else {
        putstr("Q4 PROGRAM: OK\n");
    }

    /* 5. Read both pages back and compare. */
    if (ext_flash_read(Q4_TSEC, rdbuf, sizeof(rdbuf)) != (int)sizeof(rdbuf)) {
        putstr("Q4 READBACK: FAIL (read error)\n");
        rc = 1;
    }
    else if (memcmp(wrbuf, rdbuf, sizeof(wrbuf)) != 0) {
        putstr("Q4 READBACK: FAIL (mismatch)\n");
        rc = 1;
    }
    else {
        putstr("Q4 READBACK: OK\n");
    }

#ifdef WOLFBOOT_OSPI_DMA
    /* 6. (DMA variant) CSU DMA reads. First a 1 KB transfer (fits the
     * QEMU model's 1 KB OSPI SRAM), then a 4 KB transfer (beyond it) to
     * characterize single-shot reads larger than the SRAM. If QEMU's
     * model does not complete a transfer, ospi_dma_read() times out and
     * reports -1. */
    if (ospi_dma_read(Q4_TSEC, rdbuf, 1024) != 0) {
        putstr("Q4 DMA-1K READBACK: FAIL (timeout/refused)\n");
        /* Diagnostic register dump for the QEMU limitations record: */
        putstr("  DST_I_STS=0x");
        puthex(ospi_reg_read(OSPI_R_DMA_DST_I_STS)); putc('\n');
        putstr("  SRC_I_STS=0x");
        puthex(ospi_reg_read(OSPI_R_DMA_SRC_I_STS)); putc('\n');
        putstr("  IND_CTRL=0x");
        puthex(ospi_reg_read(OSPI_R_IND_RD_XFER_CTRL_REG)); putc('\n');
        rc = 1;
    }
    else if (memcmp(wrbuf, rdbuf, 1024) != 0) {
        putstr("Q4 DMA-1K READBACK: FAIL (mismatch)\n");
        rc = 1;
    }
    else {
        putstr("Q4 DMA-1K READBACK: OK\n");
    }

    if (ospi_dma_read(Q4_TSEC, rdbuf, Q4_TOTAL) != 0) {
        putstr("Q4 DMA-4K READBACK: FAIL (timeout/refused)\n");
        putstr("  DST_I_STS=0x");
        puthex(ospi_reg_read(OSPI_R_DMA_DST_I_STS)); putc('\n');
        putstr("  IND_CTRL=0x");
        puthex(ospi_reg_read(OSPI_R_IND_RD_XFER_CTRL_REG)); putc('\n');
        rc = 1;
    }
    else if (memcmp(wrbuf, rdbuf, Q4_TOTAL) != 0) {
        putstr("Q4 DMA-4K READBACK: FAIL (mismatch)\n");
        rc = 1;
    }
    else {
        putstr("Q4 DMA-4K READBACK: OK\n");
    }
#endif

    putstr("Q4-TEST-DONE rc=");
    putc(rc ? '1' : '0');
    putc('\n');

    for (;;)
        __asm__ volatile ("wfi");
    return 0;
}
