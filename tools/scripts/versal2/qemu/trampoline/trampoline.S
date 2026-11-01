/* trampoline.S
 *
 * QEMU-only EL3 -> EL2 hand-off trampoline for the versal2 tests.
 *
 * QEMU amd-versal2-virt starts cpu0 at EL3 (secure) with no prior firmware:
 * there is no PLM, PSM or BL31. This trampoline emulates the BL31 -> BL33
 * hand-off that AMD's TF-A performs on the board: it parks any secondary
 * core, programs the generic-timer frequency, sets SCR_EL3 for a
 * non-secure AArch64 EL2 entry and ERETs into wolfBoot at
 * WOLFBOOT_ORIGIN (0x40000000, the AMD default BL33 entry address).
 *
 * wolfBoot then runs exactly as it would after the real hand-off: EL2,
 * non-secure, DAIF masked, MMU off.
 *
 * EL3 exception handling (run 6): the QEMU machine enables its own PSCI
 * only when started with -kernel (xlnx-versal-virt.c: psci_conduit stays
 * QEMU_PSCI_CONDUIT_DISABLED with -device loader), so any SMC the guest
 * executes is unhandled by QEMU and would take an exception at EL3 with
 * the reset VBAR_EL3 (0) - a livelock on the undefined instructions at
 * the 0x200 vector. A real BL31 always installs VBAR_EL3, so this
 * trampoline does the same:
 *
 *   - SP_EL3 is set to a scratch stack (reset SP_EL3 is 0; an exception
 *     entry at EL3 would otherwise fault on the first stack write).
 *   - VBAR_EL3 points at the vector table below. SMC exceptions are
 *     answered with a minimal PSCI 1.0-compatible subset (the kernel's
 *     psci platform driver uses it for the version probe and, once a
 *     /psci node exists, for CPU/suspend/reset calls): VERSION,
 *     MIGRATE_INFO_TYPE, FEATURES, AFFINITY_INFO (inactive), CPU_ON/OFF/
 *     SUSPEND (unsupported), SYSTEM_OFF (park) and SYSTEM_RESET (ERET
 *     back to the trampoline start, which re-runs the whole BL31 -> BL33
 *     hand-off - the flash contents persist, so a confirmed A/B update
 *     boots on reset, like a real reboot).
 *   - Any other EL3 exception is dumped (ESR/ELR/SPSR/FAR in hex) to UART1
 *     and parked, so a future regression prints instead of livelocking.
 *
 * Linked at 0x800000 (QEMU low DDR). The QEMU test script loads it with
 * `-device loader,file=tramp.elf` AFTER `-device loader,file=wolfboot.elf`
 * so that its entry point becomes the CPU reset PC.
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

	.section .text
	.global _start
	.type _start, %function

/* WOLFBOOT_ORIGIN - must match config/examples/versal2_vek385.config */
	.equ WOLFBOOT_ORIGIN, 0x40000000
/* QEMU amd-versal2-virt UART1 (console) */
	.equ UART1_BASE, 0xF1930000
/* SCR_EL3 for the non-secure AArch64 EL2 entry.
 *
 * QEMU models the SCR register in ONE bit layout for both the AArch32
 * and the AArch64 EL3 view (the AArch64 SCR_EL3 cpreg maps 1:1 onto the
 * internal register, QEMU 11.1.3 target/arm/helper.c el3_cp_reginfo):
 * NS=bit0, IRQ=bit1, FIQ=bit2, EA=bit3, HCE=bit8, RW=bit10, ST=bit11
 * (target/arm/cpu.h). QEMU's own firmware emulation for the -kernel EL2
 * entry (target/arm/cpu.c arm_emulate_firmware_reset) writes exactly
 * NS|HCE|RW with the comment "If the guest is at EL2 then Linux expects
 * the HVC insn to work" - HVC at EL0/EL1 is UNDEFINED while HCE is 0.
 *
 * HCE (bit 8) is REQUIRED for the BOOT_EL2 Linux hand-off: the kernel's
 * VHE bring-up (finalise_el2(), arch/arm64/kernel/hyp-stub.S) executes
 * `hvc #0` AT EL1 to trap into the EL2 hyp-stub vectors; with HCE=0 the
 * HVC faults as an undefined instruction at EL1 (run-6 finding, the
 * reason the Linux config used BOOT_EL1 until this run). SMC from
 * EL0/EL1 always traps to EL3 (no SCR bit needed), so the PSCI handler
 * below works regardless; on this AArch64-only EL3 QEMU also forces
 * RW (bit 10) to 1 (scr_write, RAO/WI), so the lower-EL AArch64 state
 * is guaranteed. Bit 11 (QEMU SCR_ST, secure-trace trap; harmless here
 * - the AArch64 hardware view would call it RW) is kept as written in
 * the proven run-7..9 state; the register value is unchanged by the
 * relabelling below (NS|EA|HCE|ST = 0x909).
 *
 * QEMU's GICv3 gicv3_irqfiq_access() reads cp15.scr_el3 with the SCR_IRQ
 * (bit 1) and SCR_FIQ (bit 2) routing bits, so those stay CLEAR: if both
 * were set it would believe IRQ/FIQ are trapped to EL3 and - with
 * HCR_EL2.{IMO,FMO}=0 - trap every EL1 ICC_* CPU-interface access
 * (ICC_PMR, ICC_DIR, ICC_RPR, ICC_CTLR, ...) to EL3. Keeping bits 1/2
 * clear also stops WFI/WFE from EL0/EL1 from trapping to EL3 (the
 * kernel idle path uses WFI). Guest IRQ/FIQ are routed to EL1/EL2
 * (GIC IROUTER), where the kernel handles them. */
	.equ SCR_NS,  1 << 0
	.equ SCR_EA,  1 << 3
	.equ SCR_HCE, 1 << 8   /* QEMU's HCE bit (cpu.h SCR_HCE); HVC at EL1 needs it */
	.equ SCR_RW,  1 << 11
/* SPSR value: EL2h with DAIF masked (0x3C0) - the BL31 -> BL33 hand-off
 * state (wolfBoot runs at EL2). PSTATE mode bits[3:0] = 0b1001 = EL2h. */
	.equ SPSR_EL2H, 0x3C9
