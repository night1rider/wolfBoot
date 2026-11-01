/* versal2.h
 *
 * AMD Versal AI Edge / Prime Gen 2 (VEK385) - Cortex-A78AE
 *
 * PR 1 target configuration, proven in QEMU `amd-versal2-virt` (QEMU 11.1.3).
 * 11.1.3 is the latest release (2026-10-28); it is the first release line
 * that ships the amd-versal2-virt machine plus the Versal OSPI model fix
 * (register_array_get_owner, upstream commit 57abf6b1d5), so no backport
 * patch is needed. See BUILD.md.
 *
 * Boot flow (production, PR 2 territory):
 *   PLM -> PSM -> BL31 (EL3, secure) -> wolfBoot (EL2, non-secure) -> Linux
 * PLM (0-16 MB DDR) and BL31 (16-22 MB DDR) run before wolfBoot and own the
 * clocks, MIO and DDR; wolfBoot only uses the A53/A78 general-purpose
 * peripherals: UART1 console and the OSPI (Cadence) flash controller.
 *
 * In QEMU the CPU starts at EL3 (no BL31); the QEMU test script loads a tiny
 * EL3 -> EL2 trampoline that ERETs into wolfBoot at the same EL the BL31
 * hand-off would use (see tools/scripts/versal2/qemu/trampoline/).
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

/* Only include C headers when compiling C code, not assembly
 * (boot_aarch64_start.S includes this header for the MMU table). */
#ifndef __ASSEMBLER__
#include <stdint.h>
#endif /* __ASSEMBLER__ */

/* EL3 is owned by BL31 (secure). wolfBoot runs at EL2 non-secure, and
 * hands the application to EL1. */
#define EL3_SECURE     0
#define EL2_HYPERVISOR 1
#define EL1_NONSECURE  1

/* No guest hypervisor, no FPU trapping (A78AE FPU is always available). */
#define HYP_GUEST      0
#define FPU_TRAP       0

/* Cortex-A78: erratum 855873 workaround (as on Gen 1 Versal). */
#define CONFIG_ARM_ERRATA_855873 1

/* BL31 owns the GIC (distributor + redistributor at 0xE2000000 /
 * 0xE2060000 on Gen 2). wolfBoot is fully polling; it must not touch the
 * GIC (in QEMU the GIC is left uninitialized, which is fine). */
#define SKIP_GIC_INIT 1

/* Default entry level for the application. */
#if !defined(BOOT_EL1) && !defined(BOOT_EL2)
    #define BOOT_EL2 1
#endif
#if defined(BOOT_EL1) && defined(BOOT_EL2)
    #error "BOOT_EL1 and BOOT_EL2 are mutually exclusive"
#endif

/* System watchdog: the Gen 2 WWDT/SWDT base addresses differ from Gen 1 and
 * are not used in PR 1 (QEMU has no WWDT model). Refuse a WATCHDOG build
 * rather than run it against the Gen 1 address. */
#ifdef WATCHDOG
    #error "WATCHDOG is not supported on TARGET=versal2 (PR 1)"
#endif

/* ============================================================================
 * DDR layout
 * ============================================================================
 * The VEK385 DTB /memory node: 2 GB at 0x0 and 6 GB at 0x8_0000_0000.
 * QEMU amd-versal2-virt low channel: 2046 MiB at 0x0 (high channels at
 * 0x8_0000_0000+). The generic 40-bit table below only needs the low
 * window; WOLFBOOT_ORIGIN (0x40000000) and WOLFBOOT_LOAD_ADDRESS
 * (0x20000000) both live inside it. */
#define VERSAL2_DDR_0_BASE      0x00000000UL
#define VERSAL2_DDR_0_HIGH      0x7FFFFFFFUL
#define VERSAL2_DDR_1_BASE      0x800000000ULL
/* VEK385 high channel: 6 GB at 0x8_0000_0000 per the DTB (0x800000000 +
 * 0x180000000 - 1 = 0x97FFFFFFF). The MMU table does not map the high
 * channel (XPAR_PSU_DDR_1_S_AXI_* undefined -> the L1 DDR-1 block stays
 * "reserved"); PR 1 never touches it. If the PR 2 Linux image allocates
 * from the high channel, a high-DDR window must be added (PR 2 item). */
#define VERSAL2_DDR_1_HIGH      0x97FFFFFFFULL

/* Application load address (Linux kernel / FIT staging buffer) is set by
 * the config file (WOLFBOOT_LOAD_ADDRESS) and materialized in the
 * generated include/target.h; it must clear all RPU reserved regions,
 * which end at 0x1E4E7FFF on the VEK385. The example config uses
 * 0x20000000 (512 MB). */

