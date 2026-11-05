/* ospi_tool.ld - link the board OSPI tool at 0x40000000, where BL31
 * starts BL33 (wolfBoot's address). 64 KB of stack after BSS. */
OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)
SECTIONS
{
    . = 0x40000000;
    .text : { *(.text.start) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    . = ALIGN(16);
    _bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    _bss_end = .;
    . = . + 0x10000;
    _stack_top = .;
}
