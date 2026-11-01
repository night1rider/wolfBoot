/* unit-versal2-uart.c
 *
 * Host unit test for the TARGET=versal2 PL011 baud-rate divisor
 * calculation in hal/versal2.h (versal2_uart_baud_divisors()), added in
 * run 3 because the QEMU PL011 model ignores the divisors and the old
 * hard-coded IBRD=67/FBRD=32 was wrong for the documented 100 MHz
 * reference clock (~92.6 kbaud, ~20% off at 100 MHz).
 *
 * What is verified:
 *   - the AM026 ch. 63 p670 formula (Baud_Rate_Divisor = FCLK/(16*BAUD),
 *     IBRD = integer part, FBRD = Integer((fraction*64)+0.5)) at the
 *     115200 baud default for 100, 125 and 150 MHz reference clocks:
 *     the exact divisors (54/16, 67/52, 81/24) and a resulting
 *     baud-rate error of < 1%;
 *   - AM026's own worked example (4 MHz @ 230400 -> IBRD 1, FBRD 5);
 *   - the resulting baud within 1% for 100/125/150 MHz via the
 *     independent resulting_baud() (FCLK/(16*(IBRD+FBRD/64)));
 *   - the PL011 16x minimum (FCLK < 16*BAUD is refused, 0/0 returned);
 *   - DEBUG_UART_NUM selection: 0 selects UART0 (0xF1920000), 1 (or
 *     the default) selects the VEK385 console UART1 (0xF1930000).
 *
 * A second variant (unit-versal2-uart-uart0, built with
 * -DDEBUG_UART_NUM=0) proves the UART0 selection.
 *
 * The VEK385 UART reference clock is firmware-programmed (AM028 CRL
 * UART1_REF_CLK_CTRL, PLL source + divider, set by the PLM); the
 * documents do not pin a single runtime value. The documented limit is
 * FUART_REF_CLK <= 100 MHz (DS1021, "PS UART Controller Interface",
 * Table 51). On the board uart_init() keeps the PLM's divisors (the UART
 * is already enabled); the divisors are only programmed when the UART
 * is disabled (QEMU without the trampoline), from DEBUG_UART_CLK_HZ
 * (default 100 MHz, overridable in the config). See BUILD.md, Run 3.
 *
 * Run 4: the divisor formula was missing the 16x Baud16 factor (run 3
 * computed IBRD = FCLK/BAUD; AM026 p670 says the divider output must be
 * FCLK/(16*BAUD) because Baud16 is 16x the I/O baud rate). The run-3
 * expected values (868/4, 1085/4, 1302/5) are kept as commented-out
 * checks in the tests below with that reason and page; the corrected
 * checks (54/16, 67/52, 81/24), the AM026 4 MHz @ 230400 worked example
 * (IBRD 1, FBRD 5) and the independent 1% resulting-baud checks are the
 * new ones. resulting_baud() was fixed to the same FCLK/(16*(IBRD+
 * FBRD/64)) relation so the error checks are independent of the code
 * under test. Additive only: no existing check was removed.
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
#include <math.h>
#include <stdint.h>

/* Register offsets, UART bases and the divisor helper (host-clean). */
#include "versal2.h"

#ifndef DEBUG_UART_BAUD
#define DEBUG_UART_BAUD 115200
#endif

/* The actual baud rate produced by the divisors, independent of the
 * code under test: AM026 ch. 63 p670 - the divider output (Baud16) is
 * 16x the I/O baud rate, so baud = FCLK / (16 * (IBRD + FBRD/64)). */
static double resulting_baud(uint64_t fclk, uint32_t ibrd, uint32_t fbrd)
{
    return (double)fclk / (16.0 * ((double)ibrd + (double)fbrd / 64.0));
}

START_TEST(test_divisors_100mhz)
{
    uint32_t ibrd = 0, fbrd = 0;
    double baud;

    /* 100000000/(16*115200) = 54.2534... -> IBRD 54; FBRD =
     * Integer((0.2534...*64)+0.5) = Integer(16.72) = 16 (AM026 p670) */
    fail_unless(versal2_uart_baud_divisors(100000000UL, DEBUG_UART_BAUD,
                                           &ibrd, &fbrd) == 0,
                "100 MHz: divisor computation failed");
    /* Run 3 checks, kept for the record: they assumed IBRD = FCLK/BAUD
     * (missing the 16x Baud16 factor) - proven wrong by AM026 ch. 63
     * p670 (Baud_Rate_Divisor = REF_CLK/(16*baud); Baud16 is 16x the I/O
     * baud rate). At 100 MHz 868/4 is 7200 baud, 16x too slow. Replaced
     * by the corrected 54/16 checks below.
     *     fail_unless(ibrd == 868, "100 MHz: IBRD 868 expected, got %u", ibrd);
     *     fail_unless(fbrd == 4, "100 MHz: FBRD 4 expected, got %u", fbrd);
     */
    fail_unless(ibrd == 54, "100 MHz: IBRD 54 expected, got %u", ibrd);
    fail_unless(fbrd == 16, "100 MHz: FBRD 16 expected, got %u", fbrd);
    baud = resulting_baud(100000000UL, ibrd, fbrd);
    fail_unless(fabs(baud - DEBUG_UART_BAUD) / DEBUG_UART_BAUD < 0.01,
                "100 MHz: baud error >= 1%% (%.2f)", baud);
}
END_TEST