#define CACHE_LINE_SIZE         64
#define APP_CACHE_FLUSH_SIZE    (1 * 1024 * 1024)  /* 1MB */

/* DDR defines for the MMU table setup (used by boot_aarch64_start.S). */
#define XPAR_PSU_DDR_0_S_AXI_BASEADDR   VERSAL2_DDR_0_BASE
#define XPAR_PSU_DDR_0_S_AXI_HIGHADDR   VERSAL2_DDR_0_HIGH

/* ============================================================================
 * UART (ARM PL011)
 * ============================================================================
 * Gen 2 LPD UARTs: UART0 @ 0xF1920000 (IRQ 25), UART1 @ 0xF1930000 (IRQ 26).
 * The VEK385 console is UART1 (PS UART1 on PMXC_MIO[46:47], UG1712
 * "UART Interfaces"; the prebuilt Rev B image prints on it. */
#define VERSAL2_UART0_BASE      0xF1920000UL
#define VERSAL2_UART1_BASE      0xF1930000UL

/* DEBUG_UART_NUM: 0 selects UART0, 1 (or the default) selects UART1.
 * UART1 is the VEK385 console; the example config sets
 * CFLAGS_EXTRA+=-DDEBUG_UART_NUM=1. */
#if defined(DEBUG_UART_NUM) && DEBUG_UART_NUM == 0
    #define DEBUG_UART_BASE     VERSAL2_UART0_BASE
#else
    #define DEBUG_UART_BASE     VERSAL2_UART1_BASE
#endif

/* Reference clock for the PL011 baud-rate divisors, used only when the
 * UART is found DISABLED (QEMU without the trampoline): on the board the
 * PLM/BL31 leaves the console enabled and its divisors are kept as-is.
 *
 * The VEK385 UART reference clock is firmware-programmed: AM028 CRL
 * UART1_REF_CLK_CTRL (0xEB5E0140) selects a PLL source (PPLL/RPLL/FLXPLL/
 * NPLL) and a divider, set by the PLM at boot; the documents do not pin
 * the runtime frequency to a single value. The documented limit is
 * FUART_REF_CLK <= 100 MHz (DS1021, "PS UART Controller Interface",
 * Table 51), and AM026 ch. 63 (p670) gives the same integer + 6-bit
 * fractional divisor math as the PL011 formula below, with LPD_LSBUS_CLK
 * "typically 100 MHz". The default below is therefore 100 MHz; override
 * with -DDEBUG_UART_CLK_HZ=<hz> in the config if a board's PLM uses a
 * different rate. */
#ifndef DEBUG_UART_CLK_HZ
    #define DEBUG_UART_CLK_HZ     100000000UL
#endif

/* PL011 baud-rate divisors for a UART reference clock. AM026 ch. 63
 * p670 (Versal AI Edge / Prime Gen 2 TRM, "Baud Rate Divider and Clock
 * Dependencies"): the divider output clock (Baud16) is 16x the desired
 * I/O baud rate, so
 *   Baud_Rate_Divisor = UARTx_REF_CLK / (16 x baud)
 *   IBRD  [DIVINT]  = integer part of the divisor
 *   FBRD  [DIVFRAC] = Integer((divisor fraction x 64) + 0.5)
 * Returns 0/0 (a safe "no change" pair) when the clock cannot produce
 * the baud rate (FCLK < 16 * BAUD, the AM026/PL011 lower bound; 0 inputs
 * too) or when the integer part does not fit the 16-bit DIVINT field.
 * All math is 64-bit: for any 32-bit BAUD, 16*BAUD < 2^37 and
 * (FCLK % (16*BAUD)) * 64 < 2^43, so nothing overflows a uint64_t.
 * Host-testable: see tools/unit-tests/unit-versal2-uart.c.
 *
 * Not needed from assembly (boot_aarch64_start.S includes this header
 * for the MMU table), so the C body is guarded out there. */
