/* app_versal2.c
 *
 * Test application for AMD Versal AI Edge / Prime Gen 2 (VEK385).
 *
 * Prints a stable version marker ("TESTAPP-VERSION: N") for the QEMU
 * feature tests (tools/scripts/versal2/qemu/), and optionally drives
 * the A/B update flow:
 *
 *   WOLFBOOT2_TRIGGER=1  call wolfBoot_update_trigger() after printing,
 *                        i.e. "the OS received an update" - the swap
 *                        happens at the next reboot.
 *   WOLFBOOT2_CONFIRM=1  call wolfBoot_success() after printing,
 *                        confirming a successful boot of the update.
 *
 * The QEMU tests grep the markers printed below, so keep them stable.
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

#include "hal.h"
#include "hal/versal2.h"
#include "aarch64_arch.h"
#include "wolfboot/wolfboot.h"
#include "printf.h"

#ifndef TESTAPP_VERSION
#define TESTAPP_VERSION 1
#endif

void main(void)
{
#ifdef WOLFBOOT_FIXED_PARTITIONS
    uint32_t boot_version, update_version;
    uint8_t boot_state = 0;
    int have_boot_state = 0;
#endif

    hal_init();

    wolfBoot_printf("\n\n");
    wolfBoot_printf("===========================================\n");
    wolfBoot_printf(" wolfBoot Test Application - AMD Versal Gen 2\n");
    wolfBoot_printf("===========================================\n\n");

    wolfBoot_printf("Current EL: %d\n", current_el());

    /* Stable marker for the QEMU feature tests: the version this image
     * was built with. wolfBoot always boots the highest valid version,
     * so the printed value identifies which image won the A/B selection. */
    wolfBoot_printf("TESTAPP-VERSION: %d\n", TESTAPP_VERSION);

#ifdef WOLFBOOT_FIXED_PARTITIONS
    /* Get versions from both partitions (only available with fixed
     * partitions) */
    boot_version = wolfBoot_get_image_version(PART_BOOT);
    update_version = wolfBoot_get_image_version(PART_UPDATE);

    /* Print firmware versions */
    wolfBoot_printf("BOOT: Version: %d (0x%08x)\n",
                    boot_version, boot_version);
    wolfBoot_printf("UPDATE: Version: %d (0x%08x)\n",
                    update_version, update_version);

    have_boot_state =
        (wolfBoot_get_partition_state(PART_BOOT, &boot_state) == 0);
    if (have_boot_state)
        wolfBoot_printf("BOOT state: 0x%02X\n", boot_state);
#else
    wolfBoot_printf("Boot mode: Disk-based (GPT/MBR partitions)\n");
#endif

    wolfBoot_printf("Application running successfully!\n");

#ifdef WOLFBOOT2_TRIGGER
    /* Simulate the OS having stored a new image in the UPDATE partition
     * and triggering the update: the swap happens at the next reboot. */
    wolfBoot_printf("TESTAPP-TRIGGERING-UPDATE\n");
    wolfBoot_update_trigger();
    wolfBoot_printf("TESTAPP-TRIGGERED\n");
#endif

#ifdef WOLFBOOT2_CONFIRM
    /* Confirm a successful boot (e.g. of an unconfirmed update). */
    wolfBoot_printf("TESTAPP-CONFIRMING\n");
    wolfBoot_success();
    wolfBoot_printf("TESTAPP-CONFIRMED\n");
#endif

    wolfBoot_printf("\nEntering idle loop...\n");

    /* Idle loop */
    while (1) {
        __asm__ volatile("wfi");
    }
}
