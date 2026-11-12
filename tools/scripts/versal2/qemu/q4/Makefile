# Makefile - Q4 QEMU flash test (TARGET=versal2)
#
# Builds flash_test.elf: a tiny bare-metal ELF that runs inside QEMU's
# amd-versal2-virt machine and exercises the REAL flash code: the ext_flash
# code of hal/wolfhal.c (extracted verbatim) on the wolfHAL drivers the
# VEK385 board links (lib/wolfHAL: spimem/cadence_ospi_spimem,
# spimem/versal2_ospi_dma, flash/spimem_nor_flash, uart/pl011_uart) -
# flash ID read, 128 KB sector erase, page program, readback - plus, in
# the DMA variant, CSU DMA reads. See flash_test.c.
#
#   make                -> flash_test.elf (STIG path, as in the target)
#   make dma            -> flash_test_dma.elf (WOLFBOOT_OSPI_DMA=1)
#
# NOTE: plain `CC ?=` does not work here because make predefines CC=cc;
# a command-line `make CC=...` still overrides this.
CC      = aarch64-linux-gnu-gcc
ROOT    := ../../../../..
HALDIR  := $(ROOT)/hal
WOLFHAL := $(ROOT)/lib/wolfHAL
CFLAGS  := -DARCH_AARCH64 -DARCH_64BIT -ffreestanding -nostdlib -O2 -Wall \
           -mstrict-align -I$(HALDIR) -I$(HALDIR)/boards/vek385 \
           -I$(ROOT)/include -I$(WOLFHAL) -I.
LDFLAGS := -nostdlib -static -T q4.ld -Wl,--build-id=none

# The wolfHAL drivers of hal/boards/vek385/board.mk, plus the dispatch
# sources: this test calls them through their driver structs.
WHAL_SRC := $(WOLFHAL)/src/reg.c $(WOLFHAL)/src/uart/uart.c \
            $(WOLFHAL)/src/uart/pl011_uart.c $(WOLFHAL)/src/spimem/spimem.c \
            $(WOLFHAL)/src/spimem/cadence_ospi_spimem.c \
            $(WOLFHAL)/src/spimem/versal2_ospi_dma.c \
            $(WOLFHAL)/src/flash/flash.c \
            $(WOLFHAL)/src/flash/spimem_nor_flash.c
WHAL_OBJS := $(foreach s,$(WHAL_SRC),whal_$(notdir $(s:.c=.o)))

all: flash_test.elf

wolfhal_ext_flash_extract.h: $(HALDIR)/wolfhal.c
	sed -n '/^\/\*WOLFHAL_EXT_FLASH_BEGIN\*\//,/^\/\*WOLFHAL_EXT_FLASH_END\*\//p' $< > $@
	test -s $@

define whal_obj
whal_$(notdir $(1:.c=.o)): $(1)
	$$(CC) $$(CFLAGS) -c -o $$@ $$<
endef
$(foreach s,$(WHAL_SRC),$(eval $(call whal_obj,$(s))))

DEPS := flash_test.c wolfhal_ext_flash_extract.h $(HALDIR)/versal2.h \
        $(HALDIR)/boards/vek385/wolfHAL_board.h

flash_test.o: $(DEPS)
	$(CC) $(CFLAGS) -c -o $@ flash_test.c

flash_test_dma.o: $(DEPS)
	$(CC) $(CFLAGS) -DWOLFBOOT_OSPI_DMA=1 -c -o $@ flash_test.c

start.o: start.S
	$(CC) $(CFLAGS) -c -o $@ start.S

flash_test.elf: flash_test.o start.o $(WHAL_OBJS)
	$(CC) $(LDFLAGS) -o $@ flash_test.o start.o $(WHAL_OBJS)

flash_test_dma.elf: flash_test_dma.o start.o $(WHAL_OBJS)
	$(CC) $(LDFLAGS) -o $@ flash_test_dma.o start.o $(WHAL_OBJS)

dma: flash_test_dma.elf

clean:
	rm -f flash_test.o flash_test_dma.o start.o flash_test.elf \
	      flash_test_dma.elf wolfhal_ext_flash_extract.h $(WHAL_OBJS)

.PHONY: all dma clean