#ifndef __ASSEMBLER__
static inline int versal2_uart_baud_divisors(uint64_t fclk_hz,
                                             uint32_t baud,
                                             uint32_t *ibrd,
                                             uint32_t *fbrd)
{
    uint64_t div;    /* 16 * baud; < 2^37 for any 32-bit baud */
    uint64_t ipart, frac;

    if (baud == 0 || fclk_hz < 16ULL * (uint64_t)baud) {
        *ibrd = 0;
        *fbrd = 0;
        return -1;
    }
    div = 16ULL * (uint64_t)baud;
    ipart = fclk_hz / div;
    if (ipart > 0xFFFFULL) {    /* does not fit the 16-bit DIVINT field */
        *ibrd = 0;
        *fbrd = 0;
        return -1;
    }
    frac = fclk_hz % div;
    /* [DIVFRAC] = Integer((fraction x 64) + 0.5) =
     * (frac * 64 + div / 2) / div in integer math (div is even). */
    *fbrd = (uint32_t)(((frac << 6) + div / 2) / div);
    /* A 64 does not fit the 6-bit DIVFRAC field; carry it into the
     * integer part (the total divisor is unchanged: ip + 64/64 =
     * (ip + 1) + 0/64). */
    if (*fbrd == 64) {
        if (ipart == 0xFFFFULL) {
            *ibrd = 0;
            *fbrd = 0;
            return -1;
        }
        ipart++;
        *fbrd = 0;
    }
    *ibrd = (uint32_t)ipart;
    return 0;
}
#endif /* !__ASSEMBLER__ */

/* PL011 register offsets */
#define UART_DR_OFFSET          0x00    /* Data Register (TX/RX FIFO) */
#define UART_RSR_OFFSET         0x04    /* Receive Status / Error Clear */
#define UART_FR_OFFSET          0x18    /* Flag Register (Status) */
#define UART_ILPR_OFFSET        0x20    /* IrDA Low-Power Counter */
#define UART_IBRD_OFFSET        0x24    /* Integer Baud Rate Divisor */
#define UART_FBRD_OFFSET        0x28    /* Fractional Baud Rate Divisor */
#define UART_LCR_OFFSET         0x2C    /* Line Control Register */
#define UART_CR_OFFSET          0x30    /* Control Register */
#define UART_IFLS_OFFSET        0x34    /* Interrupt FIFO Level Select */
#define UART_IMSC_OFFSET        0x38    /* Interrupt Mask Set/Clear */
#define UART_RIS_OFFSET         0x3C    /* Raw Interrupt Status */
#define UART_MIS_OFFSET         0x40    /* Masked Interrupt Status */
#define UART_ICR_OFFSET         0x44    /* Interrupt Clear Register */
/* Note: the Gen 1 PL011 DMA Control Register at 0x48 is not listed for the
 * Gen 2 UART in the AM028 register reference, so no DMACR define is kept;
 * wolfBoot never uses UART DMA. */

#define UART_REG(offset)        (*((volatile uint32_t*)(DEBUG_UART_BASE + (offset))))

#define UART_DR                 UART_REG(UART_DR_OFFSET)
#define UART_RSR                UART_REG(UART_RSR_OFFSET)
#define UART_FR                 UART_REG(UART_FR_OFFSET)
#define UART_IBRD               UART_REG(UART_IBRD_OFFSET)
#define UART_FBRD               UART_REG(UART_FBRD_OFFSET)
#define UART_LCR                UART_REG(UART_LCR_OFFSET)
#define UART_CR                 UART_REG(UART_CR_OFFSET)
#define UART_IFLS               UART_REG(UART_IFLS_OFFSET)
#define UART_IMSC               UART_REG(UART_IMSC_OFFSET)
#define UART_RIS                UART_REG(UART_RIS_OFFSET)
#define UART_MIS                UART_REG(UART_MIS_OFFSET)
#define UART_ICR                UART_REG(UART_ICR_OFFSET)

#define UART_DR_OE              (1UL << 11) /* Overrun error */
#define UART_DR_BE              (1UL << 10) /* Break error */
#define UART_DR_PE              (1UL << 9)  /* Parity error */
#define UART_DR_FE              (1UL << 8)  /* Framing error */
#define UART_DR_ERR_MASK        (0xFUL << 8)
#define UART_DR_DATA_MASK       0xFFUL

#define UART_FR_RI              (1UL << 8)  /* Ring indicator */
#define UART_FR_TXFE            (1UL << 7)  /* TX FIFO empty */
#define UART_FR_RXFF            (1UL << 6)  /* RX FIFO full */
#define UART_FR_TXFF            (1UL << 5)  /* TX FIFO full */
#define UART_FR_RXFE            (1UL << 4)  /* RX FIFO empty */
#define UART_FR_BUSY            (1UL << 3)  /* UART busy */
#define UART_FR_DCD             (1UL << 2)  /* Data carrier detect */
#define UART_FR_DSR             (1UL << 1)  /* Data set ready */
#define UART_FR_CTS             (1UL << 0)  /* Clear to send */

