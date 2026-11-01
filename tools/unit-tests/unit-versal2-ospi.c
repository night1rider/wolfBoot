/* unit-versal2-ospi.c
 *
 * Host unit test for the TARGET=versal2 OSPI driver safety logic in
 * hal/versal2.c. The safety-critical block (between OSPI_TEST_CORE_BEGIN
 * and OSPI_TEST_CORE_END) is extracted verbatim by the Makefile and run
 * against an emulated OSPI register file and an emulated NOR flash.
 *
 * What is verified (task list, section 6, plus the Q1/Q4 run-2 items):
 *   - the opcode allow-list: every allowed opcode is accepted and every
 *     forbidden opcode (protect / pin / config / lock: 42h 68h 2Ch
 *     27h/28h/29h B1h 01h E3h E4h A6h E5h C4h B9h) is refused;
 *   - the erase sizes per the MT35XU02GCBA datasheet: 4 KB (20h/21h),
 *     32 KB (52h/5Ch) and 128 KB sector (D8h/DCh) - there is no 64 KB
 *     erase on this device;
 *   - the address guard: program and erase commands may only target the
 *     wolfBoot BOOT / UPDATE / SWAP partitions; anything else (AMD Image
 *     Selector / Image Recovery / metadata, Bank B, the partition tail)
 *     is refused - including a 128 KB erase straddling a partition end;
 *   - the page-program bound: a page program must not cross a 256-byte
 *     page boundary;
 *   - the erase chunker (ext_flash_erase): 128 KB / 32 KB / 4 KB
 *     granularity selection;
 *   - flash mode detection: direct ID read, and the fallback (software
 *     reset 66h/99h + volatile 1-bit SDR config 81h, never nonvolatile
 *     B1h) when the first read fails; refusal when no flash is present.
 *
 * A second variant (unit-versal2-ospi-dma, built with
 * -DWOLFBOOT_OSPI_DMA=1) additionally verifies the DMA read path's
 * register sequence, DONE polling / W1C clear, timeout and alignment
 * refusals.
 *
 * The extracted block references ospi_reg_read() / ospi_reg_write() and
 * hal_delay_us(); the test provides emulated versions. It uses the
 * register definitions from hal/versal2.h (host-clean) and the partition
 * geometry of the example config (config/examples/versal2_vek385.config,
 * run-13 layout: BOOT 0x1DC0000, UPDATE 0x49C0000, SWAP 0xFA40000, after
 * the 8 MB BOOT.BIN reservation 0x15C0000-0x1DBFFFF - run 13 layout
 * decision: 8 MB BOOT.BIN reservation, AMD BOOT.BIN 5.31 MiB,
 * evidence/mdom-bank-analysis-run9.txt; the run-3 values were
 * BOOT 0x19C0000, UPDATE 0x4600000).
 *
 * The SWAP partition size (WOLFBOOT_SECTOR_SIZE in the config) may be
 * overridden at run time with the WOLFBOOT_SECTOR_SIZE environment
 * variable (the `make run` target and the GitHub workflow run this test
 * with WOLFBOOT_SECTOR_SIZE=0x400); the driver core's ospi_swap_size is
 * set from it in setup(), so the guard is exercised with a smaller
 * sector geometry.
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

/* Register offsets and STIG field definitions (host-clean). */
#include "versal2.h"

/* Partition geometry: config/examples/versal2_vek385.config (run-13
 * layout; Bank A's first 8 MB 0x15C0000-0x1DBFFFF are reserved for
 * BOOT.BIN, so BOOT starts at 0x1DC0000). Old (run 3-12) values, kept
 * for reference (run 13 layout decision: 8 MB BOOT.BIN reservation, AMD
 * BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
 *   #define WOLFBOOT_PARTITION_BOOT_ADDRESS   0x19C0000UL
 *   #define WOLFBOOT_PARTITION_UPDATE_ADDRESS 0x4600000UL
 */
#define WOLFBOOT_PARTITION_BOOT_ADDRESS   0x1DC0000UL
#define WOLFBOOT_PARTITION_UPDATE_ADDRESS 0x49C0000UL
#define WOLFBOOT_PARTITION_SWAP_ADDRESS   0xFA40000UL
#define WOLFBOOT_PARTITION_SIZE           0x2C00000UL
#define WOLFBOOT_SECTOR_SIZE              0x10000UL

/* The BOOT.BIN reservation at the start of Bank A (run 13 layout
 * decision): 0x15C0000-0x1DBFFFF (8 MB). AMD's real BOOT.BIN ends at
 * 0x1B0FE40 (evidence/mdom-bank-analysis-run9.txt); the old run-3 4 MB
 * reservation overlapped it in 0x19C0000-0x1B0FE40. */
#define BOOTBIN_RESERVATION_START         0x15C0000UL
#define BOOTBIN_RESERVATION_END           0x1DBFFFFUL  /* inclusive */
#define BOOTBIN_OLD_OVERLAP_START         0x19C0000UL
#define BOOTBIN_OLD_OVERLAP_END           0x1B0FE40UL  /* inclusive */

/* Emulated OSPI module register file (APB 0x000-0x1FF + CSU DMA at
 * 0x1000-0x1828 + safety check 0x1FF8). */
#define EMU_REG_MAX   0x2000
static uint32_t emu_regs[EMU_REG_MAX];

/* Command/opcode trace: ring for order assertions, histogram for counts. */
#define EMU_CMD_RING  64
static uint32_t emu_cmd_ring[EMU_CMD_RING];
static int      emu_cmd_count;
static uint32_t emu_op_hist[256];

/* Emulated NOR flash state for the flag-status / ID readback. */
static int emu_flash_alive;      /* 0: no response (ID all FF), 1: alive */
static int emu_flash_permanent;  /* 1: 99h reset does NOT revive it */
int emu_dma_stall = 0;           /* DMA variant: stall the transfer */
/* Last 81h (write volatile configuration) command: address + data. */
static uint32_t emu_81_addr;
static uint32_t emu_81_data;

