/* trampoline.S
 *
 * QEMU-only stand-in for the BL31 -> wolfBoot hand-off: EL3 to non-secure
 * EL2 at 0x40000000, with a minimal PSCI and an EL3 exception dump.
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
/* SCR_EL3 for non-secure AArch64 EL2: HCE for Linux `hvc #0`; IRQ/FIQ
 * clear so GIC and WFI do not trap to EL3. QEMU forces RW on. */
	.equ SCR_NS,  1 << 0
	.equ SCR_EA,  1 << 3
	.equ SCR_HCE, 1 << 8   /* cpu.h SCR_HCE; HVC at EL1 needs it */
	.equ SCR_RW,  1 << 11
/* SPSR: EL2h (mode 0b1001) with DAIF masked, the BL31 -> BL33 state. */
	.equ SPSR_EL2H, 0x3C9
/* EL3 exception stack top, in QEMU low DDR. It is clear of the DTB
 * (0x1800000) and the kernel area (0x20000000 and up). */
	.equ EL3_STACK_TOP, 0x880000
/* EL2 exception stack top. SP_EL2 resets to 0, so without this an EL2
 * trap would fault on its first stack write. */
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
	/* Park all cores but cpu0 (QEMU only powers cpu0). */
	mrs	x0, mpidr_el1
	ubfx	x1, x0, #0, #8      /* affinity 0 */
	ubfx	x2, x0, #8, #8      /* affinity 1 */
	add	x1, x1, x2
	cbnz	x1, park

	/* Turn on UART1 (QEMU starts it off). The divisors are for 115200
	 * baud at 100 MHz (AM026 p670): IBRD 54, FBRD 16. QEMU ignores them. */
	mov	x2, #UART1_BASE
	str	wzr, [x2, #0x30]          /* CR = 0 (disable); 32-bit only */
	mov	x3, #54
	str	w3, [x2, #0x24]          /* IBRD: 100e6/(16*115200)=54.25 */
	mov	x3, #16
	str	w3, [x2, #0x28]          /* FBRD: 54 + 16/64 (AM026 p670) */
	mov	x3, #0x60
	str	w3, [x2, #0x2C]          /* LCR: 8N1, FIFOs */
	mov	x3, #0x203
	str	w3, [x2, #0x30]          /* CR: enable, TX, RX */

	/* Print "TRAMP\n" - proves the trampoline is running at EL3 */
	adr	x3, tramp_str
	bl	diag_print_str

	/* OSPI trigger window 16 -> 256 bytes (IND_TRIG_ADDR_RANGE = 8), for
	 * the Linux flash driver. On the board the PLM owns this register. */
	movz	x0, #0x0080
	movk	x0, #0xF101, lsl #16     /* OSPI base 0xF1010000 + 0x80 */
	mov	w1, #0x8
	str	w1, [x0]

	/* Timer at 100 MHz, as BL31 would (QEMU resets it to 1 GHz). On the
	 * board, firmware sets it (AM028 CNTFID0). */
	movz	x0, #0xE100
	movk	x0, #0x5F5, lsl #16
	msr	cntfrq_el0, x0

	/* Lower levels run non-secure AArch64; see the SCR_EL3 note above. */
	mov	x0, #(SCR_NS | SCR_EA | SCR_HCE | SCR_RW)
	msr	scr_el3, x0

	/* Set the EL3 stack and vector table (both reset to 0). There is no
	 * MSR name for SP_EL3, but at EL3h "sp" is SP_EL3, so use "mov sp". */
	movz	x0, #0x0
	movk	x0, #0x88, lsl #16     /* EL3_STACK_TOP = 0x880000 */
	mov	sp, x0			/* sp == SP_EL3 at EL3h */
	adr	x0, el3_vectors
	msr	vbar_el3, x0

	/* EL2 catch table and stack: a guest trap to EL2 prints ESR/ELR/FAR
	 * on UART1 and parks, instead of hanging with no message. */
	movz	x0, #0x0
	movk	x0, #0x8C, lsl #16     /* EL2_STACK_TOP = 0x8C0000 */
	msr	sp_el2, x0
	adr	x0, el2_vectors
	msr	vbar_el2, x0

#ifdef TRAMP_GIC_INIT
	/* GICv3 setup BL31 does on the board (-DTRAMP_GIC_INIT); without it the
	 * kernel timer never ticks in QEMU. Steps a-e follow TF-A gic/v3. */
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
	/* Max wait for ChildrenAsleep. QEMU 11.1.3 can ignore GICR_WAKER
	 * writes, so an endless wait would hang. Hardware clears it fast. */
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

	/* c. Put all SPIs in Group 1 non-secure, for n = 1 .. ITLinesNumber
	 * (GICD_TYPER[4:0]). 32-bit accesses only. */
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

	/* d. Find the boot CPU's redistributor: the frame whose GICR_TYPER
	 * [63:32] matches MPIDR_EL1 [63:32]. Stop at the Last frame (bit 4). */
	mrs	x0, mpidr_el1
	lsr	x1, x0, #32               /* boot CPU Aff3.Aff2.Aff1.Aff0 */
	movz	x2, #0xE206, lsl #16    /* x2 = current frame (RD_base) */
	mov	x3, xzr                  /* x3 = boot CPU RD_base (0 = none) */
gicr_walk:
	ldr	x4, [x2, #GICR_TYPER_OFF] /* GICR_TYPER is 64-bit */
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
	cbz	x3, gicr_marker        /* none matched: print error, skip */
	/* Wake it: clear ProcessorSleep in GICR_WAKER, then wait (with a
	 * limit) for ChildrenAsleep to clear. */
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
	/* Put SGIs/PPIs (and the timer) in Group 1 non-secure, at SGI_base.
	 * 32-bit accesses only. */
	add	x4, x3, #GICR_SGI_BASE_OFF
	mov	w5, #0xFFFFFFFF
	str	w5, [x4, #GICR_IGROUPR0_OFF]  /* GICR_IGROUPR0 */
	str	w6, [x4, #GICR_IGRPMODR0_OFF] /* GICR_IGRPMODR0 = 0 (w6 = 0) */
	isb

	/* e. ICC_IGRPEN1_EL1 and ICC_PMR_EL1: left for the kernel. */
gicr_marker:
	/* Print "GIC OK", or "GIC RD NOT FOUND" if no frame matched. */
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

	/* Jump to WOLFBOOT_ORIGIN with movz/movk (no literal pool on top of
	 * wolfBoot). ERET uses ELR_EL3 and SPSR_EL3, like BL31. */
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

/* EL3 vectors and exception handler */

	.balign 2048                       /* VBAR_ELx must be 2 KiB aligned */
el3_vectors:
	/* Each vector is a 128-byte slot (VBAR_EL3 + n*0x80). Each slot
	 * branches to the common handler; the other 124 bytes are padding. */
	.rept 32
	b	el3_exc
	.space	124
	.endr

	/* Save all guest registers. The SMC path must give them back
	 * unchanged, except x0 (the return value). */
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
	cmp	x1, #0x17         /* EC 0x17 = SMC from AArch64 (asm/esr.h) */
	b.ne	el3_diag

	/* ---- SMC: a small PSCI subset. Function ids go in w27 first (too
	 * big for CMP); guest registers are on the stack. */
	ldp	x0,  x1,  [sp,  #0*16]   /* x0 = guest fn id */

	/* Print every SMC as "SMC 0x<fnid>". The guest registers are on the
	 * stack, so these registers (and x30) are free to use. */
	mov	x23, x0                   /* keep the fn id */
	adr	x3, smc_fn_str
	bl	diag_print_str
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
	/* Set the default only now: the print above uses x2. */
	mov	x2, #PSCI_RET_NOT_SUPP   /* default: E_NOT_SUPPORTED */

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
	/* ---- AMD PM API calls (QEMU has no System Controller): Linux needs
	 * replies to probe and set the OSPI mux. Reload x1 (changed above). */
	ldr	x1,  [sp, #1*16]
	mov	w27, #0xFF03
	movk	w27, #0x8200, lsl #16 /* GET_SIP_SVC_VERSION */
	cmp	w0, w27
	beq	pm_ret
	mov	w27, #0xFFF
	movk	w27, #0xC200, lsl #16 /* extended call marker */
	cmp	w0, w27
	b.eq	pm_ext
	mov	w27, #0xA03
	movk	w27, #0xC200, lsl #16 /* TrustZone version */
	cmp	w0, w27
	b.ne	13f
	mov	x2, #0x10000                 /* TZ v1.0 in the upper 32 */
	lsl	x2, x2, #32
	b	2f
pm_ext:
	ubfx	x5, x1, #32, #32
	cmp	w5, #0x3F                   /* PM_FEATURE_CHECK in upper 32 */
	b.ne	pm_api
	/* Reply success with version 0. Then the probe turns off the
	 * per-call feature checks (zynqmp_firmware_probe). */
	mov	x2, xzr
	b	2f
pm_api:
	cmp	w1, #0x201 /* PM_GET_API_VERSION */
	b.ne	pm_ok
	mov	x2, #0x10000                 /* PM API v1.0 in the upper 32 */
	lsl	x2, x2, #32
	b	2f
pm_ok:
	mov	x2, xzr                      /* XST_PM_SUCCESS, no data */
	b	2f
pm_ret:
	mov	x2, xzr /* success */
	b	2f
13:
	/* AFFINITY_INFO gets "inactive". All else (CPU_ON/OFF/SUSPEND, MIGRATE,
	 * unknown) gets "not supported". The test kernel uses only one CPU. */
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
	/* Return past the SMC with the result in the guest's x0: write it to
	 * the saved x0 slot, then restore all guest registers. */
2:
	str	x2, [sp, #0*16]
	mrs	x0, elr_el3
	add	x0, x0, #4            /* SMC is 4 bytes */
	msr	elr_el3, x0
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
	/* SPSR_EL3 still holds the guest PSTATE saved at entry. */
	eret

	/* SYSTEM_OFF / SYSTEM_RESET side effects (jumped to above). */
	.align 4
psci_print:
	b	psci_msg

	.align 4
psci_msg:
	/* x3 = string. Print it, then act. x19 keeps the string start,
	 * because the print loop moves x3. */
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
	/* SYSTEM_OFF: park. SYSTEM_RESET is handled below. */
	/* Compare through x16: this GAS can't do "cmp x19, #symbol". x16 is
	 * free, since this path never returns to the guest. */
	adr	x16, psci_off_str
	cmp	x19, x16
	b.ne	psci_do_reset
park_off:
	wfi
	b	park_off

	/* SYSTEM_RESET: ERET back into wolfBoot, like a reboot. The flash
	 * keeps its data, so a confirmed A/B update boots. */
	.align 4
psci_do_reset:
	movz	x0, #0x0000
	movk	x0, #0x4000, lsl #16
	msr	elr_el3, x0
	mov	x0, #SPSR_EL2H        /* back in at EL2h, DAIF masked */
	msr	spsr_el3, x0
	isb
	eret

	/* ---- Other EL3 exception: print ESR/ELR/SPSR/FAR, then park ----
	 * This shows the fault on the console instead of hanging silently. */
	.align 4
el3_diag:
	adr	x3, diag_str             /* "... ESR=0x" */
	bl	diag_print_str
	mrs	x0, esr_el3
	mov	x1, #8
	bl	print_hex64
	adr	x3, diag_mid1            /* " ELR=0x" */
	bl	diag_print_str
	mrs	x0, elr_el3
	mov	x1, #16
	bl	print_hex64
	adr	x3, diag_mid2            /* " SPSR=0x" */
	bl	diag_print_str
	mrs	x0, spsr_el3
	mov	x1, #8
	bl	print_hex64
	adr	x3, diag_far_str         /* " FAR=0x" */
	bl	diag_print_str
	mrs	x0, far_el3
	mov	x1, #16
	bl	print_hex64
	adr	x3, diag_end_str         /* "\n" */
	bl	diag_print_str
	b	park_diag

	.align 4
diag_print_str:
	/* Print the string at x3 on UART1, then return. Changes x2, x3, w6,
	 * w7. Waits while the TX FIFO is full, so no character is lost. */
	ldr	x2, =UART1_BASE
1:
	ldrb	w6, [x3], #1
	cbz	w6, 3f
2:
	ldr	w7, [x2, #0x18]
	tst	w7, #(1 << 5)
	bne	2b
	strb	w6, [x2, #0x00]
	b	1b
3:
	ret

	/* print_hex64: print x0 as x1 hex digits (1..16) on UART1, top digit
	 * first. Changes x3, x4 and x19-x22. */
	.align 4
print_hex64:
	adr	x19, hexdigits
	ldr	x20, =UART1_BASE
	mov	x21, x1
	/* Move the low x1 digits to the top, so they print (not the high
	 * digits). */
	mov	x22, #16
	sub	x22, x22, x1
	lsl	x22, x22, #2
	lsl	x0, x0, x22
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

/* ==== EL2 catch vectors: any EL2 exception prints ESR/ELR/FAR and parks,
 * instead of hanging. Uses the EL3 print helpers (fine with the MMU off). */
	.balign 2048
el2_vectors:
	.rept 32
	b	el2_trap
	.space	124
	.endr

	.align 4
el2_trap:
	adr	x3, el2_str              /* "EL2 TRAP: ESR=0x" */
	bl	diag_print_str
	mrs	x0, esr_el2
	mov	x1, #8
	bl	print_hex64
	adr	x3, el2_mid1             /* " ELR=0x" */
	bl	diag_print_str
	mrs	x0, elr_el2
	mov	x1, #16
	bl	print_hex64
	adr	x3, el2_mid2             /* " FAR=0x" */
	bl	diag_print_str
	mrs	x0, far_el2
	mov	x1, #16
	bl	print_hex64
	adr	x3, el2_mid3             /* "\n" */
	bl	diag_print_str
	b	park_diag

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