#define UART_CR_CTSEN           (1UL << 15) /* CTS hardware flow control */
#define UART_CR_RTSEN           (1UL << 14) /* RTS hardware flow control */
#define UART_CR_RTS             (1UL << 11) /* Request to send */
#define UART_CR_DTR             (1UL << 10) /* Data terminal ready */
#define UART_CR_RXE             (1UL << 9)  /* Receive enable */
#define UART_CR_TXE             (1UL << 8)  /* Transmitter enable */
#define UART_CR_SIR             (1UL << 5)  /* SIR (IrDA) enable */
#define UART_CR_LPE             (1UL << 4)  /* Low power mode */
#define UART_CR_UARTEN          (1UL << 0)  /* UART enable */

#define UART_LCR_SPS            (1UL << 7)  /* Stick parity select */
#define UART_LCR_WLEN_MASK      (3UL << 5)  /* Word length mask */
#define UART_LCR_WLEN_8         (3UL << 5)  /* 8 data bits */
#define UART_LCR_WLEN_7         (2UL << 5)  /* 7 data bits */
#define UART_LCR_WLEN_6         (1UL << 5)  /* 6 data bits */
#define UART_LCR_WLEN_5         (0UL << 5)  /* 5 data bits */
#define UART_LCR_FEN            (1UL << 4)  /* FIFO enable */
#define UART_LCR_STP2           (1UL << 3)  /* Two stop bits */
#define UART_LCR_EPS            (1UL << 2)  /* Even parity select */
#define UART_LCR_PEN            (1UL << 1)  /* Parity enable */
#define UART_LCR_BRK            (1UL << 0)  /* Send break */

#ifndef DEBUG_UART_BAUD
    #define DEBUG_UART_BAUD     115200
#endif

/* ============================================================================
 * OSPI (Cadence Quad SPI controller)
 * ============================================================================
 * AM028 "OSPI register reference" (register-references/am028-ospi, Gen 2
 * edition); register offsets, bit fields and the DMA programming model
 * were cross-checked against AM026 ch. 66 and the AMD xospipsv driver
 * (see the BUILD.md "Q1 register cross-check" table). The QEMU 11.1.3
 * model (hw/ssi/xlnx-versal-ospi.c) matches the same register map.
 *
 * The VEK385 flash is a Micron MT35XU02GCBA (256 MB, x1, DQS) selected via
 * the OSPI interface (the DTB binds /axi/spi@f1010000 -> mt35xu02gcba).
 * Addresses above 16 MB require 4-byte addressing; this driver uses the
 * native 4-byte opcodes (READ4 0x13 / PP4 0x12 / ERASE4 0x21,0x5C,0xDC)
 * and never sends the legacy 3-byte set.
 *
 * Safety (task list, section 6): ospi_stig() enforces an opcode
 * allow-list and the write/erase paths enforce an address guard that
 * covers only the wolfBoot partitions (BOOT / UPDATE / SWAP). With the
 * run-13 layout (8 MB BOOT.BIN reservation 0x015C0000-0x01DBFFFF at the
 * start of Bank A, BOOT at 0x01DC0000, UPDATE at 0x049C0000) the
 * reservation, the AMD metadata areas, and Bank B are all refused by
 * that guard. None of the
 * forbidden opcodes (protect/pin/config: 42h 68h 2Ch 27h 28h 29h B1h 01h
 * E3h E4h A6h E5h C4h B9h) is in the allow-list, and none is sent by the
 * driver. The driver never touches eFUSEs, System Controller, voltages or
 * BBRAM. */
#define VERSAL2_OSPI_BASE       0xF1010000UL

/* OSPI register offsets (AM028, Gen 2 register reference). The CSU DMA
 * registers live at 0x1000 (source) and 0x1800 (destination) inside the
 * OSPI module, i.e. absolute 0xF1011000 / 0xF1011800. */
