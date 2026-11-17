/* start.S
 *
 * OSPI tool entry (EL2, MMU off from BL31): set the stack, clear BSS,
 * call main().
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

	.section .text.start
	.global _start
	.type _start, %function

_start:
	ldr	x0, =_stack_top
	mov	sp, x0

	/* Clear BSS: the PLM does not zero it. */
	ldr	x0, =_bss_start
	ldr	x1, =_bss_end
1:
	cmp	x0, x1
	b.hs	2f
	str	xzr, [x0], #8
	b	1b
2:
	bl	main

	/* main() should not return; if it does, wait here forever */
3:
	wfi
	b	3b

	.size _start, . - _start