START_TEST(test_divisors_125mhz)
{
    uint32_t ibrd = 0, fbrd = 0;
    double baud;

    /* 125000000/(16*115200) = 67.8164... -> IBRD 67; FBRD =
     * Integer((0.8164...*64)+0.5) = Integer(52.65) = 52 (AM026 p670) */
    fail_unless(versal2_uart_baud_divisors(125000000UL, DEBUG_UART_BAUD,
                                           &ibrd, &fbrd) == 0,
                "125 MHz: divisor computation failed");
    /* Run 3 checks, kept for the record: wrong formula (IBRD =
     * FCLK/BAUD, missing the 16x Baud16 factor) - proven wrong by AM026
     * ch. 63 p670. Replaced by the corrected 67/52 checks below.
     *     fail_unless(ibrd == 1085, "125 MHz: IBRD 1085 expected, got %u", ibrd);
     *     fail_unless(fbrd == 4, "125 MHz: FBRD 4 expected, got %u", fbrd);
     */
    fail_unless(ibrd == 67, "125 MHz: IBRD 67 expected, got %u", ibrd);
    fail_unless(fbrd == 52, "125 MHz: FBRD 52 expected, got %u", fbrd);
    baud = resulting_baud(125000000UL, ibrd, fbrd);
    fail_unless(fabs(baud - DEBUG_UART_BAUD) / DEBUG_UART_BAUD < 0.01,
                "125 MHz: baud error >= 1%% (%.2f)", baud);
}
END_TEST

START_TEST(test_divisors_150mhz)
{
    uint32_t ibrd = 0, fbrd = 0;
    double baud;

    /* 150000000/(16*115200) = 81.3802... -> IBRD 81; FBRD =
     * Integer((0.3802...*64)+0.5) = Integer(24.83) = 24 (AM026 p670) */
    fail_unless(versal2_uart_baud_divisors(150000000UL, DEBUG_UART_BAUD,
                                           &ibrd, &fbrd) == 0,
                "150 MHz: divisor computation failed");
    /* Run 3 checks, kept for the record: wrong formula (IBRD =
     * FCLK/BAUD, missing the 16x Baud16 factor) - proven wrong by AM026
     * ch. 63 p670. Replaced by the corrected 81/24 checks below.
     *     fail_unless(ibrd == 1302, "150 MHz: IBRD 1302 expected, got %u", ibrd);
     *     fail_unless(fbrd == 5, "150 MHz: FBRD 5 expected, got %u", fbrd);
     */
    fail_unless(ibrd == 81, "150 MHz: IBRD 81 expected, got %u", ibrd);
    fail_unless(fbrd == 24, "150 MHz: FBRD 24 expected, got %u", fbrd);
    baud = resulting_baud(150000000UL, ibrd, fbrd);
    fail_unless(fabs(baud - DEBUG_UART_BAUD) / DEBUG_UART_BAUD < 0.01,
                "150 MHz: baud error >= 1%% (%.2f)", baud);
}
END_TEST

START_TEST(test_divisors_refuse_too_slow_clock)
{
    uint32_t ibrd = 123, fbrd = 123;

    /* PL011 limit: the reference clock must be at least 16 x the baud
     * rate (16 x 115200 = 1843200 Hz). 1.8 MHz is below that limit. */
    fail_unless(versal2_uart_baud_divisors(1800000UL, DEBUG_UART_BAUD,
                                           &ibrd, &fbrd) == -1,
                "too-slow clock accepted");
    fail_unless(ibrd == 0 && fbrd == 0, "refused divisors must be 0/0");
    /* Zero inputs are refused too. */
    fail_unless(versal2_uart_baud_divisors(0UL, DEBUG_UART_BAUD,
                                           &ibrd, &fbrd) == -1,
                "zero clock accepted");
    fail_unless(versal2_uart_baud_divisors(100000000UL, 0U,
                                           &ibrd, &fbrd) == -1,
                "zero baud accepted");
}
END_TEST