#define OSPI_R_CONFIG                     0x00
#define OSPI_R_DEV_INSTR_RD_CONFIG        0x04
#define OSPI_R_DEV_INSTR_WR_CONFIG        0x08
#define OSPI_R_DEV_DELAY_REG              0x0C
#define OSPI_R_RD_DATA_CAPTURE_REG        0x10
#define OSPI_R_DEV_SIZE_CONFIG_REG        0x14
#define OSPI_R_SRAM_PARTITION_CFG_REG     0x18
#define OSPI_R_IND_AHB_ADDR_TRIG_REG      0x1C
#define OSPI_R_DMA_PERIPH_CONFIG_REG      0x20
#define OSPI_R_REMAP_ADDR_REG             0x24
#define OSPI_R_MODE_BIT_CONFIG_REG        0x28
#define OSPI_R_SRAM_FILL_REG              0x2C
#define OSPI_R_WRITE_COMPLETION_CTRL_REG  0x38
#define OSPI_R_NO_OF_POLLS_BEF_EXP_REG    0x3C
#define OSPI_R_IRQ_STATUS_REG             0x40
#define OSPI_R_IRQ_MASK_REG               0x44
#define OSPI_R_ECO_REG                    0x48
#define OSPI_R_LOWER_WR_PROT_REG          0x50
#define OSPI_R_UPPER_WR_PROT_REG          0x54
#define OSPI_R_WR_PROT_CTRL_REG           0x58
#define OSPI_R_IND_RD_XFER_CTRL_REG       0x60
#define OSPI_R_IND_RD_XFER_WATERMARK_REG  0x64
#define OSPI_R_IND_RD_XFER_START_REG      0x68
#define OSPI_R_IND_RD_XFER_NUM_BYTES_REG  0x6C
#define OSPI_R_IND_WR_XFER_CTRL_REG       0x70
#define OSPI_R_IND_WR_XFER_WATERMARK_REG  0x74
#define OSPI_R_IND_WR_XFER_START_REG      0x78
#define OSPI_R_IND_WR_XFER_NUM_BYTES_REG  0x7C
#define OSPI_R_IND_TRIG_ADDR_RANGE_REG    0x80
#define OSPI_R_FLASH_CMD_CTRL_MEM_REG     0x8C
#define OSPI_R_FLASH_CMD_CTRL_REG         0x90
#define OSPI_R_FLASH_CMD_ADDR_REG         0x94
#define OSPI_R_FLASH_RD_DATA_LOWER_REG    0xA0
#define OSPI_R_FLASH_RD_DATA_UPPER_REG    0xA4
#define OSPI_R_FLASH_WR_DATA_LOWER_REG    0xA8
#define OSPI_R_FLASH_WR_DATA_UPPER_REG    0xAC
#define OSPI_R_POLLING_FLASH_STATUS_REG   0xB0
#define OSPI_R_PHY_CONFIGURATION_REG      0xB4
#define OSPI_R_PHY_MASTER_CONTROL_REG     0xB8
#define OSPI_R_OPCODE_EXT_LOWER_REG       0xE0
#define OSPI_R_OPCODE_EXT_UPPER_REG       0xE4
#define OSPI_R_MODULE_ID_REG              0xFC

/* CSU DMA (source channel: flash -> buffer; destination channel:
 * buffer -> system memory). Same programming model as the ZynqMP CSU DMA
 * (AM026 p710). */
#define OSPI_R_DMA_SRC_RD_ADDR            0x1000
#define OSPI_R_DMA_SRC_STS                0x1008
#define OSPI_R_DMA_SRC_CTRL               0x100C
#define OSPI_R_DMA_SRC_I_STS              0x1014
#define OSPI_R_DMA_SRC_I_EN               0x1018
#define OSPI_R_DMA_SRC_I_DIS              0x101C
#define OSPI_R_DMA_SRC_I_MASK             0x1020
#define OSPI_R_DMA_SRC_CTRL2              0x1024
#define OSPI_R_DMA_DST_ADDR               0x1800
#define OSPI_R_DMA_DST_SIZE               0x1804
#define OSPI_R_DMA_DST_STS                0x1808
#define OSPI_R_DMA_DST_CTRL               0x180C
#define OSPI_R_DMA_DST_I_STS              0x1814
#define OSPI_R_DMA_DST_I_EN               0x1818
#define OSPI_R_DMA_DST_I_DIS              0x181C
#define OSPI_R_DMA_DST_I_MASK             0x1820
#define OSPI_R_DMA_DST_CTRL2              0x1824
#define OSPI_R_DMA_DST_ADDR_MSB           0x1828
#define OSPI_R_DMA_SAFETY_CHK             0x1FF8

#define OSPI_REG(offset) \
    (*((volatile uint32_t*)(VERSAL2_OSPI_BASE + (offset))))

/* CONFIG_REG (0x00) bit fields as documented for Gen 2 by the AM028 OSPI
 * config_reg. The Gen 1 fields hold_pin (4) / reset_pin (5) / reset_cfg
 * (6), legacy-ip-mode (8) and the XIP-mode bits (17/18) are NOT part of
 * the Gen 2 field map (AM028 lists 3:10 and 16:23 fields only; 17/18 are
 * undocumented there), so they are not defined. */
#define OSPI_CFG_ENB_SPI                  (1UL << 0)
#define OSPI_CFG_SEL_CLK_POL              (1UL << 1)
#define OSPI_CFG_SEL_CLK_PHASE            (1UL << 2)
#define OSPI_CFG_PHY_MODE_EN              (1UL << 3)
#define OSPI_CFG_ENB_DIR_ACC_CTLR         (1UL << 7)
#define OSPI_CFG_PERIPH_SEL_DEC           (1UL << 9)
#define OSPI_CFG_PERIPH_CS_LINES_SHIFT    10
/* Bit 14 has no documented field in the AM028 Gen 2 config_reg (it sits
 * between periph_cs_lines 13:10 and enb_dma_if 15). Not used. */