static inline uint32_t ospi_reg_read(uint32_t off)
{
    if (off >= EMU_REG_MAX)
        return 0;
    return emu_regs[off];
}

static inline void ospi_reg_write(uint32_t off, uint32_t val)
{
    if (off >= EMU_REG_MAX)
        return;
    /* Interrupt status registers are W1C: a write with 1s clears those
     * bits (AM028: "requires a specific write=1 to clear"). */
    if (off == OSPI_R_DMA_DST_I_STS || off == OSPI_R_DMA_SRC_I_STS)
        emu_regs[off] &= ~val;
    else
        emu_regs[off] = val;

    if (off == OSPI_R_FLASH_CMD_CTRL_REG) {
        int opcode = (val >> OSPI_FCC_CMD_OPCODE_SHIFT) & 0xFF;

        emu_cmd_ring[emu_cmd_count % EMU_CMD_RING] = (uint32_t)opcode;
        emu_op_hist[opcode]++;
        emu_cmd_count++;
        /* Model: the controller runs the burst to completion. */
        emu_regs[off] = val & (uint32_t)~OSPI_FCC_CMD_EXEC_STATUS;
        /* Readback registers: flag status ready; ID per flash state
         * (the driver reads a single byte for both commands). A dead
         * device reads all 0xFF on the bus (high-Z pulled up). */
        if (opcode == 0x70) {
            emu_regs[OSPI_R_FLASH_RD_DATA_LOWER_REG] =
                emu_flash_alive ? 0x80 : 0xFFFFFFFF;
            emu_regs[OSPI_R_FLASH_RD_DATA_UPPER_REG] =
                emu_flash_alive ? 0 : 0xFFFFFFFF;
        }
        else if (opcode == 0x9F) {
            emu_regs[OSPI_R_FLASH_RD_DATA_LOWER_REG] =
                emu_flash_alive ? 0x1C5B2C : 0xFFFFFFFF;
            emu_regs[OSPI_R_FLASH_RD_DATA_UPPER_REG] =
                emu_flash_alive ? 0 : 0xFFFFFFFF;
        }
        else
            emu_regs[OSPI_R_FLASH_RD_DATA_LOWER_REG] = 0;
        /* Software reset (RESET MEMORY 99h) revives a flash that was
         * left in an unknown mode - the scenario the mode-detection
         * fallback exists for - unless the device is permanently dead. */
        if (opcode == 0x99 && !emu_flash_permanent)
            emu_flash_alive = 1;
        /* Record the volatile configuration write (81h) payload for
         * assertions: register address + first data byte. */
        if (opcode == 0x81) {
            emu_81_addr = emu_regs[OSPI_R_FLASH_CMD_ADDR_REG];
            emu_81_data = emu_regs[OSPI_R_FLASH_WR_DATA_LOWER_REG];
        }
    }
    else if (off == OSPI_R_IND_RD_XFER_CTRL_REG && (val & OSPI_IND_RD_START)) {
        /* Model (DMA variant): the indirect read + DMA transfer completes
         * immediately and the DST channel reports DONE - unless stalled. */
        if (!emu_dma_stall)
            emu_regs[OSPI_R_DMA_DST_I_STS] |= OSPI_DMA_DST_I_STS_DONE;
    }
}

static void hal_delay_us(uint32_t us)
{
    (void)us;   /* no-op on the host */
}

static int emu_seen_opcode(uint32_t op)
{
    return emu_op_hist[op] != 0;
}

static int emu_opcode_count(uint32_t op)
{
    return (int)emu_op_hist[op];
}

/* Effective SWAP sector size: the config default, overridable at run
 * time with the WOLFBOOT_SECTOR_SIZE environment variable (hex or
 * decimal), so the workflow's WOLFBOOT_SECTOR_SIZE=0x400 run exercises
 * the guard with a smaller sector through the real driver core. */
static uint32_t test_sector_size(void)
{
    const char *e = getenv("WOLFBOOT_SECTOR_SIZE");

    if (e != NULL) {
        unsigned long v = strtoul(e, NULL, 0);

        if (v != 0)
            return (uint32_t)v;
    }
    return (uint32_t)WOLFBOOT_SECTOR_SIZE;
}

/* The real, extracted safety-critical block from hal/versal2.c. */
#include "versal2_ospi_extract.h"

/* ------------------------------------------------------------------ */
/* Opcode allow-list                                                  */
/* ------------------------------------------------------------------ */

static const uint8_t allowed_ops[] = {
    0x9F, 0x9E, 0x05, 0x70, 0x50, 0x06, 0x04,
    0x03, 0x0B, 0x13, 0x0C, 0x7C, 0xCC, 0x8B, 0xCB, 0xFD,
    0x02, 0x12, 0x82, 0x84, 0xC2, 0x8E,
    0x20, 0x21, 0x52, 0x5C, 0xD8, 0xDC,
    0xB7, 0xE9, 0x81, 0x85, 0x66, 0x99, 0x5A,
};

/* The forbidden opcodes from the task list (section 6): protect, pin,
 * lock, config, and legacy/volatile-op-override opcodes. */
static const uint8_t forbidden_ops[] = {
    0x42, 0x68, 0x2C,
    0x27, 0x28, 0x29,
    0xB1, 0x01,
    0xE3, 0xE4, 0xA6, 0xE5,
    0xC4, 0xB9,
};

START_TEST(test_opcode_allow_list_accepts)
{
    int i;
    for (i = 0; i < (int)(sizeof(allowed_ops) / sizeof(allowed_ops[0])); i++)
        fail_unless(ospi_op_allowed(allowed_ops[i]) == 1,
                    "allowed opcode 0x%02X was refused", allowed_ops[i]);
}
END_TEST

