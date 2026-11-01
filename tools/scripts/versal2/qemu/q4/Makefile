# Makefile - Q4 QEMU flash test (TARGET=versal2, run 2)
#
# Builds flash_test.elf: a tiny bare-metal ELF that runs inside QEMU's
# amd-versal2-virt machine and exercises the REAL OSPI driver core
# (the OSPI_TEST_CORE block of hal/versal2.c, extracted verbatim) -
# flash ID read, 128 KB sector erase, page program, readback - plus,
# in the DMA variant, one CSU DMA read. See flash_test.c.
#
#   make                -> flash_test.elf (STIG path, as in the target)
#   make dma            -> flash_test_dma.elf (WOLFBOOT_OSPI_DMA=1)
#
# NOTE: plain `CC ?=` does not work here because make predefines CC=cc;
# a command-line `make CC=...` still overrides this.
CC      = aarch64-linux-gnu-gcc
HALDIR  := ../../../../../hal
CFLAGS  := -DARCH_AARCH64 -DARCH_64BIT -ffreestanding -nostdlib -O2 -Wall \
           -I$(HALDIR) -I.
LDFLAGS := -nostdlib -static -T q4.ld -Wl,--build-id=none

all: flash_test.elf

versal2_ospi_extract.h: $(HALDIR)/versal2.c
	sed -n '/^\/\*OSPI_TEST_CORE_BEGIN\*\//,/^\/\*OSPI_TEST_CORE_END\*\//p' $< > $@
	test -s $@

flash_test.o: flash_test.c versal2_ospi_extract.h $(HALDIR)/versal2.h
	$(CC) $(CFLAGS) -c -o $@ flash_test.c

flash_test_dma.o: flash_test.c versal2_ospi_extract.h $(HALDIR)/versal2.h
	$(CC) $(CFLAGS) -DWOLFBOOT_OSPI_DMA=1 -c -o $@ flash_test.c

start.o: start.S
	$(CC) $(CFLAGS) -c -o $@ start.S

flash_test.elf: flash_test.o start.o
	$(CC) $(LDFLAGS) -o $@ flash_test.o start.o

flash_test_dma.elf: flash_test_dma.o start.o
	$(CC) $(LDFLAGS) -o $@ flash_test_dma.o start.o

dma: flash_test_dma.elf

clean:
	rm -f flash_test.o flash_test_dma.o start.o flash_test.elf \
	      flash_test_dma.elf versal2_ospi_extract.h

.PHONY: all dma clean