#define OSPI_CFG_ENB_DMA_IF               (1UL << 15)
#define OSPI_CFG_ENB_AHB_ADDR_REMAP       (1UL << 16)
#define OSPI_CFG_MSTR_BAUD_DIV_SHIFT      19
#define OSPI_CFG_ENABLE_AHB_DECODER       (1UL << 23)
#define OSPI_CFG_ENABLE_DTR_PROTOCOL      (1UL << 24)
#define OSPI_CFG_PIPELINE_PHY             (1UL << 25)
/* Bits 28:26 are config_resv2_fld in AM028: there is no CRC_ENABLE field
 * in the Gen 2 config register (the Gen 1 bit 29 is not listed). */
#define OSPI_CFG_DUAL_BYTE_OPCODE_EN      (1UL << 30)
#define OSPI_CFG_IDLE                     (1UL << 31)

/* DEV_INSTR_RD_CONFIG_REG (0x04): STIG-free (XIP/DAC) read opcode */
#define OSPI_DEV_INSTR_RD_OPCODE_MASK     0xFFUL
/* DEV_INSTR_WR_CONFIG_REG (0x08): XIP/DAC write opcode, WEL_DIS bit 8 */
#define OSPI_DEV_INSTR_WR_OPCODE_MASK     0xFFUL
#define OSPI_DEV_INSTR_WR_WEL_DIS         (1UL << 8)

/* DEV_SIZE_CONFIG_REG (0x14): flash device size configuration.
 * NUM_ADDR_BYTES: 0 = 1, 1 = 2, 2 = 3, 3 = 4 address bytes; per-CHIP
 * MEM_SIZE: 0 = 512 Mb, 1 = 1 Gb, 2 = 2 Gb, 3 = 4 Gb; BYTES_PER_DEVICE_PAGE
 * is the NOR page size (256 = 0x100) and BYTES_PER_SUBSECTOR 16 = 0x10
 * (both used by the controller's write-protection logic). */
#define OSPI_DEV_SIZE_NUM_ADDR_BYTES_SHIFT 0
#define OSPI_DEV_SIZE_NUM_ADDR_BYTES_4    3UL
#define OSPI_DEV_SIZE_BYTES_PER_PAGE_SHIFT 4
#define OSPI_DEV_SIZE_BYTES_PER_PAGE_256  0x100UL
#define OSPI_DEV_SIZE_BYTES_PER_SUBSECTOR_SHIFT 16
#define OSPI_DEV_SIZE_BYTES_PER_SUBSECTOR_16 0x10UL
#define OSPI_DEV_SIZE_MEM_SIZE_SHIFT      21
#define OSPI_DEV_SIZE_MEM_SIZE_2GB        2UL
/* Full documented value for the VEK385 device (2 Gb on CS0, 4 address
 * bytes, 256-byte pages, 16-byte subsector). */
#define OSPI_DEV_SIZE_VERSAL2 \
    ((OSPI_DEV_SIZE_MEM_SIZE_2GB << OSPI_DEV_SIZE_MEM_SIZE_SHIFT) | \
     (OSPI_DEV_SIZE_BYTES_PER_SUBSECTOR_16 << OSPI_DEV_SIZE_BYTES_PER_SUBSECTOR_SHIFT) | \
     (OSPI_DEV_SIZE_BYTES_PER_PAGE_256 << OSPI_DEV_SIZE_BYTES_PER_PAGE_SHIFT) | \
     OSPI_DEV_SIZE_NUM_ADDR_BYTES_4)

/* FLASH_CMD_CTRL_REG (0x90): STIG command trigger. */
#define OSPI_FCC_CMD_OPCODE_SHIFT         24
#define OSPI_FCC_ENB_READ_DATA            (1UL << 23)
#define OSPI_FCC_NUM_RD_DATA_BYTES_SHIFT  20
#define OSPI_FCC_ENB_COMD_ADDR            (1UL << 19)
#define OSPI_FCC_ENB_MODE_BIT             (1UL << 18)
#define OSPI_FCC_NUM_ADDR_BYTES_SHIFT     16
#define OSPI_FCC_ENB_WRITE_DATA           (1UL << 15)
#define OSPI_FCC_NUM_WR_DATA_BYTES_SHIFT  12
#define OSPI_FCC_NUM_DUMMY_CYCLES_SHIFT   7
#define OSPI_FCC_STIG_MEM_BANK_EN         (1UL << 2)
#define OSPI_FCC_CMD_EXEC_STATUS          (1UL << 1)
#define OSPI_FCC_CMD_EXEC                 (1UL << 0)