START_TEST(test_opcode_allow_list_refuses_forbidden)
{
    int i;
    for (i = 0; i < (int)(sizeof(forbidden_ops) / sizeof(forbidden_ops[0])); i++)
        fail_unless(ospi_op_allowed(forbidden_ops[i]) == 0,
                    "forbidden opcode 0x%02X was accepted", forbidden_ops[i]);
}
END_TEST

START_TEST(test_stig_refuses_forbidden_opcode)
{
    int i;
    uint8_t rdata[8];
    for (i = 0; i < (int)(sizeof(forbidden_ops) / sizeof(forbidden_ops[0])); i++) {
        int before = emu_cmd_count;
        int ret = ospi_stig(forbidden_ops[i], 0, 0, NULL, 0, rdata, 0);
        fail_unless(ret == -1,
                    "forbidden opcode 0x%02X was issued (ret=%d)",
                    forbidden_ops[i], ret);
        fail_unless(emu_cmd_count == before,
                    "forbidden opcode 0x%02X reached the controller",
                    forbidden_ops[i]);
    }
}
END_TEST

/* ------------------------------------------------------------------ */
/* Erase sizes (MT35XU02GCBA datasheet, Table 21)                     */
/* ------------------------------------------------------------------ */

START_TEST(test_erase_op_sizes)
{
    /* 4 KB / 32 KB / 128 KB; no 64 KB erase exists on this device. */
    fail_unless(ospi_erase_op_size(0x20) == 0x1000, "0x20 size");
    fail_unless(ospi_erase_op_size(0x21) == 0x1000, "0x21 size");
    fail_unless(ospi_erase_op_size(0x52) == 0x8000, "0x52 size");
    fail_unless(ospi_erase_op_size(0x5C) == 0x8000, "0x5C size");
    fail_unless(ospi_erase_op_size(0xD8) == 0x20000, "0xD8 size (128 KB)");
    fail_unless(ospi_erase_op_size(0xDC) == 0x20000, "0xDC size (128 KB)");
    fail_unless(ospi_erase_op_size(0x13) == 0, "0x13 is not an erase");
    fail_unless(ospi_erase_op_size(0xC4) == 0, "die erase (0xC4) not modelled");
}
END_TEST

START_TEST(test_erase_region_only_documented_sizes)
{
    /* The region helper accepts only the device's erase granularities
     * (addresses inside UPDATE). Old (run 3-12) checks, kept for
     * reference (run 13 layout decision: 8 MB BOOT.BIN reservation,
     * AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
    fail_unless(ospi_erase_region(0x4600000, 0x1000) == 0, "4 KB erase");
    fail_unless(ospi_erase_region(0x4600000, 0x8000) == 0, "32 KB erase");
    fail_unless(ospi_erase_region(0x4600000, 0x20000) == 0, "128 KB erase");
    fail_unless(ospi_erase_region(0x4600000, 0x10000) == -1,
                "64 KB is not a device granularity");
    fail_unless(ospi_erase_region(0x4600004, 0x1000) == -1,
                "unaligned 4 KB erase");
     */
    fail_unless(ospi_erase_region(0x49C0000, 0x1000) == 0, "4 KB erase");
    fail_unless(ospi_erase_region(0x49C0000, 0x8000) == 0, "32 KB erase");
    fail_unless(ospi_erase_region(0x49C0000, 0x20000) == 0, "128 KB erase");
    fail_unless(ospi_erase_region(0x49C0000, 0x10000) == -1,
                "64 KB is not a device granularity");
    fail_unless(ospi_erase_region(0x49C0004, 0x1000) == -1,
                "unaligned 4 KB erase");
}
END_TEST

/* ------------------------------------------------------------------ */
/* Address guard                                                      */
/* ------------------------------------------------------------------ */

START_TEST(test_addr_guard_accepts_partitions)
{
    /* A 4 KB erase anywhere inside each partition must be allowed.
     * Old (run 3-12) checks, kept for reference (run 13 layout decision:
     * 8 MB BOOT.BIN reservation, AMD BOOT.BIN 5.31 MiB,
     * evidence/mdom-bank-analysis-run9.txt):
    fail_unless(ospi_addr_guard_ok(0x19C0000, 0x1000) == 1, "BOOT start");
    fail_unless(ospi_addr_guard_ok(0x19C0000 + 0x2C00000 - 0x1000, 0x1000) == 1,
                "BOOT tail");
    fail_unless(ospi_addr_guard_ok(0x4600000, 0x1000) == 1, "UPDATE start");
    fail_unless(ospi_addr_guard_ok(0x4600000 + 0x2C00000 - 0x1000, 0x1000) == 1,
                "UPDATE tail");
    fail_unless(ospi_addr_guard_ok(0x4600000, 0x20000) == 1, "UPDATE 128 KB");
    fail_unless(ospi_addr_guard_ok(0x4600000 + 0x2C00000 - 0x20000, 0x20000)
                == 1, "UPDATE last 128 KB");
    */
    fail_unless(ospi_addr_guard_ok(0x1DC0000, 0x1000) == 1, "BOOT start");
    fail_unless(ospi_addr_guard_ok(0x1DC0000 + 0x2C00000 - 0x1000, 0x1000) == 1,
                "BOOT tail");
    fail_unless(ospi_addr_guard_ok(0x49C0000, 0x1000) == 1, "UPDATE start");
    fail_unless(ospi_addr_guard_ok(0x49C0000 + 0x2C00000 - 0x1000, 0x1000) == 1,
                "UPDATE tail");
    fail_unless(ospi_addr_guard_ok(0x49C0000, 0x20000) == 1, "UPDATE 128 KB");
    fail_unless(ospi_addr_guard_ok(0x49C0000 + 0x2C00000 - 0x20000, 0x20000)
                == 1, "UPDATE last 128 KB");
    /* The full SWAP sector (config sector size, or the run-time
     * WOLFBOOT_SECTOR_SIZE override) is inside the partition. */
    fail_unless(ospi_addr_guard_ok(0xFA40000, test_sector_size()) == 1,
                "SWAP (full sector)");
    fail_unless(ospi_addr_guard_ok(0x2000000, 0x100) == 1, "mid-BOOT program");
}
END_TEST

