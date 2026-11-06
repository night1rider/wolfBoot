/* unit-wolfhal-ext-flash.c
 *
 * Tests the hal/wolfhal.c ext_flash code (partition guard, whal_Flash_*
 * calls) on a mock flash. WOLFBOOT_SECTOR_SIZE in the env sets SWAP size.
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

#include <check.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wolfHAL/wolfHAL.h>

/* Partitions from config/examples/versal2_vek385.config. BOOT starts
 * at 0x1DC0000, after the 8 MB BOOT.BIN area. */
#define WOLFBOOT_PARTITION_BOOT_ADDRESS   0x1DC0000UL
#define WOLFBOOT_PARTITION_UPDATE_ADDRESS 0x49C0000UL
#define WOLFBOOT_PARTITION_SWAP_ADDRESS   0xFA40000UL
#define WOLFBOOT_PARTITION_SIZE           0x2C00000UL
#define WOLFBOOT_SECTOR_SIZE              0x20000UL

/* BOOT.BIN area: 0x15C0000-0x1DBFFFF (8 MB). AMD's BOOT.BIN ends at
 * 0x1B0FE40, so a 4 MB area would overlap it at 0x19C0000-0x1B0FE40. */
#define BOOTBIN_RESERVATION_START         0x15C0000UL
#define BOOTBIN_OLD_OVERLAP_START         0x19C0000UL

/* ------------------------------------------------------------------ */
/* Mock flash device (records the whal_Flash calls)                   */
/* ------------------------------------------------------------------ */

static int      fl_reads, fl_writes, fl_erases;
static size_t   fl_addr, fl_len;
static whal_Error fl_ret;

static whal_Error MockFlashRead(whal_Flash *d, size_t addr, void *data,
                                size_t sz)
{
    (void)d;
    (void)data;
    fl_reads++;
    fl_addr = addr;
    fl_len = sz;
    return fl_ret;
}

static whal_Error MockFlashWrite(whal_Flash *d, size_t addr,
                                 const void *data, size_t sz)
{
    (void)d;
    (void)data;
    fl_writes++;
    fl_addr = addr;
    fl_len = sz;
    return fl_ret;
}

static whal_Error MockFlashErase(whal_Flash *d, size_t addr, size_t sz)
{
    (void)d;
    fl_erases++;
    fl_addr = addr;
    fl_len = sz;
    return fl_ret;
}

static const whal_FlashDriver mockFlashDriver = {
    .Read = MockFlashRead,
    .Write = MockFlashWrite,
    .Erase = MockFlashErase,
};

static whal_Flash mock_flash = { 0, &mockFlashDriver, NULL };
#define BOARD_EXT_FLASH_DEV (&mock_flash)

/* SWAP sector size: the config value, or the WOLFBOOT_SECTOR_SIZE
 * environment variable if set (CI also runs with 0x400). */
static uint32_t test_sector_size(void)
{
    const char *e = getenv("WOLFBOOT_SECTOR_SIZE");

    if (e != NULL) {
        unsigned long v = strtoul(e, NULL, 0);

        if (v != 0) {
            return (uint32_t)v;
        }
    }
    return (uint32_t)WOLFBOOT_SECTOR_SIZE;
}

/* The real ext_flash code, extracted from hal/wolfhal.c. */
#include "wolfhal_ext_flash_extract.h"

static int flash_calls(void)
{
    return fl_reads + fl_writes + fl_erases;
}

/* ------------------------------------------------------------------ */
/* Address guard                                                      */
/* ------------------------------------------------------------------ */

START_TEST(test_addr_guard_accepts_partitions)
{
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x1DC0000, 0x1000) == 1, "BOOT start");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x1DC0000 + 0x2C00000 - 0x1000,
                                     0x1000) == 1, "BOOT tail");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x49C0000, 0x20000) == 1,
                  "UPDATE 128 KB");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x49C0000 + 0x2C00000 - 0x20000, 0x20000)
                  == 1, "UPDATE last 128 KB");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0xFA40000, test_sector_size()) == 1,
                  "SWAP (full sector)");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x2000000, 0x100) == 1,
                  "mid-BOOT program");
}
END_TEST

START_TEST(test_addr_guard_refuses_out_of_range)
{
    /* AMD Image Selector / Image Recovery / metadata. */
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x0000000, 0x1000) == 0,
                  "Image Selector @0");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x0100000, 0x1000) == 0,
                  "recovery @0x100000");
    /* Bank A past the partitions and DTS slots, and Bank B. */
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x08000000, 0x1000) == 0, "Bank A tail");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x08800000, 0x1000) == 0, "Bank B");
    /* Past the end of UPDATE, and a 128 KB block straddling it. */
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x49C0000 + 0x2C00000, 0x1000) == 0,
                  "UPDATE tail overrun");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x49C0000 + 0x2C00000 - 0x10000, 0x20000)
                  == 0, "128 KB straddling UPDATE end");
    /* Past the end of SWAP (for any sector size). */
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0xFA40000 + test_sector_size() - 0x400,
                                     0x800) == 0, "SWAP overrun");
    ck_assert_msg(wolfhal_ext_flash_guard_ok(0x1DC0000, 0) == 0, "zero length");
}
END_TEST

/* Every erase and program in the 8 MB BOOT.BIN area is refused before
 * the flash driver is called. */
