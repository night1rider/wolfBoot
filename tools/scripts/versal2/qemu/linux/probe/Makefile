# Makefile - Q5 Linux-test OSPI DAC/STIG bring-up probe (TARGET=versal2).
#
# Builds dac_test.elf: a tiny bare-metal ELF that runs inside QEMU's
# amd-versal2-virt machine and validates the OSPI access paths the guest
# Linux MTD driver will use (STIG erase + ID, and the AXI DAC linear
# window for bulk program/read). See dac_test.c.
#
#   make          -> dac_test.elf
#
CC      = aarch64-linux-gnu-gcc
CFLAGS  := -DARCH_AARCH64 -DARCH_64BIT -ffreestanding -nostdlib -O2 -Wall
LDFLAGS := -nostdlib -static -T dac.ld -Wl,--build-id=none

all: dac_test.elf

dac_test.o: dac_test.c
	$(CC) $(CFLAGS) -c -o $@ dac_test.c

start.o: start.S
	$(CC) $(CFLAGS) -c -o $@ start.S

dac_test.elf: dac_test.o start.o
	$(CC) $(LDFLAGS) -o $@ dac_test.o start.o

clean:
	rm -f dac_test.elf dac_test.o start.o

.PHONY: all clean