/* STIG limits (AM028): at most 4 address bytes and 8 write-data bytes per
 * command; the read-data registers are 64 bits wide. */
#define OSPI_STIG_MAX_ADDR_BYTES          4
#define OSPI_STIG_MAX_WR_DATA_BYTES       8
#define OSPI_STIG_MAX_RD_DATA_BYTES       8

/* INDIRECT_READ_XFER_CTRL_REG (0x60) */
#define OSPI_IND_RD_START                 (1UL << 0)
#define OSPI_IND_RD_CANCEL                (1UL << 1)
#define OSPI_IND_RD_STATUS                (1UL << 2)
#define OSPI_IND_RD_SRAM_FULL             (1UL << 3)
#define OSPI_IND_RD_OPS_DONE_STATUS       (1UL << 5)   /* W1C */

/* CSU DMA interrupt status bits (AM026 Tables 224/225; AM028 *_I_STS):
 * W1C on both channels. */
#define OSPI_DMA_SRC_I_STS_MEM_DONE       (1UL << 0)
#define OSPI_DMA_SRC_I_STS_DONE           (1UL << 1)
#define OSPI_DMA_SRC_I_STS_AXI_RDERR      (1UL << 2)
#define OSPI_DMA_DST_I_STS_DONE           (1UL << 1)
#define OSPI_DMA_DST_I_STS_AXI_BRESP_ERR  (1UL << 2)
#define OSPI_DMA_DST_I_STS_TIMEOUT_STRM   (1UL << 3)
#define OSPI_DMA_DST_I_STS_TIMEOUT_MEM    (1UL << 4)
#define OSPI_DMA_DST_I_STS_FIFO_OVERFLOW  (1UL << 7)

/* DMA programming model (AM026 p706-709 Table 223, identical to the AMD
 * xospipsv driver constants, xospipsv_hw.h): burst requests of 64 bytes,
 * single requests of 4 bytes (DMA_PERIPH_CONFIG = 2^6 / 2^2); SRC DMA
 * fixed 64-byte burst (IND_TRIG_ADDR_RANGE = 6); the whole SRAM given to
 * the indirect-read partition for DMA reads (SRAM_PARTITION = 0xFE).
 * AHB_Indirect_Addr must not straddle a 4 KB boundary (AM026 p709):
 * the DAC base 0xC0000000 is used, as in xospipsv (IND_TRIGGAHB_BASE). */
#define OSPI_DMA_PERIPH_CFG_64B_4B        0x00000602UL
#define OSPI_SRAM_PARTITION_DMA_READ      0x000000FEUL
#define OSPI_IND_TRIG_RANGE_64B           0x6UL
#define OSPI_IND_TRIG_RANGE_256B          0x8UL
#define OSPI_DMA_DST_CTRL_DEF             0xF43FFA00UL
#define OSPI_IND_AHB_TRIG_BASE            VERSAL2_OSPI_DAC_BASE

/* MODULE_ID register (0xFC): the module id is bits [23:8]. Real Versal
 * OSPI silicon reports 0x20 (Cadence QSPI SV); the QEMU xlnx-versal-ospi
 * model (hw/ssi/xlnx-versal-ospi.c) resets MODULE_ID_REG to 0x300, i.e.
 * module id 3. ospi_init() uses this to detect the QEMU model (the same
 * discriminator the QEMU probe in run 2 used to establish the register
 * programming sequence). */
#define OSPI_MODULE_ID_SHIFT              8
#define OSPI_MODULE_ID_MASK               0xFFFFUL
#define OSPI_MODULE_ID_QEMU               3UL

/* Statically mapped flash window (DAC / indirect). AM026 p704: direct
 * mode is mapped 0xC000_0000 - 0xDFFF_FFFF (512 MB). Not used for data
 * transfers by the STIG-only default build; the DMA read path (when
 * enabled with WOLFBOOT_OSPI_DMA) uses it as the SRC DMA source window. */
#define VERSAL2_OSPI_DAC_BASE     0xC0000000UL
#define VERSAL2_OSPI_DAC_SIZE     0x20000000UL

/* Absolute bases of the two CSU DMA register blocks (module offsets
 * 0x1000 / 0x1800 above VERSAL2_OSPI_BASE). */
#define VERSAL2_OSPI_DMA_SRC_BASE (VERSAL2_OSPI_BASE + 0x1000UL)
#define VERSAL2_OSPI_DMA_DST_BASE (VERSAL2_OSPI_BASE + 0x1800UL)