START_TEST(test_addr_guard_refuses_out_of_range)
{
    /* AMD Image Selector / Image Recovery / metadata (0x000000-0x015BFFFF). */
    fail_unless(ospi_addr_guard_ok(0x0000000, 0x1000) == 0, "Image Selector @0");
    fail_unless(ospi_addr_guard_ok(0x0100000, 0x1000) == 0, "recovery @0x100000");
    /* Bank B (0x08000000 and up). */
    fail_unless(ospi_addr_guard_ok(0x08000000, 0x1000) == 0, "Bank B");
    /* Tail past the end of the UPDATE partition (0x7600000 is the DTS
     * boot slot region, not a wolfBoot partition; old run 3-12 end
     * 0x7200000, kept for reference - run 13 layout decision: 8 MB
     * BOOT.BIN reservation, AMD BOOT.BIN 5.31 MiB,
     * evidence/mdom-bank-analysis-run9.txt):
    fail_unless(ospi_addr_guard_ok(0x4600000 + 0x2C00000, 0x1000) == 0,
                "UPDATE tail overrun");
    fail_unless(ospi_addr_guard_ok(0x4600000 + 0x2C00000 - 0x20000, 0x20000)
                == 1, "last full 128 KB");
    fail_unless(ospi_addr_guard_ok(0x4600000 + 0x2C00000 - 0x10000, 0x20000)
                == 0, "128 KB straddling UPDATE end");
    */
    fail_unless(ospi_addr_guard_ok(0x49C0000 + 0x2C00000, 0x1000) == 0,
                "UPDATE tail overrun");
    /* The last full 128 KB of UPDATE is fine... */
    fail_unless(ospi_addr_guard_ok(0x49C0000 + 0x2C00000 - 0x20000, 0x20000)
                == 1, "last full 128 KB");
    /* ...but a 128 KB erase starting 64 KB earlier would straddle the end
     * of UPDATE into the DTS boot slot - it must be refused. */
    fail_unless(ospi_addr_guard_ok(0x49C0000 + 0x2C00000 - 0x10000, 0x20000)
                == 0, "128 KB straddling UPDATE end");
    /* A region straddling the end of the SWAP partition (with the default
     * 64 KB sector this crosses the tail; with the run-time override the
     * start is already past the smaller partition - refused either way). */
    fail_unless(ospi_addr_guard_ok(0xFA40000 + 0x8000, 0x10000) == 0,
                "SWAP overrun");
    /* A 0-length region is never "inside" a partition. Old (run 3-12)
     * address, kept for reference (run 13 layout decision: 8 MB BOOT.BIN
     * reservation, AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
    fail_unless(ospi_addr_guard_ok(0x19C0000, 0) == 0, "zero length");
     */
    fail_unless(ospi_addr_guard_ok(0x1DC0000, 0) == 0, "zero length");
}
END_TEST

/* Run 13: the BOOT.BIN reservation at the start of Bank A must be
 * refused for every program and erase. AMD's real BOOT.BIN occupies
 * 0x15C0000-0x1B0FE40 (5.31 MiB; evidence/mdom-bank-analysis-run9.txt,
 * evidence/mdom-embedded-manifest.json); the old run-3 4 MB reservation
 * overlapped it in 0x19C0000-0x1B0FE40. This test sweeps the WHOLE
 * 8 MB reservation 0x15C0000-0x1DBFFFF at every 128 KB sector boundary
 * (erase) and every 4 KB subsector boundary (program), plus the old
 * overlap area 0x19C0000-0x1B0FE40 at 128 KB / 4 KB aligned points, and
 * checks the guard boundary: the first 4 KB of the BOOT partition at
 * 0x1DC0000 (right after the reservation end 0x1DBFFFF) is accepted. */
