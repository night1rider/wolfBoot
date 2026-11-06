# wbmtd - wolfBoot partition-state tool for the QEMU local Linux test
# Reuses src/libwolfboot.c verbatim (#include); see the
# files in this directory.
#
# Targets:
#   make guest      - static aarch64 binary for the QEMU guest (the real
#                     /dev/mtdN backend)
#   make host       - host build with the file-backed NOR emulation
#                     backend (for manual checks)
#   make test-host  - host trailer test (test_trailer_host.c)
#
# Nothing here is part of the wolfBoot bootloader build; it is a test
# tool (QEMU only).

WOLFBOOT_DIR ?= $(abspath $(CURDIR)/../../../../../..)
CC_HOST      ?= gcc
CC_GUEST     ?= aarch64-linux-gnu-gcc
# Set OUT_GUEST to a build dir to keep the binary out of the repo,
# e.g. OUT_GUEST=/opt/build/wb-linux/wbmtd.aarch64.
OUT_GUEST    ?= $(CURDIR)/wbmtd.aarch64
OUT_HOST     ?= $(CURDIR)/wbmtd.host

# Same settings as versal2_vek385_linux.config (512-byte header). The
# partition layout is in wbmtd_target.h.
CFLAGS_COMMON = -O2 -g -std=gnu17 \
  -I$(CURDIR) -I$(WOLFBOOT_DIR)/src -I$(WOLFBOOT_DIR)/include \
  -DEXT_FLASH -DWOLFBOOT_DUALBOOT -DIMAGE_HEADER_SIZE=512 \
  -DALLOW_DOWNGRADE=0

# No wolfSSL is needed (no EXT_ENCRYPTED).
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
