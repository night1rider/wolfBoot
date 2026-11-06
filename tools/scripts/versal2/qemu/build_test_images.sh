#!/bin/bash
#
# build_test_images.sh - build everything test_qemu.sh needs for
# wolfBoot TARGET=versal2 (VEK385):
#   - wolfBoot from config/examples/versal2_vek385.config,
#   - the EL3 -> EL2 trampoline (stage/tramp.elf),
#   - the Q4 flash-test ELFs (STIG path + CSU DMA variant),
#   - the signed v1 and v2 test-app images (stage/img_v{1,2}_signed.bin).
#
# Used by .github/workflows/test-versal2-qemu.yml; also works for local
# runs. Needs the aarch64-linux-gnu- cross compiler.
#
# Usage: ./build_test_images.sh
#
set -euxo pipefail

QEMU_DIR="$(cd "$(dirname "$0")" && pwd)"
WOLFBOOT_DIR="${WOLFBOOT_DIR:-$(cd "$QEMU_DIR/../../../.." && pwd)}"
STAGE="$QEMU_DIR/stage"

cd "$WOLFBOOT_DIR"
cp config/examples/versal2_vek385.config .config
make clean TARGET=versal2
make TARGET=versal2
test -s wolfboot.elf

# `stage/` holds build artifacts only and is not in git.
mkdir -p "$STAGE"
aarch64-linux-gnu-gcc -nostdlib -nostartfiles -static -march=armv8-a \
  -T "$QEMU_DIR/trampoline/tramp.ld" -o "$STAGE/tramp.elf" \
  "$QEMU_DIR/trampoline/trampoline.S"
make -C "$QEMU_DIR/q4"
make -C "$QEMU_DIR/q4" dma

export IMAGE_HEADER_SIZE=512 WOLFBOOT_PARTITION_SIZE=0x2C00000 \
       WOLFBOOT_SECTOR_SIZE=0x20000
for v in 1 2; do
  make -C test-app clean TARGET=versal2 WOLFBOOT_VERSION=$v
  make -C test-app TARGET=versal2 WOLFBOOT_VERSION=$v
  tools/keytools/sign --ecc384 --sha384 \
    test-app/image.elf wolfboot_signing_private_key.der $v
  cp test-app/image_v${v}_signed.bin "$STAGE/img_v${v}_signed.bin"
done