START_TEST(test_bootbin_reservation_refused)
{
    uint8_t buf[16];
    uint32_t addr;

    memset(buf, 0x5A, sizeof(buf));
    for (addr = BOOTBIN_RESERVATION_START; addr <= 0x1DA0000;
            addr += 0x20000) {
        ck_assert_msg(ext_flash_erase(addr, 0x20000) == -1,
                      "erase at 0x%08lX accepted", (unsigned long)addr);
        ck_assert_msg(ext_flash_write(addr, buf, sizeof(buf)) == -1,
                      "write at 0x%08lX accepted", (unsigned long)addr);
    }
    ck_assert_msg(ext_flash_erase(BOOTBIN_OLD_OVERLAP_START, 0x20000) == -1,
                  "erase at the overlap start accepted");
    ck_assert_msg(ext_flash_write(0x1B0F000, buf, sizeof(buf)) == -1,
                  "write in the overlap area accepted");
    ck_assert_msg(flash_calls() == 0, "a refused request reached the flash");
}
END_TEST

START_TEST(test_ext_flash_refuses_outside_partitions)
{
    uint8_t buf[8] = { 0 };

    ck_assert_int_eq(ext_flash_write(0x0, buf, sizeof(buf)), -1);
    ck_assert_int_eq(ext_flash_write(0x08800000, buf, sizeof(buf)), -1);
    ck_assert_int_eq(ext_flash_erase(0x49C0000 + 0x2C00000 - 0x10000,
                                     0x20000), -1);
    ck_assert_int_eq(ext_flash_erase(0x0, 0x20000), -1);
    ck_assert_msg(flash_calls() == 0, "a refused request reached the flash");
}
END_TEST

/* ------------------------------------------------------------------ */
/* ext_flash_* glue                                                   */
/* ------------------------------------------------------------------ */

START_TEST(test_ext_flash_passes_requests)
{
    uint8_t buf[300];

    memset(buf, 0, sizeof(buf));
    ck_assert_int_eq(ext_flash_write(0x49C0100, buf, 300), 300);
    ck_assert_int_eq(fl_writes, 1);
    ck_assert_uint_eq(fl_addr, 0x49C0100);
    ck_assert_uint_eq(fl_len, 300);

    ck_assert_int_eq(ext_flash_erase(0x49C0000, 0x40000), 0x40000);
    ck_assert_int_eq(fl_erases, 1);
    ck_assert_uint_eq(fl_addr, 0x49C0000);
    ck_assert_uint_eq(fl_len, 0x40000);

    /* Reads are not guarded: any address goes to the driver. */
    ck_assert_int_eq(ext_flash_read(0x0, buf, 64), 64);
    ck_assert_int_eq(fl_reads, 1);
    ck_assert_uint_eq(fl_addr, 0x0);
    ck_assert_uint_eq(fl_len, 64);
}
END_TEST

START_TEST(test_ext_flash_driver_error)
{
    uint8_t buf[16] = { 0 };

    fl_ret = WHAL_EHARDWARE;
    ck_assert_int_eq(ext_flash_write(0x49C0000, buf, sizeof(buf)), -1);
    ck_assert_int_eq(ext_flash_erase(0x49C0000, 0x20000), -1);
    ck_assert_int_eq(ext_flash_read(0x49C0000, buf, sizeof(buf)), -1);
}
END_TEST

START_TEST(test_ext_flash_empty_requests)
{
    uint8_t buf[4] = { 0 };

    ck_assert_int_eq(ext_flash_write(0x49C0000, buf, 0), 0);
    ck_assert_int_eq(ext_flash_write(0x49C0000, NULL, 4), 0);
    ck_assert_int_eq(ext_flash_erase(0x49C0000, 0), 0);
    ck_assert_int_eq(ext_flash_read(0x49C0000, buf, 0), 0);
    ck_assert_int_eq(ext_flash_read(0x49C0000, NULL, 4), 0);
    ck_assert_msg(flash_calls() == 0, "an empty request reached the flash");
}
END_TEST

/* ------------------------------------------------------------------ */

static void setup(void)
{
    fl_reads = 0;
    fl_writes = 0;
    fl_erases = 0;
    fl_addr = 0;
    fl_len = 0;
    fl_ret = WHAL_SUCCESS;
    wolfhal_swap_size = test_sector_size();
}

static void teardown(void)
{
}

Suite *wolfhal_ext_flash_suite(void)
{
    Suite *s = suite_create("wolfhal-ext-flash");
    TCase *tc = tcase_create("wolfhal-ext-flash");

    tcase_add_checked_fixture(tc, setup, teardown);
    tcase_add_test(tc, test_addr_guard_accepts_partitions);
    tcase_add_test(tc, test_addr_guard_refuses_out_of_range);
    tcase_add_test(tc, test_bootbin_reservation_refused);
    tcase_add_test(tc, test_ext_flash_refuses_outside_partitions);
    tcase_add_test(tc, test_ext_flash_passes_requests);
    tcase_add_test(tc, test_ext_flash_driver_error);
    tcase_add_test(tc, test_ext_flash_empty_requests);
    suite_add_tcase(s, tc);

    return s;
}

int main(void)
{
    int fails;
    Suite *s = wolfhal_ext_flash_suite();
    SRunner *sr = srunner_create(s);

    srunner_run_all(sr, CK_NORMAL);
    fails = srunner_ntests_failed(sr);
    srunner_free(sr);

    return fails;
}