START_TEST(test_bootbin_reservation_refused)
{
    uint32_t addr;
    int before = emu_cmd_count;

    /* Every 128 KB sector erase starting at a 128 KB boundary inside the
     * reservation must be refused (64 sectors, the last one at
     * 0x1DA0000 covering 0x1DA0000-0x1DBFFFF). */
    for (addr = BOOTBIN_RESERVATION_START;
         addr <= 0x1DA0000; addr += 0x20000) {
        fail_unless(ospi_addr_guard_ok(addr, 0x20000) == 0,
                    "128 KB erase at 0x%08lX inside the BOOT.BIN reservation was accepted",
                    (unsigned long)addr);
        fail_unless(ospi_stig(0xDC, addr, 4, NULL, 0, NULL, 0) == -1,
                    "ospi_stig 0xDC erase at 0x%08lX reached the guard-pass path",
                    (unsigned long)addr);
    }
    /* Every 4 KB page program starting at a 4 KB boundary inside the
     * reservation must be refused (2048 subsectors). */
    for (addr = BOOTBIN_RESERVATION_START;
         addr < BOOTBIN_RESERVATION_START + 0x800000; addr += 0x1000) {
        fail_unless(ospi_addr_guard_ok(addr, 0x1000) == 0,
                    "4 KB program at 0x%08lX inside the BOOT.BIN reservation was accepted",
                    (unsigned long)addr);
    }
    /* The old overlap area 0x19C0000-0x1B0FE40 (run-3 BOOT start through
     * the end of AMD's real 5.31 MiB BOOT.BIN) at 128 KB aligned erase
     * boundaries and 4 KB aligned program boundaries. (The 128 KB
     * boundaries inside this area are a subset of the reservation sweep
     * above; the area's 4 KB pages are all covered by the reservation
     * program sweep, and the explicit points below pin the boundary
     * pages of the overlap itself.) */
    fail_unless(ospi_addr_guard_ok(BOOTBIN_OLD_OVERLAP_START, 0x20000) == 0,
                "128 KB erase at the old overlap start (0x19C0000) was accepted");
    fail_unless(ospi_addr_guard_ok(0x1B00000, 0x1000) == 0,
                "4 KB program at 0x1B00000 (inside the old overlap area) was accepted");
    {
        /* Last 4 KB-aligned program window inside 0x19C0000-0x1B0FE40:
         * 0x1B0F000 + 0x1000 ends at 0x1B10000 (the guard is per-page, so
         * the page 0x1B0F000-0x1B0FFFF is checked as a whole; its start
         * is inside the old overlap area and inside the reservation). */
        fail_unless(ospi_addr_guard_ok(0x1B0F000, 0x1000) == 0,
                    "4 KB program at 0x1B0F000 (last page of the old overlap area) was accepted");
    }
    fail_unless(ospi_stig(0x12, BOOTBIN_RESERVATION_START, 4, (const uint8_t *)"x", 4, NULL, 0) == -1,
                "page program at the reservation start not refused");
    fail_unless(ospi_stig(0x12, BOOTBIN_OLD_OVERLAP_START, 4, (const uint8_t *)"x", 4, NULL, 0) == -1,
                "page program at the old overlap start (0x19C0000) not refused");
    /* Boundary: the first 4 KB of the BOOT partition, right after the
     * reservation end (0x1DBFFFF), must be ACCEPTED. */
    fail_unless(ospi_addr_guard_ok(0x1DC0000, 0x1000) == 1,
                "BOOT start (just past the reservation end) was refused");
    /* Nothing may have reached the controller (every refused command is
     * dropped before the register write). */
    fail_unless(emu_cmd_count == before,
                "refused reservation erase/program reached the flash");
}
END_TEST

START_TEST(test_stig_refuses_out_of_range_program)
{
    uint8_t wdata[4] = { 0xAA, 0xBB, 0xCC, 0xDD };
    int before = emu_cmd_count;

    /* Page program (0x12) to the Image Selector area must be refused. */
    fail_unless(ospi_stig(0x12, 0x0000000, 4, wdata, 4, NULL, 0) == -1,
                "program to 0x0 (Image Selector) not refused");
    /* Page program to Bank B must be refused. */
    fail_unless(ospi_stig(0x12, 0x08000000, 4, wdata, 4, NULL, 0) == -1,
                "program to Bank B not refused");
    /* Nothing must have reached the controller. */
    fail_unless(emu_cmd_count == before, "refused program reached the flash");
}
END_TEST

START_TEST(test_stig_refuses_out_of_range_erase)
{
    int before = emu_cmd_count;

    /* 4 KB subsector erase (0x21) to the Image Selector area. */
    fail_unless(ospi_stig(0x21, 0x0000000, 4, NULL, 0, NULL, 0) == -1,
                "erase to 0x0 (Image Selector) not refused");
    /* 128 KB sector erase (0xDC) straddling the end of the BOOT
     * partition. Old (run 3-12) checks, kept for reference (run 13
     * layout decision: 8 MB BOOT.BIN reservation, AMD BOOT.BIN 5.31 MiB,
     * evidence/mdom-bank-analysis-run9.txt):
    fail_unless(ospi_stig(0xDC, 0x19C0000 + 0x2C00000 - 0x2000, 4,
                          NULL, 0, NULL, 0) == -1,
                "erase straddling BOOT end not refused");
    fail_unless(ospi_stig(0xDC, 0x19C0000 + 0x2C00000 - 0x10000, 4,
                          NULL, 0, NULL, 0) == -1,
                "128 KB erase straddling BOOT end not refused");
    fail_unless(ospi_stig(0xDC, 0x4600000 + 0x2C00000, 4,
                          NULL, 0, NULL, 0) == -1,
                "erase at UPDATE end (DTS slot) not refused");
     */
    /* 128 KB sector erase (0xDC) straddling the end of the BOOT
     * partition (0x1DC0000 + 0x2C00000 = 0x49C0000). 0xDC is the 128 KB
     * sector erase on the MT35XU02GCBA (datasheet Table 32 ERASE
     * Operations, p50: "4-BYTE SECTOR ERASE DCh"; the memory is uniform
     * 128 KB sectors, Table 2, p13). */
    fail_unless(ospi_stig(0xDC, 0x1DC0000 + 0x2C00000 - 0x2000, 4,
                          NULL, 0, NULL, 0) == -1,
                "erase straddling BOOT end not refused");
    fail_unless(ospi_stig(0xDC, 0x1DC0000 + 0x2C00000 - 0x10000, 4,
                          NULL, 0, NULL, 0) == -1,
                "128 KB erase straddling BOOT end not refused");
    /* 128 KB erase just past the end of UPDATE into the DTS slot. */
    fail_unless(ospi_stig(0xDC, 0x49C0000 + 0x2C00000, 4,
                          NULL, 0, NULL, 0) == -1,
                "erase at UPDATE end (DTS slot) not refused");
    fail_unless(emu_cmd_count == before, "refused erase reached the flash");
}
END_TEST

