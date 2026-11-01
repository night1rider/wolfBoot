# wbmtd - wolfBoot partition-state tool for the QEMU local Linux test
# (plan item Q5). Reuses src/libwolfboot.c verbatim (#include); see the
# files in this directory.
#
# Targets:
#   make guest      - static aarch64 binary for the QEMU guest (the real
#                     /dev/mtdN backend)
#   make host       - host build with the file-backed NOR emulation
#                     backend (used by tools/unit-tests/unit-versal2-linux-mtd.c
#                     and for manual checks)
#
# Nothing here is part of the wolfBoot bootloader build; it is a test
# tool (PR 1, QEMU-only).

WOLFBOOT_DIR ?= $(abspath $(CURDIR)/../../../../../..)
CC_HOST      ?= gcc
CC_GUEST     ?= aarch64-linux-gnu-gcc
# Guest binary location: keep it OUT of the repo tree by pointing OUT_GUEST
# at a build dir (e.g. OUT_GUEST=/opt/build/wb-linux/wbmtd.aarch64).
OUT_GUEST    ?= $(CURDIR)/wbmtd.aarch64
OUT_HOST     ?= $(CURDIR)/wbmtd.host

# Same signing/config as config/examples/versal2_vek385_linux.config:
# ECC384/SHA384, 512-byte image header. The partition geometry comes
# from target.h -> wbmtd_target.h.
CFLAGS_COMMON = -O2 -g -std=gnu17 \
  -I$(CURDIR) -I$(WOLFBOOT_DIR)/src -I$(WOLFBOOT_DIR)/include \
  -DEXT_FLASH -DWOLFBOOT_DUALBOOT -DIMAGE_HEADER_SIZE=512 \
  -DALLOW_DOWNGRADE=0

# libwolfboot.c references a few wolfSSL-independent helpers; keep the
# build freestanding from wolfSSL (no EXT_ENCRYPTED).
CFLAGS_GUEST = $(CFLAGS_COMMON) -static -fno-stack-protector
LDFLAGS_GUEST = -static

.PHONY: all guest host test-host clean
all: guest host

guest: $(OUT_GUEST)
host: $(OUT_HOST)

# Host unit test: drive libwolfboot's own trailer operations against the
# file NOR backend and check the exact bytes (see test_trailer_host.c).
test-host: wbmtd_test_host
	./wbmtd_test_host

wbmtd_test_host: test_trailer_host.c mtd_backend.c target.h wbmtd_target.h \
    $(WOLFBOOT_DIR)/src/libwolfboot.c
	$(CC_HOST) $(CFLAGS_COMMON) -DWBMTD_BACKEND_FILE -o $@ test_trailer_host.c

$(OUT_GUEST): wbmtd.c mtd_backend.c target.h wbmtd_target.h \
    $(WOLFBOOT_DIR)/src/libwolfboot.c
	$(CC_GUEST) $(CFLAGS_GUEST) -o $@ wbmtd.c $(LDFLAGS_GUEST)

$(OUT_HOST): wbmtd.c mtd_backend.c target.h wbmtd_target.h \
    $(WOLFBOOT_DIR)/src/libwolfboot.c
	$(CC_HOST) $(CFLAGS_COMMON) -DWBMTD_BACKEND_FILE -o $@ wbmtd.c

clean:
	rm -f $(OUT_GUEST) $(OUT_HOST) wbmtd_test_host
