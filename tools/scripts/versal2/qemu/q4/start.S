/* start.S
 *
 * Minimal reset start for the Q4 QEMU flash test (see flash_test.c).
 * QEMU amd-versal2-virt starts cpu0 at EL3 with the MMU off; the test
 * needs nothing more than a stack and a jump to main() (UART init is
 * done in C, as in the trampoline).
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

/* start.ld places .text/.rodata/.data at 0x800000 and reserves RAM
 * above; the stack pointer starts at 0x820000 (128 KB above the load
 * base), well clear of the image. */

_start:
	movz	x0, #0x0000
	movk	x0, #0x82, lsl #16
	mov	sp, x0
	bl	main

	/* main() should not return; park anyway */
2:
	wfi
	b	2b

	.size _start, . - _start