START_TEST(test_stig_accepts_in_range)
{
    uint8_t wdata[4] = { 0x11, 0x22, 0x33, 0x44 };

    /* Page program to the middle of the BOOT partition. Old (run 3-12)
     * checks, kept for reference (run 13 layout decision: 8 MB BOOT.BIN
     * reservation, AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
    fail_unless(ospi_stig(0x12, 0x19D0000, 4, wdata, 4, NULL, 0) == 0,
                "in-range program refused");
    fail_unless(ospi_stig(0x21, 0x4600000, 4, NULL, 0, NULL, 0) == 0,
                "in-range erase refused");
    fail_unless(ospi_stig(0xDC, 0x4600000, 4, NULL, 0, NULL, 0) == 0,
                "128 KB in-range erase refused");
     */
    fail_unless(ospi_stig(0x12, 0x1DD0000, 4, wdata, 4, NULL, 0) == 0,
                "in-range program refused");
    fail_unless(emu_cmd_ring[(emu_cmd_count - 1) % EMU_CMD_RING] == 0x12,
                "wrong opcode issued");
    /* 4 KB erase to the start of the UPDATE partition. */
    fail_unless(ospi_stig(0x21, 0x49C0000, 4, NULL, 0, NULL, 0) == 0,
                "in-range erase refused");
    fail_unless(emu_cmd_ring[(emu_cmd_count - 1) % EMU_CMD_RING] == 0x21,
                "wrong erase opcode issued");
    /* 128 KB erase at the start of UPDATE. */
    fail_unless(ospi_stig(0xDC, 0x49C0000, 4, NULL, 0, NULL, 0) == 0,
                "128 KB in-range erase refused");
    fail_unless(emu_cmd_ring[(emu_cmd_count - 1) % EMU_CMD_RING] == 0xDC,
                "wrong 128 KB erase opcode issued");
    /* Address-less Write Enable. */
    fail_unless(ospi_stig(0x06, 0, 0, NULL, 0, NULL, 0) == 0, "WREN refused");
}
END_TEST

START_TEST(test_stig_refuses_page_crossing_program)
{
    uint8_t wdata[8];
    int before = emu_cmd_count;

    memset(wdata, 0x5A, sizeof(wdata));
    /* A program starting 4 bytes from a page end and writing 8 bytes would
     * cross the 256-byte boundary; the driver must refuse it. Old (run 3-12)
     * addresses, kept for reference (run 13 layout decision: 8 MB BOOT.BIN
     * reservation, AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
    uint32_t addr = 0x19C0000 + 0x100 - 4;   (old: mid-BOOT, 4B from page end)
    fail_unless(ospi_stig(0x12, 0x19C0100, 4, wdata, 8, NULL, 0) == 0,
                "page-aligned 8B program refused");
     */
    uint32_t addr = 0x1DC0000 + 0x100 - 4;   /* mid-BOOT, 4B from page end */
    fail_unless((addr & 0xFF) == 0xFC, "test premise (address at page-4)");
    fail_unless(ospi_stig(0x12, addr, 4, wdata, 8, NULL, 0) == -1,
                "page-crossing program not refused");
    fail_unless(emu_cmd_count == before, "page-crossing program reached flash");
    /* The same 8 bytes starting on a page boundary is fine. */
    fail_unless(ospi_stig(0x12, 0x1DC0100, 4, wdata, 8, NULL, 0) == 0,
                "page-aligned 8B program refused");
}
END_TEST

/* ------------------------------------------------------------------ */
/* Erase chunker (ext_flash_erase)                                    */
/* ------------------------------------------------------------------ */

START_TEST(test_erase_chunker_128k)
{
    /* Old (run 3-12) check, kept for reference (run 13 layout decision:
     * 8 MB BOOT.BIN reservation, AMD BOOT.BIN 5.31 MiB,
     * evidence/mdom-bank-analysis-run9.txt):
    fail_unless(ext_flash_erase(0x4600000, 0x20000) == 0x20000,
                "128 KB erase failed");
     */
    fail_unless(ext_flash_erase(0x49C0000, 0x20000) == 0x20000,
                "128 KB erase failed");
    fail_unless(emu_opcode_count(0xDC) == 1, "expected one 0xDC sector erase");
    fail_unless(emu_opcode_count(0x06) >= 1, "erase without WREN");
}
END_TEST

START_TEST(test_erase_chunker_64k_as_two_32k)
{
    /* 64 KB erase test case (kept from run 1/2). The MT35XU02GCBA has
     * no native 64 KB erase (datasheet Table 21/32, p32/p50: only 4 KB
     * 20h/21h, 32 KB 52h/5Ch and the 128 KB sector D8h/DCh; the memory
     * is uniform 128 KB sectors, Table 2, p13), so the driver erases a
     * 64 KB request with two 32 KB (0x5C) erases. Run 1's expectation,
     * kept for the record (proven wrong by the datasheet pages above):
     *   fail_unless(ext_flash_erase(0xFA40000, 0x10000) == 0x10000,
     *               "64 KB erase failed");
     *   fail_unless(emu_opcode_count(0xDC) == 1,
     *               "expected one 0xDC 64 KB erase");
     * The region is inside a wolfBoot partition (run-3: UPDATE, run-13:
     * BOOT - 0x4800000 sits inside the new BOOT partition
     * 0x1DC0000-0x49BFFFF; the address is unchanged, only the partition
     * identity moved with the run-13 layout) and NOT the SWAP partition,
     * so the test also passes the WOLFBOOT_SECTOR_SIZE=0x400 run, in
     * which the SWAP sector is only 1 KB and a 64 KB SWAP erase would be
     * refused. */
    fail_unless(ext_flash_erase(0x4800000, 0x10000) == 0x10000,
                "64 KB erase failed");
    fail_unless(emu_opcode_count(0x5C) == 2, "expected two 0x5C 32 KB erases");
    fail_unless(emu_opcode_count(0xDC) == 0,
                "0xDC used where it would erase 128 KB");
}
END_TEST

