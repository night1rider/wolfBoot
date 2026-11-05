/* unit-versal2-el3.c
 *
 * Tests versal2_el3_handoff_ok() (hal/versal2.h) and that VERSAL2_EL3
 * turns on EL3_SECURE. Built with -DVERSAL2_BL33_BASE=0x30000000.
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

#include "versal2.h"

/* The board layout: BL31 at 0x1600000, wolfBoot at 0x40000000. */
#define T_BL31      0x1600000ULL
#define T_WB_LO     0x40000000ULL
#define T_WB_HI     0x40054000ULL

START_TEST(test_good_pair_accepted)
{
    ck_assert_msg(versal2_el3_handoff_ok(T_BL31, VERSAL2_BL33_BASE,
                  VERSAL2_BL33_BASE, T_WB_LO, T_WB_HI) == 1,
                  "BL31 0x1600000 + BL33 at VERSAL2_BL33_BASE refused");
}
END_TEST

START_TEST(test_bl31_zero_refused)
{
    ck_assert_msg(versal2_el3_handoff_ok(0, VERSAL2_BL33_BASE,
                  VERSAL2_BL33_BASE, T_WB_LO, T_WB_HI) == 0,
                  "BL31 entry 0 accepted");
}
END_TEST

START_TEST(test_bl33_wrong_address_refused)
{
    /* TF-A would jump to VERSAL2_BL33_BASE, not to this image. */
    ck_assert_msg(versal2_el3_handoff_ok(T_BL31, VERSAL2_BL33_BASE + 0x1000,
                  VERSAL2_BL33_BASE, T_WB_LO, T_WB_HI) == 0,
                  "BL33 not at VERSAL2_BL33_BASE accepted");
    ck_assert_msg(versal2_el3_handoff_ok(T_BL31, 0x24000000ULL,
                  VERSAL2_BL33_BASE, T_WB_LO, T_WB_HI) == 0,
                  "BL33 at the Linux kernel address accepted");
}
END_TEST

START_TEST(test_bl31_equal_bl33_refused)
{
    ck_assert_msg(versal2_el3_handoff_ok(VERSAL2_BL33_BASE,
                  VERSAL2_BL33_BASE, VERSAL2_BL33_BASE,
                  T_WB_LO, T_WB_HI) == 0,
                  "BL31 at the BL33 address accepted");
}
END_TEST

START_TEST(test_bl31_inside_wolfboot_refused)
{
    ck_assert_msg(versal2_el3_handoff_ok(T_WB_LO, VERSAL2_BL33_BASE,
                  VERSAL2_BL33_BASE, T_WB_LO, T_WB_HI) == 0,
                  "BL31 at wolfBoot's start accepted");
    ck_assert_msg(versal2_el3_handoff_ok(T_WB_HI - 4, VERSAL2_BL33_BASE,
                  VERSAL2_BL33_BASE, T_WB_LO, T_WB_HI) == 0,
                  "BL31 at wolfBoot's last word accepted");
}
END_TEST

START_TEST(test_bl31_wolfboot_edges_accepted)
{
    ck_assert_msg(versal2_el3_handoff_ok(T_WB_LO - 4, VERSAL2_BL33_BASE,
                  VERSAL2_BL33_BASE, T_WB_LO, T_WB_HI) == 1,
                  "BL31 just below wolfBoot refused");
    ck_assert_msg(versal2_el3_handoff_ok(T_WB_HI, VERSAL2_BL33_BASE,
                  VERSAL2_BL33_BASE, T_WB_LO, T_WB_HI) == 1,
                  "BL31 just after wolfBoot refused");
}
END_TEST

START_TEST(test_el3_build_flags)
{
    /* VERSAL2_EL3=1 makes boot_aarch64_start.S run its EL3 init. */
    ck_assert_msg(EL3_SECURE == 1, "EL3_SECURE is %d, expected 1",
                  EL3_SECURE);
    ck_assert_msg(VERSAL2_BL33_BASE == 0x30000000ULL,
                  "VERSAL2_BL33_BASE is 0x%llX",
                  (unsigned long long)VERSAL2_BL33_BASE);
}
END_TEST

Suite *versal2_el3_suite(void)
{
    Suite *s = suite_create("versal2-el3");
    TCase *tc = tcase_create("versal2-el3");

    tcase_add_test(tc, test_good_pair_accepted);
    tcase_add_test(tc, test_bl31_zero_refused);
    tcase_add_test(tc, test_bl33_wrong_address_refused);
    tcase_add_test(tc, test_bl31_equal_bl33_refused);
    tcase_add_test(tc, test_bl31_inside_wolfboot_refused);
    tcase_add_test(tc, test_bl31_wolfboot_edges_accepted);
    tcase_add_test(tc, test_el3_build_flags);
    suite_add_tcase(s, tc);

    return s;
}

int main(void)
{
    int fails;
    Suite *s = versal2_el3_suite();
    SRunner *sr = srunner_create(s);

    srunner_run_all(sr, CK_NORMAL);
    fails = srunner_ntests_failed(sr);
    srunner_free(sr);

    return fails;
}