/* ============================================================================
 * OSPI flash opcodes (Micron MT35XU02GCBA)
 * ============================================================================
 * OpCodes used by the PR 1 driver: the native 4-byte address set
 * (READ4 0x13, PP4 0x12, ERASE4 0x21/0x5C/0xDC) - addresses above 16 MB
 * require 4-byte addressing. ospi_stig() in hal/versal2.c enforces the full
 * allow-list from the task list (section 6) as a table; only allow-listed
 * opcodes may reach the flash.
 *
 * Erase sizes are per the MT35XU02GCBA datasheet (Table 2 memory map and
 * Table 21 command set, p13-14 / p32-34): 0xDC erases the 128 KB sector
 * (2048 sectors x 128 KB = 2 Gb); the extended-ID byte 5 sector-size bits
 * read "01 = Uniform 128KB". QEMU's m25p80 model of mt35xu02gbba agrees
 * (sector_size 128 KB for 0xDC). */
#define OSPI_OP_READ4               0x13    /* Read, 4-byte address */
#define OSPI_OP_PAGE_PROGRAM4       0x12    /* Page Program, 4-byte address */
#define OSPI_OP_ERASE4_4K           0x21    /* 4 KB subsector erase */
#define OSPI_OP_ERASE4_32K          0x5C    /* 32 KB subsector erase */
#define OSPI_OP_ERASE4_128K         0xDC    /* Sector erase (128 KB) */

#define OSPI_OP_WREN                0x06    /* Write Enable */
#define OSPI_OP_WRDI                0x04    /* Write Disable */

#define OSPI_OP_READ_STATUS1        0x05    /* Read Status Register 1 */
#define OSPI_OP_READ_FLAG_STATUS    0x70    /* Read Flag Status Register */

#define OSPI_OP_JEDEC_ID            0x9F    /* JEDEC ID (3 bytes) */

#define OSPI_OP_RESET_ENABLE        0x66    /* Reset Enable */
#define OSPI_OP_RESET               0x99    /* Reset */

#define OSPI_OP_WRITE_VOL_CFG       0x81    /* Write Volatile Configuration */
#define OSPI_OP_READ_VOL_CFG        0x85    /* Read Volatile Configuration */

/* Volatile configuration register (Micron Table 7, p21-22). Only the LSB
 * of the address selects the register; the data bytes hold the values.
 * The driver only ever uses the volatile (0x81) form - never the
 * nonvolatile 0xB1. */
#define OSPI_VCFG_ADDR_IO_MODE      0x00    /* I/O mode select */
#define OSPI_VCFG_VAL_EXT_SPI_1BIT  0xFF    /* Extended SPI (1-bit SDR), POR default */
#define OSPI_VCFG_ADDR_B128M        0x05    /* 3- vs 4-byte addressing */
#define OSPI_VCFG_VAL_4BYTE_ADDR    0xFE

/* Flash flag status register bits (read with 0x70; Micron MT35XU02GCBA
 * Table 5, p17). */
#define OSPI_FLAG_STATUS_READY      (1UL << 7)  /* 1 = ready, 0 = busy */
#define OSPI_FLAG_STATUS_ERASE_ERR  (1UL << 5)  /* erase failure/protect error */
#define OSPI_FLAG_STATUS_PROG_ERR   (1UL << 4)  /* program failure/protect error */
#define OSPI_FLAG_STATUS_PROTECT    (1UL << 1)  /* protected-sector attempt */
#define OSPI_FLAG_STATUS_ADDR_MODE4 (1UL << 0)  /* 1 = 4-byte addressing */

/* JEDEC ID of the VEK385 flash: 2C 5B 1C (Micron MT35XU02GxxBx). */
#define OSPI_JEDEC_ID_MICRON_2C     0x2C

/* System timer (ARM generic timer). AM028 TSG_RW CNTFID0: reset value
 * 0x0, programmed by system firmware (PLM/BL31). timer_get_freq()
 * (include/aarch64_arch.h) reads CNTFRQ_EL0 and uses it whenever it is
 * non-zero; TIMER_CLK_FREQ is the fallback only when CNTFRQ_EL0 reads 0
 * (one-line warning on the debug UART, see hal/versal2.c). The QEMU test
 * trampoline programs 100 MHz, matching this default. The actual board
 * value is whatever the PLM programmed - confirm it in PR 2. */
#ifndef TIMER_CLK_FREQ
    #define TIMER_CLK_FREQ          100000000UL  /* 100 MHz */
#endif

#endif /* _VERSAL2_H_ */
