# Makefile - board OSPI tool (TARGET=versal2, VEK385)
#
# Builds tiny bare-metal ELFs that BL31 starts in wolfBoot's place. They
# use the REAL flash code: the ext_flash code of hal/wolfhal.c (extracted
# verbatim) on the wolfHAL drivers the VEK385 board links (lib/wolfHAL),
# so the partition guard applies. See ospi_tool.c.
#
#   make                -> ospi_scan.elf (read only, DMA reads)
#   make map            -> ospi_map.elf (whole flash map, read only)
#   make write          -> ospi_write_boot.elf, ospi_write_update.elf
#   make OSPI_DMA=0 ... -> the same, STIG reads only
#
# NOTE: plain `CC ?=` does not work here because make predefines CC=cc;
# a command-line `make CC=...` still overrides this.
CC      = aarch64-linux-gnu-gcc
ROOT    := ../../../../..
HALDIR  := $(ROOT)/hal
WOLFHAL := $(ROOT)/lib/wolfHAL
CFLAGS  := -DARCH_AARCH64 -DARCH_64BIT -ffreestanding -nostdlib -O2 -Wall \
           -mgeneral-regs-only -mstrict-align -I$(HALDIR) \
           -I$(HALDIR)/boards/vek385 -I$(ROOT)/include -I$(WOLFHAL) -I.
# OSPI_DMA=0 reads with STIG only (AMD's QEMU fork has no DMA model).
OSPI_DMA ?= 1
ifeq ($(OSPI_DMA),1)
CFLAGS  += -DWOLFBOOT_OSPI_DMA=1
endif
LDFLAGS := -nostdlib -static -T ospi_tool.ld -Wl,--build-id=none \
           -Wl,--no-warn-rwx-segments

# The wolfHAL drivers of hal/boards/vek385/board.mk, plus the dispatch
# sources: this tool calls them through their driver structs.
WHAL_SRC := $(WOLFHAL)/src/reg.c $(WOLFHAL)/src/uart/uart.c \
            $(WOLFHAL)/src/uart/pl011_uart.c $(WOLFHAL)/src/spimem/spimem.c \
            $(WOLFHAL)/src/spimem/cadence_ospi_spimem.c \
            $(WOLFHAL)/src/spimem/versal2_ospi_dma.c \
            $(WOLFHAL)/src/flash/flash.c \
            $(WOLFHAL)/src/flash/spimem_nor_flash.c
WHAL_OBJS := $(foreach s,$(WHAL_SRC),whal_$(notdir $(s:.c=.o)))

all: ospi_scan.elf

wolfhal_ext_flash_extract.h: $(HALDIR)/wolfhal.c
	sed -n '/^\/\*WOLFHAL_EXT_FLASH_BEGIN\*\//,/^\/\*WOLFHAL_EXT_FLASH_END\*\//p' $< > $@
	test -s $@

define whal_obj
whal_$(notdir $(1:.c=.o)): $(1)
	$$(CC) $$(CFLAGS) -c -o $$@ $$<
endef
$(foreach s,$(WHAL_SRC),$(eval $(call whal_obj,$(s))))

DEPS := ospi_tool.c wolfhal_ext_flash_extract.h $(HALDIR)/versal2.h \
        $(HALDIR)/boards/vek385/wolfHAL_board.h

ospi_scan.o: $(DEPS)
	$(CC) $(CFLAGS) -DOT_MODE_SCAN -c -o $@ ospi_tool.c

ospi_map.o: $(DEPS)
	$(CC) $(CFLAGS) -DOT_MODE_MAP -c -o $@ ospi_tool.c

ospi_write_boot.o: $(DEPS)
	$(CC) $(CFLAGS) -DOT_MODE_WRITE -DOT_DST=0x1DC0000UL -c -o $@ ospi_tool.c

ospi_write_update.o: $(DEPS)
	$(CC) $(CFLAGS) -DOT_MODE_WRITE -DOT_DST=0x49C0000UL -c -o $@ ospi_tool.c

start.o: start.S
	$(CC) $(CFLAGS) -c -o $@ start.S

%.elf: %.o start.o $(WHAL_OBJS) ospi_tool.ld
	$(CC) $(LDFLAGS) -o $@ $< start.o $(WHAL_OBJS)

map: ospi_map.elf

write: ospi_write_boot.elf ospi_write_update.elf

clean:
	rm -f *.o *.elf wolfhal_ext_flash_extract.h

.PHONY: all map write clean
