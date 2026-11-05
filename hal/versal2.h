/* versal2.h
 *
 * AMD Versal Gen 2 (VEK385, Cortex-A78AE). Boot: PLM -> BL31 (EL3) ->
 * wolfBoot (EL2) -> Linux; in QEMU a trampoline stands in for BL31.
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

#ifndef _VERSAL2_H_
#define _VERSAL2_H_

#ifdef __cplusplus
extern "C" {
#endif

/* C headers only for C code; boot_aarch64_start.S also includes this. */
#ifndef __ASSEMBLER__
#include <stdint.h>
#endif /* __ASSEMBLER__ */

/* BL31 owns EL3. wolfBoot runs at EL2 and starts the app at EL1.
 * With VERSAL2_EL3=1, wolfBoot starts at EL3 and hands off to BL31. */
#ifdef WOLFBOOT_VERSAL2_EL3
#define EL3_SECURE     1
#else
#define EL3_SECURE     0
#endif
#define EL2_HYPERVISOR 1
#define EL1_NONSECURE  1

/* No guest hypervisor, no FPU trapping (the A78AE FPU is always on). */
#define HYP_GUEST      0
#define FPU_TRAP       0

/* Cortex-A78: erratum 855873 workaround (as on Gen 1 Versal). */
#define CONFIG_ARM_ERRATA_855873 1

/* BL31 owns the interrupt controller (GIC). wolfBoot only polls, so it
 * must not touch it. */
#define SKIP_GIC_INIT 1

/* Default entry level for the application. */
#if !defined(BOOT_EL1) && !defined(BOOT_EL2)
    #define BOOT_EL2 1
#endif
#if defined(BOOT_EL1) && defined(BOOT_EL2)
    #error "BOOT_EL1 and BOOT_EL2 are mutually exclusive"
#endif

/* The watchdog is not supported yet (Gen 2 uses other addresses than
 * Gen 1), so a WATCHDOG build stops with an error. */
#ifdef WATCHDOG
    #error "WATCHDOG is not supported on TARGET=versal2"
#endif

/* DDR (DTB): 2 GB at 0x0, 6 GB at 0x8_0000_0000. wolfBoot (0x40000000)
 * and the app (0x20000000) are in the low 2 GB. */
#define VERSAL2_DDR_0_BASE      0x00000000UL
#define VERSAL2_DDR_0_HIGH      0x7FFFFFFFUL
#define VERSAL2_DDR_1_BASE      0x800000000ULL
/* High 6 GB. The MMU table does not map it and wolfBoot never uses it;
 * a Linux image loaded there would need a new mapping. */
#define VERSAL2_DDR_1_HIGH      0x97FFFFFFFULL

/* The app load address is WOLFBOOT_LOAD_ADDRESS in the config. It must be
 * above the RPU areas, which end at 0x1E4E7FFF on the VEK385. */

#define CACHE_LINE_SIZE         64

/* DDR range for the MMU table (used by boot_aarch64_start.S). */
#define XPAR_PSU_DDR_0_S_AXI_BASEADDR   VERSAL2_DDR_0_BASE
#define XPAR_PSU_DDR_0_S_AXI_HIGHADDR   VERSAL2_DDR_0_HIGH

/* UART (PL011): UART0 0xF1920000, UART1 0xF1930000; the VEK385 console is
 * UART1 (UG1712 "UART Interfaces"). */
#define VERSAL2_UART0_BASE      0xF1920000UL
#define VERSAL2_UART1_BASE      0xF1930000UL

/* The console UART, its clock and the OSPI flash settings are board
 * settings: see hal/boards/vek385/wolfHAL_board.h. */

/* Timer frequency used only if firmware left CNTFRQ_EL0 at 0. The QEMU
 * trampoline sets 100 MHz; the board value is not confirmed yet. */
#ifndef TIMER_CLK_FREQ
    #define TIMER_CLK_FREQ          100000000UL  /* 100 MHz */
#endif

/* wolfBoot at EL3 (VERSAL2_EL3=1) loads BL31 from the FIT ("atf"). TF-A
 * takes no handoff data: it starts BL33 at PRELOADED_BL33_BASE, EL2. */
#ifdef WOLFBOOT_VERSAL2_EL3
#ifndef VERSAL2_BL33_BASE
    #error "VERSAL2_EL3=1 needs VERSAL2_BL33_BASE (TF-A PRELOADED_BL33_BASE)"
#endif
#endif

/* 1 if BL33 is where TF-A starts it and BL31 is not 0, BL33 or inside
 * wolfBoot [wb_lo, wb_hi). Tested in unit-versal2-el3.c. */
#ifndef __ASSEMBLER__
static inline int versal2_el3_handoff_ok(uint64_t bl31_entry,
                                         uint64_t bl33_entry,
                                         uint64_t bl33_base,
                                         uint64_t wb_lo,
                                         uint64_t wb_hi)
{
    if (bl31_entry == 0) {
        return 0;
    }
    if (bl33_entry != bl33_base) {
        return 0;
    }
    if (bl31_entry == bl33_entry) {
        return 0;
    }
    if (bl31_entry >= wb_lo) {
        if (bl31_entry < wb_hi) {
            return 0;
        }
    }
    return 1;
}

#ifdef WOLFBOOT_VERSAL2_EL3
void versal2_bl31_handoff(uintptr_t bl31_entry, uintptr_t bl33_entry);
#endif
#endif /* !__ASSEMBLER__ */

#endif /* _VERSAL2_H_ */