START_TEST(test_erase_chunker_partition)
{
    /* Erasing the whole UPDATE partition (44 MB = 352 x 128 KB) must use
     * only 128 KB sector erases, all inside the partition. Old (run 3-12)
     * check, kept for reference (run 13 layout decision: 8 MB BOOT.BIN
     * reservation, AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
    fail_unless(ext_flash_erase(0x4600000, 0x2C00000) == 0x2C00000,
                "partition erase failed");
     */
    fail_unless(ext_flash_erase(0x49C0000, 0x2C00000) == 0x2C00000,
                "partition erase failed");
    fail_unless(emu_opcode_count(0xDC) == 352,
                "expected 352 x 128 KB erases, got %d",
                emu_opcode_count(0xDC));
    fail_unless(emu_opcode_count(0x5C) == 0 && emu_opcode_count(0x21) == 0,
                "partition erase used a smaller granularity");
}
END_TEST

START_TEST(test_erase_refuses_bad_geometry)
{
    fail_unless(ext_flash_erase(0x4200004, 0x1000) == -1, "unaligned start");
    fail_unless(ext_flash_erase(0x4200000, 0x1200) == -1, "non-4K length");
    fail_unless(ext_flash_erase(0x4200000, 0) == 0, "zero length is a no-op");
}
END_TEST

/* ------------------------------------------------------------------ */
/* Flash mode detection (Q4)                                          */
/* ------------------------------------------------------------------ */

START_TEST(test_mode_detect_direct_id)
{
    uint8_t id[3];

    /* Flash answers in its current mode: detected on the first read. */
    emu_flash_alive = 1;
    fail_unless(ospi_flash_mode_detect(id) == 0, "direct detection failed");
    fail_unless(id[0] == 0x2C && id[1] == 0x5B && id[2] == 0x1C,
                "wrong ID %02X %02X %02X", id[0], id[1], id[2]);
    fail_unless(!emu_seen_opcode(0x66), "no reset needed for direct detect");
}
END_TEST

START_TEST(test_mode_detect_fallback_reset_1bit_sdr)
{
    uint8_t id[3];
    int i;
    int n = 0;

    /* Flash does not answer (left in an unknown mode by the PLM). */
    emu_flash_alive = 0;
    fail_unless(ospi_flash_mode_detect(id) == 0, "fallback detection failed");
    fail_unless(id[0] == 0x2C && id[1] == 0x5B && id[2] == 0x1C,
                "wrong ID after fallback");
    /* The fallback sequence: 66h (reset enable), 99h (reset memory),
     * then the volatile 1-bit SDR configuration (81h). */
    fail_unless(emu_seen_opcode(0x66), "RESET ENABLE missing");
    fail_unless(emu_seen_opcode(0x99), "RESET MEMORY missing");
    fail_unless(emu_seen_opcode(0x81), "volatile config (81h) missing");
    /* Never the nonvolatile configuration write. */
    fail_unless(!emu_seen_opcode(0xB1), "nonvolatile B1h must never be used");
    /* The 81h write must target the I/O mode register (00h) with the
     * Extended SPI 1-bit SDR value (FFh) as the first data byte
     * (datasheet Figure 21 / Table 7). */
    fail_unless(emu_81_addr == 0x00, "81h wrong register (addr 0x%08lX)",
                (unsigned long)emu_81_addr);
    fail_unless((emu_81_data & 0xFF) == 0xFF, "81h wrong I/O mode value 0x%02X",
                (emu_81_data & 0xFF));
    /* Order: 66h before 99h, 99h before 81h. */
    n = emu_cmd_count < EMU_CMD_RING ? emu_cmd_count : EMU_CMD_RING;
    {
        int p66 = -1, p99 = -1, p81 = -1;

        for (i = 0; i < n; i++) {
            uint32_t op = emu_cmd_ring[i];

            if (op == 0x66 && p66 < 0)
                p66 = i;
            if (op == 0x99 && p99 < 0)
                p99 = i;
            if (op == 0x81 && p81 < 0)
                p81 = i;
        }
        fail_unless(p66 >= 0 && p99 > p66 && p81 > p99,
                    "bad fallback order (66=%d 99=%d 81=%d)", p66, p99, p81);
    }
}
END_TEST

START_TEST(test_mode_detect_no_flash)
{
    uint8_t id[3];

    /* No flash at all (permanently dead): the reset fallback cannot help
     * and the detection must report -1. */
    emu_flash_alive = 0;
    emu_flash_permanent = 1;
    fail_unless(ospi_flash_mode_detect(id) == -1,
                "permanently dead flash was detected");
    /* The fallback was still attempted (reset + volatile config). */
    fail_unless(emu_seen_opcode(0x99), "reset not attempted");
    fail_unless(emu_seen_opcode(0x81), "volatile config not attempted");
    emu_flash_permanent = 0;
}
END_TEST

/* ------------------------------------------------------------------ */
/* DMA read path (only in the -DWOLFBOOT_OSPI_DMA=1 variant)          */
/* ------------------------------------------------------------------ */
#ifdef WOLFBOOT_OSPI_DMA

static uint8_t dma_buf[4096] __attribute__((aligned(4)));

START_TEST(test_dma_refuses_unaligned)
{
    /* DMA transfers must be 4-byte aligned on both ends (AM026 p706). */
    fail_unless(ospi_dma_read(0x4200001, dma_buf, 4096) == -1,
                "unaligned address accepted");
    fail_unless(ospi_dma_read(0x4200000, dma_buf, 4095) == -1,
                "unaligned length accepted");
    fail_unless(ospi_dma_read(0x4200000, NULL, 4096) == -1, "NULL buffer");
    /* Nothing may have been triggered. */
    fail_unless((emu_regs[OSPI_R_IND_RD_XFER_CTRL_REG] & OSPI_IND_RD_START)
                == 0, "DMA triggered on a refused transfer");
}
END_TEST

