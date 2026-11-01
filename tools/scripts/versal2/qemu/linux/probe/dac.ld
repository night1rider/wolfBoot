/* q4.ld - link the Q4 QEMU flash test at QEMU low DDR (0x800000),
 * leaving RAM above the image for the stack (see start.S). */
OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)
SECTIONS
{
    . = 0x800000;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(8);
}