/* EL3 exception stack: 1 MB above the trampoline text (0x800000), inside
 * QEMU low DDR; clear of the DTB staging (0x1800000) and the FIT/kernel/
 * ramdisk regions (0x20000000+). */
	.equ EL3_STACK_TOP, 0x880000
/* EL2 exception stack (for the VBAR_EL2 catch table below): another 1 MB
 * up. SP_EL2 resets to 0, so any exception taken at EL2 (an EL1 -> EL2
 * trap from the guest) would fault on its first stack write without this. */
	.equ EL2_STACK_TOP, 0x8C0000

/* PSCI (ARM PSCI 1.0) function ids (SMC conduit) and return codes */
	.equ PSCI_0_2_VERSION,        0x80000000
	.equ PSCI_0_2_MIGRATE_TYPE,   0x81000000
	.equ PSCI_0_2_SYSTEM_OFF,     0x82000000
	.equ PSCI_0_2_SYSTEM_RESET,   0x83000000
	.equ PSCI_0_2_CPU_ON,         0x84000000
	.equ PSCI_0_2_CPU_OFF,        0x84000001
	.equ PSCI_0_2_CPU_SUSPEND,    0x84000002
	.equ PSCI_0_2_AFFINITY_INFO,  0x85000000
	.equ PSCI_1_0_VERSION,        0xC0000000
	.equ PSCI_1_0_MIGRATE_TYPE,   0xC0100000
	.equ PSCI_1_0_SYSTEM_OFF,     0xC0200000
	.equ PSCI_1_0_SYSTEM_RESET,   0xC0300000
	.equ PSCI_1_0_CPU_ON,         0xC0400000
	.equ PSCI_1_0_CPU_OFF,        0xC0400001
	.equ PSCI_1_0_CPU_SUSPEND,    0xC0400002
	.equ PSCI_1_0_AFFINITY_INFO,  0xC0500000
	.equ PSCI_1_0_FEATURES,       0xC0600000
	.equ PSCI_1_1_VERSION,        0xC0700000
	.equ PSCI_1_1_AFFINITY_INFO,  0xC0B00000
	.equ PSCI_1_1_MIGRATE,        0xC0E00000
	.equ PSCI_RET_NOT_SUPP,       0xFFFFFFFF
	.equ PSCI_RET_INACTIVE,       3