START_TEST(test_divisors_am026_example)
{
    uint32_t ibrd = 0, fbrd = 0;
    double baud;

    /* AM026 ch. 63 p670 "Baud Rate Example": 230400 bps with a 4 MHz
     * reference: Baud_Rate_Divisor = 4000000/(16*230400) = 1.085...,
     * [DIVINT] = 1, [DIVFRAC] = Integer((0.085*64)+0.5) = Integer(5.94)
     * = 5. Resulting divider = 1 + 5/64 = 1.078... */
    fail_unless(versal2_uart_baud_divisors(4000000UL, 230400U,
                                           &ibrd, &fbrd) == 0,
                "4 MHz: divisor computation failed");
    fail_unless(ibrd == 1, "4 MHz: IBRD 1 expected, got %u", ibrd);
    fail_unless(fbrd == 5, "4 MHz: FBRD 5 expected, got %u", fbrd);
    baud = resulting_baud(4000000UL, ibrd, fbrd);
    fail_unless(fabs(baud - 230400.0) / 230400.0 < 0.01,
                "4 MHz: baud error >= 1%% (%.2f)", baud);
}
END_TEST

START_TEST(test_resulting_baud_within_1pct)
{
    uint64_t fclks[3] = { 100000000UL, 125000000UL, 150000000UL };
    uint32_t i;

    /* Run 4: with the fixed resulting_baud() (FCLK/(16*(IBRD+FBRD/64)),
     * independent of the code under test), the divisors for the three
     * reference clocks must produce the target baud within 1%. */
    for (i = 0; i < 3; i++) {
        uint32_t ibrd = 0, fbrd = 0;
        double baud;

        fail_unless(versal2_uart_baud_divisors(fclks[i], DEBUG_UART_BAUD,
                                               &ibrd, &fbrd) == 0,
                    "%lu MHz: divisor computation failed",
                    (unsigned long)(fclks[i] / 1000000UL));
        baud = resulting_baud(fclks[i], ibrd, fbrd);
        fail_unless(fabs(baud - DEBUG_UART_BAUD) / DEBUG_UART_BAUD < 0.01,
                    "%lu MHz: resulting baud %.2f not within 1%%",
                    (unsigned long)(fclks[i] / 1000000UL), baud);
    }
}
END_TEST

START_TEST(test_uart_base_selection)
{
#if defined(DEBUG_UART_NUM) && DEBUG_UART_NUM == 0
    /* This variant was built with -DDEBUG_UART_NUM=0: UART0. */
    fail_unless(DEBUG_UART_BASE == VERSAL2_UART0_BASE,
                "DEBUG_UART_NUM=0 must select UART0 (0x%lX)",
                (unsigned long)DEBUG_UART_BASE);
    fail_unless(DEBUG_UART_BASE == 0xF1920000UL,
                "UART0 base 0xF1920000 expected, got 0x%lX",
                (unsigned long)DEBUG_UART_BASE);
#else
    /* Default (or DEBUG_UART_NUM=1): the VEK385 console UART1. */
    fail_unless(DEBUG_UART_BASE == VERSAL2_UART1_BASE,
                "default must select UART1 (0x%lX)",
                (unsigned long)DEBUG_UART_BASE);
    fail_unless(DEBUG_UART_BASE == 0xF1930000UL,
                "UART1 base 0xF1930000 expected, got 0x%lX",
                (unsigned long)DEBUG_UART_BASE);
#endif
}
END_TEST

Suite *versal2_uart_suite(void)
{
    Suite *s = suite_create("versal2-uart");
    TCase *tc = tcase_create("versal2-uart");

    tcase_add_test(tc, test_divisors_100mhz);
    tcase_add_test(tc, test_divisors_125mhz);
    tcase_add_test(tc, test_divisors_150mhz);
    tcase_add_test(tc, test_divisors_refuse_too_slow_clock);
    tcase_add_test(tc, test_divisors_am026_example);
    tcase_add_test(tc, test_resulting_baud_within_1pct);
    tcase_add_test(tc, test_uart_base_selection);
    suite_add_tcase(s, tc);

    return s;
}

int main(void)
{
    int fails;
    Suite *s = versal2_uart_suite();
    SRunner *sr = srunner_create(s);

    srunner_run_all(sr, CK_NORMAL);
    fails = srunner_ntests_failed(sr);
    srunner_free(sr);

    return fails;
}