START_TEST(test_dma_register_sequence)
{
    uint32_t dst = (uint32_t)(uintptr_t)dma_buf;

    fail_unless(ospi_dma_read(0x4200000, dma_buf, 4096) == 0, "DMA read failed");
    /* One-shot configuration values (AM026 Table 223 / xospipsv). */
    fail_unless(emu_regs[OSPI_R_DMA_PERIPH_CONFIG_REG] ==
                OSPI_DMA_PERIPH_CFG_64B_4B,
                "DMA_PERIPH_CONFIG 0x%08lX",
                (unsigned long)emu_regs[OSPI_R_DMA_PERIPH_CONFIG_REG]);
    fail_unless(emu_regs[OSPI_R_SRAM_PARTITION_CFG_REG] ==
                OSPI_SRAM_PARTITION_DMA_READ, "SRAM partition");
    fail_unless(emu_regs[OSPI_R_IND_RD_XFER_WATERMARK_REG] == 0, "watermark");
    /* Channels. */
    fail_unless(emu_regs[OSPI_R_DMA_DST_ADDR] == dst, "DST addr");
    fail_unless(emu_regs[OSPI_R_DMA_DST_ADDR_MSB] ==
                (uint32_t)((uintptr_t)dma_buf >> 32), "DST addr MSB");
    fail_unless(emu_regs[OSPI_R_DMA_SRC_RD_ADDR] == OSPI_IND_AHB_TRIG_BASE,
                "SRC rd addr (DAC base)");
    fail_unless(emu_regs[OSPI_R_DMA_DST_CTRL] == OSPI_DMA_DST_CTRL_DEF,
                "DST ctrl");
    /* Indirect read setup. */
    fail_unless(emu_regs[OSPI_R_IND_AHB_ADDR_TRIG_REG] == OSPI_IND_AHB_TRIG_BASE,
                "AHB trigger");
    fail_unless(emu_regs[OSPI_R_IND_TRIG_ADDR_RANGE_REG] ==
                OSPI_IND_TRIG_RANGE_64B, "trigger range (64 B)");
    fail_unless(emu_regs[OSPI_R_IND_RD_XFER_START_REG] == 0x4200000,
                "flash addr");
    fail_unless(emu_regs[OSPI_R_IND_RD_XFER_NUM_BYTES_REG] == 4096,
                "byte count");
    fail_unless(emu_regs[OSPI_R_DMA_DST_SIZE] == 4096, "DST size (bytes)");
    /* The transfer was triggered and the DONE flag was cleared (W1C). */
    fail_unless((emu_regs[OSPI_R_IND_RD_XFER_CTRL_REG] & OSPI_IND_RD_START)
                == 1, "indirect read not started");
    fail_unless((emu_regs[OSPI_R_DMA_DST_I_STS] & OSPI_DMA_DST_I_STS_DONE)
                == 0, "DST DONE not cleared");
}
END_TEST

START_TEST(test_dma_timeout_fails)
{
    int ret;

    /* Stall the transfer: the model does not set DONE, so the driver must
     * time out (OSPI_DMA_TIMEOUT is small in this unit build). */
    emu_regs[OSPI_R_DMA_DST_I_STS] = 0;
    emu_dma_stall = 1;
    ret = ospi_dma_read(0x4200000, dma_buf, 4096);
    emu_dma_stall = 0;
    fail_unless(ret == -1, "stalled DMA reported success");
}
END_TEST

#endif /* WOLFBOOT_OSPI_DMA */

/* ------------------------------------------------------------------ */

static void setup(void)
{
    memset(emu_regs, 0, sizeof(emu_regs));
    memset(emu_cmd_ring, 0, sizeof(emu_cmd_ring));
    memset(emu_op_hist, 0, sizeof(emu_op_hist));
    emu_cmd_count = 0;
    emu_flash_alive = 1;
    emu_flash_permanent = 0;
    emu_dma_stall = 0;
    emu_81_addr = 0;
    emu_81_data = 0;
    ospi_swap_size = test_sector_size();
}

static void teardown(void)
{
}

Suite *versal2_ospi_suite(void)
{
    Suite *s = suite_create("versal2-ospi");
    TCase *tc = tcase_create("versal2-ospi");

    tcase_add_checked_fixture(tc, setup, teardown);
    tcase_add_test(tc, test_opcode_allow_list_accepts);
    tcase_add_test(tc, test_opcode_allow_list_refuses_forbidden);
    tcase_add_test(tc, test_stig_refuses_forbidden_opcode);
    tcase_add_test(tc, test_erase_op_sizes);
    tcase_add_test(tc, test_erase_region_only_documented_sizes);
    tcase_add_test(tc, test_addr_guard_accepts_partitions);
    tcase_add_test(tc, test_addr_guard_refuses_out_of_range);
    tcase_add_test(tc, test_bootbin_reservation_refused);
    tcase_add_test(tc, test_stig_refuses_out_of_range_program);
    tcase_add_test(tc, test_stig_refuses_out_of_range_erase);
    tcase_add_test(tc, test_stig_accepts_in_range);
    tcase_add_test(tc, test_stig_refuses_page_crossing_program);
    tcase_add_test(tc, test_erase_chunker_128k);
    tcase_add_test(tc, test_erase_chunker_64k_as_two_32k);
    tcase_add_test(tc, test_erase_chunker_partition);
    tcase_add_test(tc, test_erase_refuses_bad_geometry);
    tcase_add_test(tc, test_mode_detect_direct_id);
    tcase_add_test(tc, test_mode_detect_fallback_reset_1bit_sdr);
    tcase_add_test(tc, test_mode_detect_no_flash);
#ifdef WOLFBOOT_OSPI_DMA
    tcase_add_test(tc, test_dma_refuses_unaligned);
    tcase_add_test(tc, test_dma_register_sequence);
    tcase_add_test(tc, test_dma_timeout_fails);
#endif
    suite_add_tcase(s, tc);

    return s;
}

int main(void)
{
    int fails;
    Suite *s = versal2_ospi_suite();
    SRunner *sr = srunner_create(s);

    srunner_run_all(sr, CK_NORMAL);
    fails = srunner_ntests_failed(sr);
    srunner_free(sr);

    return fails;
}