_start:
	/* Park secondary cores: QEMU powers only cpu0, but a powered-up
	 * secondary would run this code with no wolfBoot context. */
	mrs	x0, mpidr_el1
	ubfx	x1, x0, #0, #8      /* affinity 0 */
	ubfx	x2, x0, #8, #8      /* affinity 1 */
	add	x1, x1, x2
	cbnz	x1, park

	/* Primary core: bring up UART1 for the bring-up marker. QEMU starts
	 * the PL011 disabled; on the board the PLM has already configured
	 * the console with the same 8N1 settings, so re-initializing its
	 * own registers is required under QEMU and harmless on the board.
	 * QEMU's PL011 model ignores the baud divisors, so the exact
	 * IBRD/FBRD values do not matter here; wolfBoot's uart_init() keeps
	 * them (the trampoline leaves the UART enabled) and only programs
	 * divisors - computed from DEBUG_UART_CLK_HZ - when it finds the
	 * UART disabled (run 3). The values below are the correct AM026
	 * ch. 63 p670 divisors for 115200 at the 100 MHz reference clock:
	 * divisor = 100000000/(16*115200) = 54.25 -> IBRD 54,
	 * FBRD = Integer((0.25*64)+0.5) = 16 (run 4; they matter on the
	 * board). */
	mov	x2, #UART1_BASE
	str	wzr, [x2, #0x30]          /* CR = 0 (disable); 32-bit accesses only */
	mov	x3, #54
	str	w3, [x2, #0x24]          /* IBRD (115200 @ 100 MHz: 100e6/(16*115200)=54.25) */
	mov	x3, #16
	str	w3, [x2, #0x28]          /* FBRD (54 + 16/64, AM026 ch. 63 p670, see unit-versal2-uart) */
	mov	x3, #0x60
	str	w3, [x2, #0x2C]          /* LCR: 8N1, FIFOs */
	mov	x3, #0x203
	str	w3, [x2, #0x30]          /* CR: enable, TX, RX */

	/* Print "TRAMP\n" - proves the trampoline is running at EL3 */
	adr	x3, tramp_str
1:
	ldrb	w4, [x3], #1
	cbz	w4, 2f
	ldr	w5, [x2, #0x18]          /* FR */
	tst	w5, #(1 << 5)            /* TXFF */
	bne	1b
	str	w4, [x2, #0x00]          /* DR */
	b	1b
2:

	/* Generic timer frequency, as BL31 would have left it.
	 * 100000000 Hz = 0x05F5E100 (boot_aarch64_start.S counterfreq).
	 * NOTE: QEMU amd-versal2-virt resets CNTFRQ_EL0 to 1 GHz (0x3B9ACA00,
	 * verified with a reset-state probe, run 3); this write emulates the
	 * board's firmware (PLM/BL31) value so the QEMU flow matches the board
	 * hand-off. The actual board value is firmware-programmed (AM028 TSG_RW
	 * CNTFID0, reset 0) and must be confirmed in PR 2. */
	movz	x0, #0xE100
	movk	x0, #0x5F5, lsl #16
	msr	cntfrq_el0, x0

	/* Non-secure AArch64 EL2 below; IRQ/FIQ stay untrapped so the guest
	 * kernel handles them at EL1. HCE (bit 8) makes the kernel's EL1
	 * `hvc #0` (finalise_el2) trap to EL2 instead of UNDEF; see the
	 * SCR_EL3 note above. */
	mov	x0, #(SCR_NS | SCR_EA | SCR_HCE | SCR_RW)
	msr	scr_el3, x0

	/* EL3 exception handling: SP_EL3 (reset 0 - unusable) and VBAR_EL3
	 * (reset 0 - would livelock on the undefined-instruction vectors).
	 * See the file header for the PSCI subset the handler answers.
	 *
	 * SP_EL3 has NO MSR/MRS system-register encoding that this QEMU
	 * implements (target/arm/helper.c defines SP_EL0=S3_0_C4_C1_0,
	 * SP_EL1=S3_4_C4_C1_0, SP_EL2=S3_6_C4_C1_0 - and no SP_EL3), so
	 * "msr s3_4_c9_c0_3, x0" is an unallocated register and takes an
	 * undefined-instruction exception. The CPU resets into EL3h
	 * (PSTATE.SP=1), where the architectural "sp" register IS SP_EL3,
	 * so it is set with an ordinary "mov sp, x0". */
	movz	x0, #0x0
	movk	x0, #0x88, lsl #16     /* EL3_STACK_TOP = 0x880000 */
	mov	sp, x0			/* sp == SP_EL3 at EL3h */
	adr	x0, el3_vectors
	msr	vbar_el3, x0

	/* EL2 exception catch: the guest (EL1) can still trap to EL2 for
	 * system-register accesses the hand-off leaves trapped; the reset
	 * VBAR_EL2 is 0, so such an exception would livelock silently. Install
	 * a 2 KiB-aligned catch table that dumps ESR/ELR/FAR over UART1 and
	 * parks. SP_EL2 (reset 0) gets its own stack top. */
	movz	x0, #0x0
	movk	x0, #0x8C, lsl #16     /* EL2_STACK_TOP = 0x8C0000 */
	msr	sp_el2, x0
	adr	x0, el2_vectors
	msr	vbar_el2, x0

#ifdef TRAMP_GIC_INIT
	/* ===== GICv3 bring-up: the part of BL31 this trampoline emulates ====
	 * Build option: compiled in only for the Linux trampoline (the build
	 * adds -DTRAMP_GIC_INIT); the 23-check test_qemu.sh suite uses the
	 * plain trampoline (no GIC block) - the bare-metal test app runs at
	 * EL2 and needs no interrupts.
	 *
	 * Placed AFTER the SP_EL3/VBAR_EL3 and SP_EL2/VBAR_EL2 installs above:
	 * any EL3 exception in this code must hit the diag vectors and dump
	 * ESR/ELR/FAR over UART1 instead of livelocking on the reset VBAR_EL3
	 * (0).
	 *
	 * Why (run 8): QEMU's GICv3 (security extensions on) resets with
	 * every interrupt in Group 0 (secure), the GICD_CTLR group enables
	 * clear and the redistributors asleep (GICR_WAKER with
	 * ProcessorSleep|ChildrenAsleep set). With -device loader QEMU does
	 * NOT do the -kernel firmware emulation (hw/intc/arm_gicv3_common.c:
	 * arm_gic_common_linux_init() sets irq_reset_nonsecure only for a
	 * -kernel boot), so a non-secure EL1 kernel receives no interrupts at
	 * all: the arch-timer PPIs (INTIDs 26/27/29/30) stay Group 0 and the
	 * kernel's jiffies never advances - it hangs on the first delay with
	 * jiffies stuck at INITIAL_JIFFIES (0xfffedb08 = -300*HZ, HZ=250).
	 * On the board TF-A sets up the GIC security groups at EL3; do the
	 * single-core subset of TF-A's GICv3 driver (drivers/arm/gic/v3,
	 * ARM Trusted Firmware-A) at EL3, before the ERET, mirroring the
	 * BL31 -> BL33 hand-off.
	 *
	 * Register access widths (GICv3 Architecture Specification: every
	 * GICD/GICR register takes 32-bit accesses EXCEPT GICR_TYPER and
	 * GICD_IROUTERn, which are 64-bit): use 32-bit accesses (ldr w /
	 * str w) for every GICD/GICR register in this block and read
	 * GICR_TYPER as 64-bit (ldr x). A 64-bit access to a 32-bit GIC
	 * register is a bus error in QEMU, which shows up as a synchronous
	 * external abort at EL3 - the run-8 GIC block hit exactly that (a
	 * 64-bit str to GICD_IGRPMODRn / GICR_IGRPMODR0).
	 *
	 * Order (all at EL3, before dropping to EL2), with the TF-A source:
	 *  a. ICC_SRE_EL3 = SRE (bit0) | DFB (bit1) | DIB (bit2) |
	 *     Enable (bit3); isb. TF-A gicv3_cpuif_enable() (gicv3_main.c):
	 *     icc_sre_el3 = DIB | DFB | EN | SRE. (QEMU models ICC_SRE_EL3
	 *     as constant 0xF, RAZ/WI; on a GICv3 without v2-compat DIB/DFB
	 *     are RAZ/WI, so 0xF is the complete effective state on the
	 *     board too. Use s3_6_c12_c12_5 if an assembler does not know
	 *     icc_sre_el3.)
	 *  b. GICD_CTLR (0xE2000000 + 0x0): first write ARE_S (bit4) |
	 *     ARE_NS (bit5) and wait for RWP (bit31) = 0; then ALSO set
	 *     EnableGrp0 (bit0), EnableGrp1NS (bit1) and EnableGrp1S (bit2)
	 *     and wait for RWP = 0. TF-A gicv3_distif_init() (gicv3_main.c):
	 *     "The Distributor might generate a system error otherwise"
	 *     (wait for RWP before/after group-enable changes). (QEMU: RWP
	 *     is RAO of the DS bit, so the waits pass immediately; ARE_S/
	 *     ARE_NS are RAO and already 1 at reset.)
	 *  c. GICD_TYPER (+0x4): ITLinesNumber = bits[4:0]; the number of
	 *     32-interrupt blocks is ITLinesNumber + 1. For n = 1 ..
	 *     ITLinesNumber: GICD_IGROUPRn (+0x80 + 4n) = 0xFFFFFFFF and
	 *     GICD_IGRPMODRn (+0xD00 + 4n) = 0. TF-A
	 *     gicv3_spis_config_defaults() (gicv3_helpers.c): "Treat all
	 *     (E)SPIs as G1NS by default"; (IGRPMODR=0, IGROUPR=1) is
	 *     Group 1 Non-secure. (n = 0 is banked per CPU and handled in
	 *     the redistributor, step d.)
	 *  d. Boot CPU redistributor: the DTB GICR region is 0xE2060000,
	 *     size 0x100000 (8 CPUs x 128 KB); each redistributor frame is
	 *     0x20000: RD_base = frame, SGI_base = frame + 0x10000. The
	 *     boot CPU's frame is the one whose GICR_TYPER (RD_base + 0x08,
	 *     read 64-bit) affinity bits [63:32] match the boot CPU's
	 *     MPIDR_EL1 Aff3.Aff2.Aff1.Aff0. Walk the frames from
	 *     0xE2060000 in 0x20000 steps until it matches; stop at the
	 *     frame with GICR_TYPER.Last (bit 4); do NOT assume frame 0.
	 *     Then GICR_WAKER (RD_base + 0x14): clear ProcessorSleep (bit1)
	 *     and wait until ChildrenAsleep (bit2) = 0 - TF-A
	 *     gicv3_rdistif_mark_core_awake() (gicv3_helpers.c). The wait
	 *     is BOUNDED (GICR_WAKER_WAIT_MAX iterations): run-9 QEMU 11.1.3
	 *     forensics (see q8-qemu-report.md, QEMU limitations) showed the
	 *     model's GICR_WAKER write path being ignored in some -device
	 *     loader boots (the register keeps its reset value 0x6 = PS|CA
	 *     for both CPU and monitor writes), which would hang an
	 *     unbounded wait; QEMU's model does not reference gicr_waker
	 *     when delivering interrupts to the CPU, so proceeding after the
	 *     bound still delivers the timer PPIs. On real hardware the
	 *     handshake completes in a handful of iterations and the bound
	 *     is never reached. Then
	 *     GICR_IGROUPR0 (SGI_base + 0x80) = 0xFFFFFFFF and
	 *     GICR_IGRPMODR0 (SGI_base + 0xD00) = 0, so SGIs/PPIs -
	 *     including the arch-timer PPIs (QEMU DTB timer node:
	 *     PPI 13, 14, 11, 10 = INTIDs 29, 30, 27, 26) - are Group 1
	 *     Non-secure. TF-A gicv3_ppi_sgi_config_defaults()
	 *     (gicv3_helpers.c): "GICR_IGRPMODR0 resets to an
	 *     architecturally UNKNOWN value, so clear it explicitly to pin
	 *     the group to (IGRPMODR=0, IGROUPR=1) = G1NS".
	 *  e. Do NOT set ICC_IGRPEN1_EL1 or ICC_PMR_EL1 for Linux: the
	 *     kernel enables its own CPU interface and priority mask at EL1
	 *     (arch/arm64/kernel/psci.c / the GICv3 CPU init); TF-A leaves
	 *     those to the guest as well.
	 *
	 * The kernel's own gic_dist_init() re-sets GICD_CTLR and the SPI
	 * groups, and its CPU init sets ICC_SRE_EL1 / ICC_PMR_EL1 /
	 * ICC_IGRPEN1_EL1 itself; this EL3 setup is what makes the PPIs
	 * reachable at all before that code runs.
	 */
	.equ GICD_BASE,         0xE2000000
	.equ GICD_CTLR,         0x0
	.equ GICD_TYPER,        0x4
	.equ GICD_IGROUPR_BASE, 0x80
	.equ GICD_IGRPMODR_BASE, 0xD00
	.equ GICR_FRAME_BASE,   0xE2060000
	.equ GICR_FRAME_STRIDE, 0x20000
	.equ GICR_SGI_BASE_OFF, 0x10000
	.equ GICR_TYPER_OFF,    0x8
	.equ GICR_WAKER_OFF,    0x14
	.equ GICR_IGROUPR0_OFF, 0x80
	.equ GICR_IGRPMODR0_OFF, 0xD00
	.equ GICD_CTLR_EN0,     1 << 0
	.equ GICD_CTLR_EN1NS,   1 << 1
	.equ GICD_CTLR_EN1S,    1 << 2
	.equ GICD_CTLR_ARE_S,   1 << 4
	.equ GICD_CTLR_ARE_NS,  1 << 5
	.equ GICD_CTLR_RWP,     1 << 31
	.equ GICR_TYPER_LAST,   1 << 4
	.equ GICR_WAKER_PS,     1 << 1
	.equ GICR_WAKER_CA,     1 << 2
	/* Bounded ChildrenAsleep wait (see the note in the GICR_WAKER code
	 * below): QEMU 11.1.3's GICv3 model can ignore GICR_WAKER writes in
	 * a -device loader boot, in which case CA never clears and an
	 * unbounded wait hangs the boot. On real hardware CA clears within
	 * a few iterations. */
	.equ GICR_WAKER_WAIT_MAX, 0x10000

	/* a. ICC_SRE_EL3: SRE | DFB | DIB | Enable = 0xF; isb. */
	mov	x0, #0xF
	msr	icc_sre_el3, x0
	isb

	/* b. GICD_CTLR: ARE_S | ARE_NS first, wait for RWP = 0. */
	movz	x0, #0xE200, lsl #16    /* GICD base (DTB) */
	ldr	w1, [x0, #GICD_CTLR]
	orr	w1, w1, #(GICD_CTLR_ARE_S | GICD_CTLR_ARE_NS)
	str	w1, [x0, #GICD_CTLR]
1:	ldr	w1, [x0, #GICD_CTLR]
	tst	w1, #GICD_CTLR_RWP
	bne	1b
	/* Then also the group enables, wait for RWP = 0. */
	ldr	w1, [x0, #GICD_CTLR]
	orr	w1, w1, #(GICD_CTLR_EN0 | GICD_CTLR_EN1NS | GICD_CTLR_EN1S)
	str	w1, [x0, #GICD_CTLR]
1:	ldr	w1, [x0, #GICD_CTLR]
	tst	w1, #GICD_CTLR_RWP
	bne	1b

	/* c. All SPIs to G1NS: n = 1 .. GICD_TYPER.ITLinesNumber[4:0]
	 * (number of 32-interrupt blocks = ITLinesNumber + 1). 32-bit
	 * accesses only. */
	ldr	w1, [x0, #GICD_TYPER]
	and	w1, w1, #0x1F
	mov	x2, x0
	add	x2, x2, #GICD_IGROUPR_BASE  /* GICD_IGROUPR base (+0x80) */
	mov	x3, x0
	add	x3, x3, #GICD_IGRPMODR_BASE /* GICD_IGRPMODR base (+0xD00) */
	mov	w4, #1
	mov	w5, #0xFFFFFFFF
	mov	w6, #0
1:	cmp	w4, w1
	b.gt	2f
	str	w5, [x2]                  /* GICD_IGROUPRn = all Group 1 */
	str	w6, [x3]                  /* GICD_IGRPMODRn = 0 (G1NS) */
	add	x2, x2, #4
	add	x3, x3, #4
	add	w4, w4, #1
	b	1b
2:

	/* d. Find the boot CPU's redistributor frame: walk from
	 * GICR_FRAME_BASE in GICR_FRAME_STRIDE steps; the frame whose
	 * GICR_TYPER [63:32] matches the boot CPU's MPIDR_EL1 [63:32] is
	 * the boot CPU's; stop at GICR_TYPER.Last (bit 4). */
	mrs	x0, mpidr_el1
	lsr	x1, x0, #32               /* boot CPU Aff3.Aff2.Aff1.Aff0 */
	movz	x2, #0xE206, lsl #16    /* x2 = current frame (RD_base) */
	mov	x3, xzr                  /* x3 = boot CPU RD_base (0 = none) */
gicr_walk:
	ldr	x4, [x2, #GICR_TYPER_OFF] /* GICR_TYPER, 64-bit (RD_base + 0x08) */
	ubfx	x5, x4, #32, #32        /* frame affinity [63:32] */
	eor	x5, x5, x1
	cbz	x5, gicr_match
	tst	x4, #GICR_TYPER_LAST
	b.ne	gicr_wake                /* last frame of the series */
	add	x2, x2, #GICR_FRAME_STRIDE
	b	gicr_walk
gicr_match:
	cmp	x3, xzr
	b.ne	gicr_wake                /* first matching frame wins */
	mov	x3, x2
gicr_wake:
	cbz	x3, gicr_marker        /* no frame matched: print the diagnostic
	                                below and continue (no PPI setup) */
	/* Wake it: GICR_WAKER (RD_base + 0x14): clear ProcessorSleep,
	 * wait for ChildrenAsleep == 0 (bounded - see the note in the
	 * GICR_WAKER_WAIT_MAX comment above). */
	add	x4, x3, #GICR_WAKER_OFF
	ldr	w4, [x4]
	bic	w4, w4, #GICR_WAKER_PS
	str	w4, [x4]
	mov	x7, #GICR_WAKER_WAIT_MAX
1:	ldr	w4, [x4]
	tst	w4, #GICR_WAKER_CA
	b.eq	2f
	cbz	x7, 2f
	sub	x7, x7, #1
	b	1b
2:
	/* SGIs/PPIs to G1NS: GICR_IGROUPR0/IGRPMODR0 at SGI_base
	 * (RD_base + 0x10000); 32-bit accesses only. */
	add	x4, x3, #GICR_SGI_BASE_OFF
	mov	w5, #0xFFFFFFFF
	str	w5, [x4, #GICR_IGROUPR0_OFF]  /* GICR_IGROUPR0 */
	str	w6, [x4, #GICR_IGRPMODR0_OFF] /* GICR_IGRPMODR0 = 0 (w6 = 0) */
	isb

	/* e. ICC_IGRPEN1_EL1 / ICC_PMR_EL1 deliberately NOT set: the
	 * kernel sets them itself at EL1. */
gicr_marker:
	/* "GIC OK" marker, or the "GIC RD NOT FOUND" diagnostic when no
	 * frame matched the boot CPU. */
	mov	x2, #UART1_BASE
	cbz	x3, gicr_nf_str
	adr	x3, gic_str
	b	gicr_print
gicr_nf_str:
	adr	x3, gic_nf_str
gicr_print:
1:
	ldrb	w4, [x3], #1
	cbz	w4, 2f
	ldr	w5, [x2, #0x18]          /* FR */
	tst	w5, #(1 << 5)            /* TXFF */
	bne	1b
	str	w4, [x2, #0x00]          /* DR */
	b	1b
2:
#endif /* TRAMP_GIC_INIT */

	/* Entry: wolfBoot vector table at WOLFBOOT_ORIGIN. Use movz/movk
	 * instead of a literal pool: a literal pool would be placed by the
	 * linker outside .text and could clobber the wolfBoot image.
	 *
	 * NOTE: an ERET executed at EL3 returns to the state in ELR_EL3 and
	 * SPSR_EL3 (NOT ELR_EL2/SPSR_EL2). QEMU's trans_ERET reads
	 * elr_el[current_el] and banked_spsr[banked_spsr_index(current_el)],
	 * which at EL3 are ELR_EL3/SPSR_EL3. This mirrors the BL31 -> BL33
	 * hand-off, where BL31 (at EL3) stages the target in ELR_EL3/SPSR_EL3. */
	movz	x0, #0x0000
	movk	x0, #0x4000, lsl #16
	msr	elr_el3, x0

	/* SPSR_EL3: EL2h with DAIF masked (the BL31 hand-off state) */
	mov	x0, #SPSR_EL2H
	msr	spsr_el3, x0

	isb
	eret

	/* Park secondary cores */
park:
	wfi
	b	park

	.align 3
tramp_str:
	.asciz "TRAMP\n"
gic_str:
	.asciz "GIC OK\n"
gic_nf_str:
	.asciz "GIC RD NOT FOUND\n"

/* ======================================================================
 * EL3 vectors + exception handler (see file header)
 * ====================================================================== */

	.balign 2048                       /* VBAR_ELx must be 2 KiB aligned */
el3_vectors:
	/* AArch64 exception vectors are indexed at VBAR_EL3 + n*0x80 (128-byte
	 * slots). Each slot branches to the common handler (which dispatches on
	 * ESR_ELx.EC); the remaining 124 bytes of the slot are padding. Using
	 * contiguous 4-byte branches would misplace every non-zero vector (e.g.
	 * Lower-EL AArch64 Sync at +0x400 would land mid-handler). */
	.rept 32
	b	el3_exc
	.space	124
	.endr

	/* Handler entry: interrupts are masked by exception entry; SP_EL3
	 * is valid. Save the GPR context (the SMC path must return the
	 * guest's registers untouched apart from x0 = return value). */
	.align 4
el3_exc:
	stp	x0,  x1,  [sp, #-31*16]!
	stp	x2,  x3,  [sp,  #1*16]
	stp	x4,  x5,  [sp,  #2*16]
	stp	x6,  x7,  [sp,  #3*16]
	stp	x8,  x9,  [sp,  #4*16]
	stp	x10, x11, [sp,  #5*16]
	stp	x12, x13, [sp,  #6*16]
	stp	x14, x15, [sp,  #7*16]
	stp	x16, x17, [sp,  #8*16]
	stp	x18, x19, [sp,  #9*16]
	stp	x20, x21, [sp, #10*16]
	stp	x22, x23, [sp, #11*16]
	stp	x24, x25, [sp, #12*16]
	stp	x26, x27, [sp, #13*16]
	stp	x28, x29, [sp, #14*16]
	str	x30,              [sp, #15*16]

	mrs	x0, esr_el3
	ubfx	x1, x0, #26, #6   /* ESR.EC */
	cmp	x1, #0x17         /* EC_SMC64: SMC instruction in AArch64 state
	                          (0x15 is EC_SVC64, 0x18 is EC_SYS64 - see
	                          kernel arch/arm64/include/asm/esr.h and QEMU
	                          target/arm/syndrome.h) */
	b.ne	el3_diag

	/* ---- SMC: answer the minimal PSCI subset --------------------
	 * Each comparison loads the PSCI function id into w27 first: this
	 * binutils refuses CMP immediates above 16 bits ("immediate out of
	 * range"), while the function ids (0x8xxxxxxx / 0xCxxxxxxx) need
	 * more. w27 is a scratch register - the guest context is saved on
	 * the stack and restored before the ERET. */
	ldp	x0,  x1,  [sp,  #0*16]   /* x0 = guest fn id */
	mov	x2, #PSCI_RET_NOT_SUPP   /* default: E_NOT_SUPPORTED */

	/* Trace every SMC to the console: "SMC 0x<fnid>\n". The guest
	 * context is on the stack, so x23/x3/x4/x19-x21 are safe scratch
	 * here; print_hex64() (x0=value, x1=digits) returns via x30,
	 * which is also restored from the stack before the ERET. */
	mov	x23, x0                   /* keep the fn id */
	adr	x3, smc_fn_str
	ldr	x2, =UART1_BASE
1:
	ldrb	w4, [x3], #1
	cbz	w4, 2f
	ldr	w5, [x2, #0x18]
	tst	w5, #(1 << 5)
	bne	1b
	strb	w4, [x2, #0x00]
	b	1b
2:
	mov	x0, x23
	mov	x1, #8
	bl	print_hex64
	ldr	x2, =UART1_BASE
	mov	w4, #0x0a                 /* '\n' */
1:
	ldr	w5, [x2, #0x18]
	tst	w5, #(1 << 5)
	bne	1b
	strb	w4, [x2, #0x00]
	mov	x0, x23

	mov	w27, #PSCI_0_2_VERSION
	cmp	w0, w27
	b.ne	3f
	mov	w2, #0x2                  /* 0.2: (major<<16)|minor */
	b	2f
3:
	mov	w27, #PSCI_1_0_VERSION
	cmp	w0, w27
	b.ne	4f
	mov	w2, #0x10000             /* 1.0: (major<<16)|minor */
	b	2f
4:
	mov	w27, #PSCI_1_1_VERSION
	cmp	w0, w27
	b.ne	5f
	mov	w2, #0x1                  /* 1.1: minor = 1 (major<<16|minor) */
	movk	w2, #0x1, lsl #16
	b	2f
5:
	mov	w27, #PSCI_0_2_MIGRATE_TYPE
	cmp	w0, w27
	b.ne	6f
	mov	w2, #1                    /* 32-bit AArch64 */
	b	2f
6:
	mov	w27, #PSCI_1_0_MIGRATE_TYPE
	cmp	w0, w27
	b.ne	7f
	mov	w2, #1
	b	2f
7:
	mov	w27, #PSCI_1_0_FEATURES
	cmp	w0, w27
	b.ne	8f
	mov	x2, xzr               /* no optional features */
	b	2f
8:
	mov	w27, #PSCI_0_2_SYSTEM_OFF
	cmp	w0, w27
	b.ne	9f
	adr	x3, psci_off_str
	b	psci_print
9:
	mov	w27, #PSCI_1_0_SYSTEM_OFF
	cmp	w0, w27
	b.ne	10f
	adr	x3, psci_off_str
	b	psci_print
10:
	mov	w27, #PSCI_0_2_SYSTEM_RESET
	cmp	w0, w27
	b.ne	11f
	adr	x3, psci_reset_str
	b	psci_print
11:
	mov	w27, #PSCI_1_0_SYSTEM_RESET
	cmp	w0, w27
	b.ne	12f
	adr	x3, psci_reset_str
	b	psci_print
12:
	/* ---- AMD System Controller PM API (QEMU has no SC) ----------
	 * The guest's zynqmp firmware driver (CONFIG_ZYNQMP_FIRMWARE, DTB
	 * node "xlnx,versal2-firmware") issues PLM/SC PM API calls over the
	 * SMC conduit; the stock spi-cadence-quadspi driver needs the OSPI
	 * mux select (PM_IOCTL, IOCTL_OSPI_MUX_SELECT) to work its CSU DMA
	 * reads. QEMU models no System Controller, so answer them here:
	 *   - GET_SIP_SVC_VERSION (0x8200ff03): success, value unused;
	 *   - extended format (x0 = 0xC2000FFF = PM_SIP_SVC | PASS_THROUGH_FW_CMD_ID,
	 *     PASS_THROUGH_FW_CMD_ID = GENMASK(11, 0) = 0xFFF, xlnx-zynqmp.h):
	 *       feature check (x1 upper 32 = PM_FEATURE_CHECK 0x3F) is answered
	 *       with SUCCESS and a ZERO version field - the probe enables the
	 *       per-call feature checks only when (ret & 0xFFFF) >= 1, so 0 keeps
	 *       them off and every later extended call goes straight to the real
	 *       SMC; everything else is XST_PM_SUCCESS (0) - the OSPI mux select
	 *       is a no-op in the QEMU model - with the PM API version (v1.0) in
	 *       the upper 32 for the PM_GET_API_VERSION call (x1 lower = 0x201 =
	 *       XPM_MODULE_ID<<8 | 1), which the kernel reads there;
	 *   - PM_GET_TRUSTZONE_VERSION (basic, x0 = 0xC2000A03): v1.0 in
	 *       the upper 32 (the probe panics below v1.0).
	 * Citations: drivers/firmware/xilinx/zynqmp-{core,pm}.c and
	 * include/linux/firmware/xlnx-zynqmp.h of the EDF 6.18.10-xilinx
	 * kernel. The guest x1 was clobbered by the SMC trace print above,
	 * so reload it from the saved context. */
	ldr	x1,  [sp, #1*16]
	mov	w27, #0xFF03
	movk	w27, #0x8200, lsl #16      /* w27 = 0x8200ff03 (GET_SIP_SVC_VERSION) */
	cmp	w0, w27
	beq	pm_ret
	mov	w27, #0xFFF
	movk	w27, #0xC200, lsl #16      /* w27 = 0xC2000FFF (extended marker) */
	cmp	w0, w27
	b.eq	pm_ext
	mov	w27, #0xA03
	movk	w27, #0xC200, lsl #16      /* w27 = 0xC2000A03 (TZ version, basic) */
	cmp	w0, w27
	b.ne	13f
	mov	x2, #0x10000                 /* TZ v1.0 in the upper 32 */
	lsl	x2, x2, #32
	b	2f
pm_ext:
	ubfx	x5, x1, #32, #32
	cmp	w5, #0x3F                   /* feature check: PM_FEATURE_CHECK up top */
	b.ne	pm_api
	/* SUCCESS + zero version field: the probe only enables the per-call
	 * feature checks when (ret & 0xFFFF) >= 1 (zynqmp_firmware_probe), so
	 * 0 keeps them off (see the header note above). */
	mov	x2, xzr
	b	2f
pm_api:
	cmp	w1, #0x201                  /* PM_GET_API_VERSION (module 2, id 1) */
	b.ne	pm_ok
	mov	x2, #0x10000                 /* PM API v1.0 in the upper 32 */
	lsl	x2, x2, #32
	b	2f
pm_ok:
	mov	x2, xzr                      /* XST_PM_SUCCESS, no data */
	b	2f
pm_ret:
	mov	x2, xzr                      /* success; sip_svc_version unused */
	b	2f
13:
	/* AFFINITY_INFO (all PSCI revisions): E_INACTIVE. Everything else
	 * (CPU_ON/OFF/SUSPEND, MIGRATE, unknown): E_NOT_SUPPORTED.
	 * The single-CPU test kernel (maxcpus=1) only needs the
	 * version/features probes; a reboot from the guest takes the
	 * SYSTEM_RESET paths above. */
	mov	w27, #PSCI_0_2_AFFINITY_INFO
	cmp	w0, w27
	b.eq	aff_inactive
	mov	w27, #PSCI_1_0_AFFINITY_INFO
	cmp	w0, w27
	b.eq	aff_inactive
	mov	w27, #PSCI_1_1_AFFINITY_INFO
	cmp	w0, w27
	b.ne	14f
aff_inactive:
	mov	x2, #PSCI_RET_INACTIVE
14:
	/* Restore the context and ERET past the SMC instruction. The PSCI
	 * return value is in x2; the guest receives it in x0 (PSCI ABI).
	 * Save it, restore all guest registers from the stack, then move
	 * it into x0 AFTER the ELR write (which uses x0 as scratch). */
2:
	mov	x22, x2               /* x22 = return value. x19 must NOT be
	                                used here: the restore block below
	                                reloads the guest's x19 from the
	                                stack and would clobber it. */
	ldp	x0,  x1,  [sp,  #0*16]
	ldp	x2,  x3,  [sp,  #1*16]
	ldp	x4,  x5,  [sp,  #2*16]
	ldp	x6,  x7,  [sp,  #3*16]
	ldp	x8,  x9,  [sp,  #4*16]
	ldp	x10, x11, [sp,  #5*16]
	ldp	x12, x13, [sp,  #6*16]
	ldp	x14, x15, [sp,  #7*16]
	ldp	x16, x17, [sp,  #8*16]
	ldp	x18, x19, [sp,  #9*16]
	ldp	x20, x21, [sp, #10*16]
	ldp	x22, x23, [sp, #11*16]
	ldp	x24, x25, [sp, #12*16]
	ldp	x26, x27, [sp, #13*16]
	ldp	x28, x29, [sp, #14*16]
	ldr	x30,              [sp, #15*16]
	add	sp, sp, #31*16

	mrs	x0, elr_el3
	add	x0, x0, #4            /* SMC is 4 bytes */
	msr	elr_el3, x0
	mov	x0, x22               /* x0 = PSCI return value */
	/* SPSR_EL3 still holds the guest PSTATE saved at entry. */
	eret

	/* SYSTEM_OFF / SYSTEM_RESET side effects (jumped to above). */
	.align 4
psci_print:
	b	psci_msg

	.align 4
psci_msg:
	/* x3 = string; print, then act. x19 keeps the string START: the
	 * print loop below advances x3 to the NUL byte, so the action
	 * dispatch must compare the original address. */
	mov	x19, x3
	ldr	x2, =UART1_BASE
1:
	ldrb	w4, [x3], #1
	cbz	w4, 2f
	ldr	w5, [x2, #0x18]          /* FR */
	tst	w5, #(1 << 5)
	bne	1b
	str	w4, [x2, #0x00]
	b	1b
2:
	/* SYSTEM_OFF was requested: park. (QEMU keeps the machine; the
	 * guest is stopped. SYSTEM_RESET is handled below.) */
	/* Explicit ADR: "cmp x19, #symbol" only encodes a +/-4 KB immediate
	 * in this GAS (no ADR+CMP fallback), so the string must be compared
	 * via a temporary register. x16 is scratch (guest context is on the
	 * stack; this path never returns to the guest). */
	adr	x16, psci_off_str
	cmp	x19, x16
	b.ne	psci_do_reset
park_off:
	wfi
	b	park_off

	/* SYSTEM_RESET: ERET back to the trampoline start - re-run the
	 * BL31 -> BL33 hand-off into wolfBoot (flash persists, so a
	 * confirmed A/B swap boots on reset, like a real reboot). */
	.align 4
psci_do_reset:
	movz	x0, #0x0000
	movk	x0, #0x4000, lsl #16
	msr	elr_el3, x0
	mov	x0, #SPSR_EL2H        /* wolfBoot re-enters at EL2h (DAIF masked) */
	msr	spsr_el3, x0
	isb
	eret

		/* ---- non-SMC EL3 exception: dump and park --------------------
	 * Print "EL3 UNHANDLED EXC: ESR=0x<8> ELR=0x<16> SPSR=0x<8>" so a
	 * regression shows its ESR (EC/DFSC/ISV) and fault address on the
	 * console instead of livelocking, then park. */
	.align 4
el3_diag:
	/* x4 = label to branch to after the header string is printed. */
	adr	x3, diag_str
	adr	x4, el3_diag_esr
	b	diag_print_str

	.align 4
el3_diag_esr:
	mrs	x0, esr_el3
	mov	x1, #8
	adr	x3, diag_mid1
	adr	x4, diag_val_esr
	adr	x5, el3_diag_elr
	b	diag_print_str

	.align 4
diag_val_esr:
	b	print_hex64
	br	x5

	.align 4
el3_diag_elr:
	mrs	x0, elr_el3
	mov	x1, #16
	adr	x3, diag_mid2
	adr	x4, diag_val_elr
	adr	x5, el3_diag_spsr
	b	diag_print_str

	.align 4
diag_val_elr:
	b	print_hex64
	br	x5

	.align 4
el3_diag_spsr:
	mrs	x0, spsr_el3
	mov	x1, #8
	adr	x3, diag_end_str
	adr	x4, diag_val_spsr
	adr	x5, el3_diag_far
	b	diag_print_str

	.align 4
diag_val_spsr:
	b	print_hex64
	br	x5

	.align 4
el3_diag_far:
	mrs	x0, far_el3
	mov	x1, #16
	adr	x3, diag_far_str
	adr	x4, diag_val_far
	mov	x5, #0                   /* park after FAR */
	b	diag_print_str

	.align 4
diag_val_far:
	b	print_hex64
	br	x5

	.align 4
diag_print_str:
	/* x3 = string; print it, then branch to x4 (a label) or park
	 * (x4 = 0). Clobbers x2; x0-x1, x4-x5 preserved. */
	ldr	x2, =UART1_BASE
1:
	ldrb	w4, [x3], #1
	cbz	w4, 2f
	ldr	w5, [x2, #0x18]
	tst	w5, #(1 << 5)
	bne	1b
	str	w4, [x2, #0x00]
	b	1b
2:
	cbz	x4, park_diag
	br	x4

	/* print_hex64: x0 = value, x1 = digits (1..16); print the digits
	 * most-significant-first (zero padded) to UART1, then return.
	 * Clobbers x3, x4, x19-x21. */
	.align 4
print_hex64:
	adr	x19, hexdigits
	ldr	x20, =UART1_BASE
	mov	x21, x1
ph1:
	cbz	x21, ph2
	lsr	x3, x0, #60
	and	w3, w3, #0xF
	add	x22, x19, w3, UXTW
	ldrb	w3, [x22]
	ldr	w4, [x20, #0x18]
	tst	w4, #(1 << 5)
	bne	ph1
	strb	w3, [x20, #0x00]
	lsl	x0, x0, #4
	sub	x21, x21, #1
	b	ph1
ph2:
	ret

	.align 4
park_diag:
	wfi
	b	park_diag

/* =====================================================================
 * EL2 catch vectors (see _start comment): any exception taken at EL2
 * dumps ESR_EL2/ELR_EL2/FAR_EL2 and parks instead of livelocking on the
 * reset VBAR_EL2 (0). Runs at EL2h with SP_EL2 (set above). Reuses the
 * EL3 diag print helpers (plain UART + flat physical accesses, valid
 * with the EL2 MMU off). */
	.balign 2048
el2_vectors:
	.rept 32
	b	el2_trap
	.space	124
	.endr

	.align 4
el2_trap:
	adr	x3, el2_str
	adr	x4, el2_trap_esr
	b	diag_print_str

	.align 4
el2_trap_esr:
	mrs	x0, esr_el2
	mov	x1, #8
	adr	x3, el2_mid1
	adr	x4, el2_val_esr
	adr	x5, el2_trap_elr
	b	diag_print_str

	.align 4
el2_val_esr:
	b	print_hex64
	br	x5

	.align 4
el2_trap_elr:
	mrs	x0, elr_el2
	mov	x1, #16
	adr	x3, el2_mid2
	adr	x4, el2_val_elr
	adr	x5, el2_trap_far
	b	diag_print_str

	.align 4
el2_val_elr:
	b	print_hex64
	br	x5

	.align 4
el2_trap_far:
	mrs	x0, far_el2
	mov	x1, #16
	adr	x3, el2_mid3
	adr	x4, el2_val_far
	mov	x5, #0                   /* park after FAR */
	b	diag_print_str

	.align 4
el2_val_far:
	b	print_hex64
	br	x5

	.size _start, . - _start

	.align 3
psci_off_str:
	.asciz "EL3 PSCI: SYSTEM_OFF\n"
psci_reset_str:
	.asciz "EL3 PSCI: SYSTEM_RESET\n"
smc_fn_str:
	.asciz "SMC 0x"
diag_str:
	.asciz "EL3 UNHANDLED EXC: ESR=0x"
diag_mid1:
	.asciz " ELR=0x"
diag_mid2:
	.asciz " SPSR=0x"
diag_end_str:
	.asciz "\n"
diag_far_str:
	.asciz " FAR=0x"
el2_str:
	.asciz "EL2 TRAP: ESR=0x"
el2_mid1:
	.asciz " ELR=0x"
el2_mid2:
	.asciz " FAR=0x"
el2_mid3:
	.asciz "\n"

	.align 4
hexdigits:
	.byte	'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'
