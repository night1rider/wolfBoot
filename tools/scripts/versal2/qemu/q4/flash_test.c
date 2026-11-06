/* flash_test.c
 *
 * QEMU flash test: ID, erase, program and read through hal/wolfhal.c on
 * the VEK385 wolfHAL drivers; ends with "Q4-TEST-DONE rc=<n>".
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

void hal_delay_us(uint32_t us)
{
    /* Exact timing does not matter here (it only sets timeouts). A short
     * nop loop keeps QEMU fast. */
    uint32_t i;

    for (i = 0; i < us * 10; i++) {
        __asm__ volatile ("nop");
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
static uint32_t q4_tick_us(void)
{
    return (uint32_t)((timer_get_count() * 1000000ULL) / timer_get_freq());
}

static whal_Timeout q4_uart_timeout = { 1000000U, 0, q4_tick_us };
static whal_Timeout q4_ospi_timeout = { 1000000U, 0, q4_tick_us };
static whal_Timeout q4_flash_timeout = { 10000000U, 0, q4_tick_us };

/* UART1 on the wolfHAL PL011 driver. QEMU ignores the divisors. */
static whal_Pl011_Uart_Cfg q4_uart_cfg = {
    WHAL_PL011_UART_IBRD(DEBUG_UART_CLK_HZ, DEBUG_UART_BAUD),
    WHAL_PL011_UART_FBRD(DEBUG_UART_CLK_HZ, DEBUG_UART_BAUD),
    WHAL_PL011_UART_LCRH_8N1_FIFO,
    &q4_uart_timeout
};
static whal_Uart q4_uart = {
    WHAL_VERSAL2_UART1_BASE, WHAL_VERSAL2_UART_DRIVER, &q4_uart_cfg
};

#ifdef WOLFBOOT_OSPI_DMA
/* Cache upkeep around the DMA read, like in the board file. */
static void q4_dcache_clean_inval(void *buf, size_t len)
{
    uintptr_t addr = (uintptr_t)buf;
    uintptr_t p = addr & ~(uintptr_t)(CACHE_LINE_SIZE - 1);

    for (; p < addr + len; p += CACHE_LINE_SIZE) {
        __asm__ volatile("dc civac, %0" : : "r"(p) : "memory");
    }
    __asm__ volatile("dsb sy" : : : "memory");
}

static void q4_dcache_inval(void *buf, size_t len)
{
    uintptr_t addr = (uintptr_t)buf;
    uintptr_t p = addr & ~(uintptr_t)(CACHE_LINE_SIZE - 1);

    for (; p < addr + len; p += CACHE_LINE_SIZE) {
        __asm__ volatile("dc ivac, %0" : : "r"(p) : "memory");
    }
    __asm__ volatile("dsb sy" : : : "memory");
}

static whal_Timeout q4_dma_timeout = { 10000000U, 0, q4_tick_us };
static whal_Versal2_OspiDma_Ctx q4_dma_ctx = {
    WHAL_VERSAL2_OSPI_BASE,
    WHAL_VERSAL2_OSPI_DMA_SRC_RD_ADDR,
    WHAL_VERSAL2_OSPI_DMA_DST_CTRL,
    q4_dcache_clean_inval,
    q4_dcache_inval,
    &q4_dma_timeout
};

/* Wrap the hook to count the DMA transfers. */
static int q4_dma_arms;
static whal_Error q4_dma_arm(void *ctx, void *buf, size_t len)
{
    q4_dma_arms++;
    return whal_Versal2_OspiDma_Arm(ctx, buf, len);
}

static const whal_CadenceOspi_SpiMem_Dma q4_dma = {
    q4_dma_arm, whal_Versal2_OspiDma_Wait, &q4_dma_ctx, CACHE_LINE_SIZE
};
#define Q4_DMA_HOOK (&q4_dma)
#else
#define Q4_DMA_HOOK NULL
#endif

/* The flash devices, set up as in hal/boards/vek385. QEMU has no PLM, so the
 * controller starts from its reset values. */
static whal_CadenceOspi_SpiMem_Cfg q4_ospi_cfg = {
    WHAL_VERSAL2_OSPI_DEV_SIZE_VEK385,
    VERSAL2_OSPI_BAUD_DIV_32,
    VERSAL2_OSPI_CS_LINES,
    VERSAL2_OSPI_RD_CAPTURE,
    WHAL_VERSAL2_OSPI_IND_TRIG_BASE,
    WHAL_VERSAL2_OSPI_IND_TRIG_RANGE,
    WHAL_VERSAL2_OSPI_SRAM_PARTITION,
    WHAL_VERSAL2_OSPI_DMA_PERIPH_CFG,
    Q4_DMA_HOOK,
    &q4_ospi_timeout
};
static whal_SpiMem versal2_ospi = {
    WHAL_VERSAL2_OSPI_BASE, WHAL_VERSAL2_OSPI_DRIVER, &q4_ospi_cfg
};
static whal_SpiMemNor_Flash_Cfg q4_flash_cfg = {
    &versal2_ospi, 0x10000000, 256, 0x20000, 4,
    OSPI_OP_READ4, 0, OSPI_OP_PAGE_PROGRAM4, OSPI_OP_ERASE4_128K,
    WHAL_SPIMEM_NOR_FLAG_FSR | WHAL_SPIMEM_NOR_FLAG_RESET |
        WHAL_SPIMEM_NOR_FLAG_MICRON_VCFG_1BIT,
    VERSAL2_FLASH_JEDEC_ID, &q4_flash_timeout
};
static whal_Flash versal2_flash = {
    0, &whal_SpiMemNor_Flash_Driver, &q4_flash_cfg
};

/* The real ext_flash code, copied out of hal/wolfhal.c by the
 * Makefile. */
#undef BOARD_EXT_FLASH_DEV
#define BOARD_EXT_FLASH_DEV (&versal2_flash)
#include "wolfhal_ext_flash_extract.h"

static void uart_putc(char c)
{
    (void)whal_Uart_Send(&q4_uart, &c, 1);
}

static void putstr(const char *s)
{
    while (*s) {
        uart_putc(*s++);
    }
}

static void puthex8(uint8_t v)
{
    static const char h[] = "0123456789ABCDEF";

    uart_putc(h[(v >> 4) & 0xF]);
    uart_putc(h[v & 0xF]);
}

/* Test sector: 128 KB inside UPDATE, away from the image. 4 KB is written
 * so DMA is tested at 1 KB (QEMU SRAM size) and 4 KB. */
#define Q4_TSEC   ((uint32_t)WOLFBOOT_PARTITION_UPDATE_ADDRESS + 0x200000)
#define Q4_PAGES  16
#define Q4_PGSZ   256
#define Q4_TOTAL  (Q4_PAGES * Q4_PGSZ)   /* 4096 */

static uint8_t wrbuf[Q4_TOTAL];
/* Aligned to a cache line, as the DMA read needs. */
static uint8_t rdbuf[Q4_TOTAL] __attribute__((aligned(CACHE_LINE_SIZE)));

int main(void)
{
    int rc = 0;
    int i;
    uint8_t id[3];
    uint8_t erd[8];

    (void)whal_Uart_Init(&q4_uart);
    putstr("Q4-TEST-START\n");

    if (whal_SpiMem_Init(&versal2_ospi) != WHAL_SUCCESS) {
        putstr("Q4 INIT: FAIL (controller)\n");
        rc = 1;
    }

    /* 1. Init the NOR driver: it reads the flash ID (9Fh), resets the
     * flash and retries if needed, and accepts only the VEK385 part. */
    if (whal_Flash_Init(&versal2_flash) != WHAL_SUCCESS) {
        putstr("Q4 INIT: FAIL (NOR flash)\n");
        rc = 1;
    }
    if (whal_SpiMemNor_Flash_ReadId(&versal2_flash, id) != WHAL_SUCCESS) {
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

    /* 2. Erase the 128 KB test sector (0xDC erase). */
    if (ext_flash_erase(Q4_TSEC, WOLFBOOT_SECTOR_SIZE) !=
            (int)WOLFBOOT_SECTOR_SIZE) {
        putstr("Q4 ERASE: FAIL\n");
        rc = 1;
    }
    else {
        putstr("Q4 ERASE: OK\n");
    }

    /* 3. The erased area must read as 0xFF (8-byte STIG read). */
    if (ext_flash_read(Q4_TSEC, erd, sizeof(erd)) != (int)sizeof(erd)) {
        putstr("Q4 ERASED-READ: FAIL (read error)\n");
        rc = 1;
    }
    else {
        int allff = 1;

        for (i = 0; i < 8; i++) {
            if (erd[i] != 0xFF) {
                allff = 0;
            }
        }
        if (allff) {
            putstr("Q4 ERASED-READ: OK\n");
        }
        else {
            putstr("Q4 ERASED-READ: FAIL (not 0xFF)\n");
            rc = 1;
        }
    }

    /* 4. Write 16 pages (4 KB). Page 0 has a different pattern. */
    for (i = 0; i < Q4_PAGES * Q4_PGSZ; i++) {
        if (i / Q4_PGSZ == 0) {
            wrbuf[i] = (uint8_t)(i * 0x11);
        }
        else {
            wrbuf[i] = (uint8_t)(0xA5 ^ i);
        }
    }
    if (ext_flash_write(Q4_TSEC, wrbuf, sizeof(wrbuf)) != (int)sizeof(wrbuf)) {
        putstr("Q4 PROGRAM: FAIL\n");
        rc = 1;
    }
    else {
        putstr("Q4 PROGRAM: OK\n");
    }

    /* 5. Read it all back and compare. */
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
    /* 6. (DMA build) Read 1 KB, then 4 KB, into the aligned buffer, both
     * through the DMA hook. */
    memset(rdbuf, 0, sizeof(rdbuf));
    q4_dma_arms = 0;
    if (ext_flash_read(Q4_TSEC, rdbuf, 1024) != 1024 || q4_dma_arms != 1) {
        putstr("Q4 DMA-1K READBACK: FAIL (read error or no DMA)\n");
        rc = 1;
    }
    else if (memcmp(wrbuf, rdbuf, 1024) != 0) {
        putstr("Q4 DMA-1K READBACK: FAIL (mismatch)\n");
        rc = 1;
    }
    else {
        putstr("Q4 DMA-1K READBACK: OK\n");
    }

    memset(rdbuf, 0, sizeof(rdbuf));
    q4_dma_arms = 0;
    if (ext_flash_read(Q4_TSEC, rdbuf, Q4_TOTAL) != Q4_TOTAL ||
            q4_dma_arms != 1) {
        putstr("Q4 DMA-4K READBACK: FAIL (read error or no DMA)\n");
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
    if (rc != 0) {
        uart_putc('1');
    }
    else {
        uart_putc('0');
    }
    uart_putc('\n');

    for (;;) {
        __asm__ volatile ("wfi");
    }
    return 0;
}
