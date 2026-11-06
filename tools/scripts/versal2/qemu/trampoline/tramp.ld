OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)
SECTIONS
{
    . = 0x800000;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    . = ALIGN(8);
}
