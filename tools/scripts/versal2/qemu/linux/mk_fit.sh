#!/bin/bash
#
# mk_fit.sh - Build the signed FIT image(s) that wolfBoot boots for the
# versal2 QEMU local Linux test: a gzip-compressed AMD EDF Linux kernel
# (Image) + the guest DTB + a gzip-compressed initramfs, packed into a FIT
# and signed with the wolfBoot key (ECC384/SHA384) to match the wolfBoot
# build (config/examples/versal2_vek385_linux.config).
#
# The FIT is built with U-Boot's `mkimage -f` (installed in the VM) from
# linux.its (kept in this directory), following the FIT examples in
# docs/Targets.md (Gen 1 versal hal/versal.its, zynqmp) and what hal/ +
# src/fdt.c / src/update_ram.c expect: a `kernel` sub-image with
# load/entry, a `flat_dt` sub-image (wolfBoot relocates it to
# WOLFBOOT_LOAD_DTS_ADDRESS) and a `ramdisk` sub-image with a load
# address; compression = "gzip" with config GZIP=1 because the kernel
# sub-image is Image.gz.
#
# linux.its carries two placeholders - @BUILDDIR@ (the build directory,
# outside the repo) and @RAMDISK@ (the initramfs filename) - which this
# script substitutes before calling mkimage; the substituted file lives
# in the build dir, the repo keeps only the template.
#
# Subimages (addresses match the linux config):
#   kernel-1  Image.gz          load/entry 0x24000000 (576 MB, low RAM;
#            (EDF kernel,        WOLFBOOT_LOAD_KERNEL_ADDRESS=0 -> follow
#             33 MB raw)         the FIT load/entry)
#   fdt-1     kernel.dtb        no load property: wolfBoot copies the FIT
#            (from mk_dtb.sh)    fdt to WOLFBOOT_LOAD_DTS_ADDRESS=0x1F000000
#   ramdisk-1 initramfs.cpio.gz  load 0x30000000 (768 MB, low RAM;
#            (from               WOLFBOOT_LOAD_RAMDISK_ADDRESS=0x30000000
#             mk_initramfs.sh)   overrides it)
#
# The whole signed FIT is staged by wolfBoot at WOLFBOOT_LOAD_ADDRESS
# (0x20000000) and must fit the 44 MB partition (checked below).
#
# This script builds BOTH signed FITs the local test needs:
#   $BUILD/fit_v1_signed.bin  - version 1, with the FULL initramfs
#                               (initramfs.cpio.gz, which embeds the v2
#                               FIT as /v2.fit so the guest can write the
#                               update to the UPDATE partition - L2/L3);
#   $BUILD/fit_v2_signed.bin  - version 2, with the PLAIN initramfs
#                               (initramfs-plain.cpio.gz, no embedded FIT;
#                               this is the image wbmtd writes during the
#                               update test).
#
# Inputs (env overrides; defaults build a self-contained chain):
#   BUILD            build dir outside the repo
#                    (default /opt/build/wb-linux)
#   KERNEL_IMAGE     EDF kernel Image (raw)
#                    (default $BUILD/Image, copied there by test_linux.sh
#                    from the EDF WIC boot part.)
#   KERNEL_DTB       guest DTB
#                    (default $BUILD/kernel.dtb, from mk_dtb.sh)
#   INITRAMFS        full initramfs
#                    (default $BUILD/initramfs.cpio.gz)
#   INITRAMFS_PLAIN  plain initramfs
#                    (default $BUILD/initramfs-plain.cpio.gz)
#   SIGN_TOOL        wolfBoot sign tool
#                    (default <repo>/tools/keytools/sign)
#   PRIVATE_KEY      wolfBoot signing key
#                    (default <repo>/wolfboot_signing_private_key.der)
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# repo root is 5 levels up: wolfboot/tools/scripts/versal2/qemu/linux
WBOOT="$(cd "$HERE/../../../../../" && pwd)"
BUILD="${BUILD:-/opt/build/wb-linux}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$BUILD/Image}"
KERNEL_DTB="${KERNEL_DTB:-$BUILD/kernel.dtb}"
INITRAMFS="${INITRAMFS:-$BUILD/initramfs.cpio.gz}"
INITRAMFS_PLAIN="${INITRAMFS_PLAIN:-$BUILD/initramfs-plain.cpio.gz}"
OUT_V1="${OUT_V1:-$BUILD/fit_v1_signed.bin}"
OUT_V2="${OUT_V2:-$BUILD/fit_v2_signed.bin}"
# L5c FITs: v1c is a signed older v1 that the v2c guest writes to UPDATE.
# v2c carries v1c as /v1c.fit. They are separate from the L1-L5 FITs
# because the full 29 MB v1 FIT would make v2c too big for 44 MB.
OUT_V1C="${OUT_V1C:-$BUILD/fit_v1c_signed.bin}"
OUT_V2C="${OUT_V2C:-$BUILD/fit_v2c_signed.bin}"
INITRAMFS_V1C="${INITRAMFS_V1C:-$BUILD/initramfs-extra.cpio.gz}"
# Set FIT_xx=0 to skip a FIT. test_linux.sh builds in two passes because
# the v1 initramfs holds the v2 FIT (and v2c holds v1c).
FIT_V1="${FIT_V1:-1}"
FIT_V2="${FIT_V2:-1}"
FIT_V1C="${FIT_V1C:-0}"
FIT_V2C="${FIT_V2C:-0}"
# Signing settings match versal2_vek385_linux.config (ECC384, SHA384,
# 512-byte header). wolfboot.elf holds the public key for this key.
SIGN_TOOL="${SIGN_TOOL:-$WBOOT/tools/keytools/sign}"
PRIVATE_KEY="${PRIVATE_KEY:-$WBOOT/wolfboot_signing_private_key.der}"
KB=1024
MB=1048576
# Each signed FIT must fit the 44 MB BOOT/UPDATE partition.
PART_SIZE=$((0x2c00000))

command -v mkimage >/dev/null || {
    echo "mkimage not found (u-boot-tools)"; exit 2; }
command -v dtc >/dev/null     || { echo "dtc not found"; exit 2; }
command -v fdtget >/dev/null  || { echo "fdtget not found"; exit 2; }
[ -s "$KERNEL_IMAGE" ]    || {
    echo "kernel Image missing: $KERNEL_IMAGE"; exit 3; }
[ -s "$KERNEL_DTB" ]      || {
    echo "guest DTB missing: $KERNEL_DTB (run mk_dtb.sh)"; exit 4; }
[ -s "$INITRAMFS" ]       || {
    echo "initramfs missing: $INITRAMFS (run mk_initramfs.sh)"; exit 5; }
[ -s "$INITRAMFS_PLAIN" ] || {
    echo "plain initramfs missing: $INITRAMFS_PLAIN" \
         "(run mk_initramfs.sh)"; exit 5; }
[ -x "$SIGN_TOOL" ]       || {
    echo "sign tool missing/not built: $SIGN_TOOL" \
         "(make -C tools/keytools)"; exit 8; }
[ -f "$PRIVATE_KEY" ]     || {
    echo "signing key missing: $PRIVATE_KEY"; exit 9; }
[ -f "$HERE/linux.its" ]  || { echo "linux.its missing"; exit 11; }

mkdir -p "$BUILD"
WORK="$(mktemp -d /tmp/fit.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Compress the kernel. wolfBoot (GZIP=1) unpacks it to the FIT load
# address. All FITs use the same Image.gz.
gzip -9 -c "$KERNEL_IMAGE" > "$BUILD/Image.gz"

# build_fit <name> <version> <ramdisk-file> <out>: fill in linux.its,
# run mkimage, check the FIT, then sign it and check its size.
build_fit() {
    local name="$1" version="$2" ramdisk="$3" out="$4"
    local its="$WORK/${name}.its" fit="$WORK/${name}"

    echo "== $name (v$version, ramdisk $ramdisk)"
    sed -e "s|@BUILDDIR@|$BUILD|g" \
        -e "s|@RAMDISK@|$(basename "$ramdisk")|g" \
        "$HERE/linux.its" > "$its"
    grep -q "@BUILDDIR@\|@RAMDISK@" "$its" && {
        echo "placeholder left in $its"; exit 12; }

    # U-Boot FIT builder (dtc 1.7.2 supports /incbin/ here via mkimage).
    mkimage -f "$its" "$fit" >/dev/null
    [ -s "$fit" ] || { echo "mkimage failed for $name"; exit 6; }

    # --- verify the unsigned FIT before signing (dtc + fdtget) -----------
    dtc -I dtb -O dts "$fit" >/dev/null 2>&1 || {
        echo "dtc: FIT not parseable"; exit 13; }
    local got
    got="$(fdtget -t x "$fit" /images/kernel-1 load)" || {
        echo "no kernel load"; exit 13; }
    [ "$got" = "24000000" ] || {
        echo "kernel load wrong: $got (want 24000000)"; exit 13; }
    got="$(fdtget -t x "$fit" /images/kernel-1 entry)" || {
        echo "no kernel entry"; exit 13; }
    [ "$got" = "24000000" ] || {
        echo "kernel entry wrong: $got (want 24000000)"; exit 13; }
    got="$(fdtget -t s "$fit" /images/kernel-1 compression 2>/dev/null \
        || true)"
    [ "$got" = "gzip" ] || {
        echo "kernel compression wrong: '$got' (want gzip)"; exit 13; }
    got="$(fdtget -t x "$fit" /images/ramdisk-1 load)" || {
        echo "no ramdisk load"; exit 13; }
    [ "$got" = "30000000" ] || {
        echo "ramdisk load wrong: $got (want 30000000)"; exit 13; }
    got="$(fdtget -t s "$fit" /configurations default 2>/dev/null \
        || true)"
    [ "$got" = "conf-vek385" ] || {
        echo "default conf wrong: '$got'"; exit 13; }
    for ref in kernel fdt ramdisk; do
        got="$(fdtget -t s "$fit" /configurations/conf-vek385 $ref \
            2>/dev/null || true)"
        [ -n "$got" ] || {
            echo "configuration missing $ref reference"; exit 13; }
    done
    echo "   FIT verified: kernel load/entry 0x24000000 (gzip)," \
         "ramdisk load 0x30000000, conf-vek385"

    # --- sign the FIT with the wolfBoot key (ECC384/SHA384) --------------
    # The sign tool writes <name>_v<version>_signed.bin next to the input.
    ( cd "$WORK" && \
      IMAGE_HEADER_SIZE=512 \
      WOLFBOOT_PARTITION_SIZE=0x2C00000 \
      WOLFBOOT_SECTOR_SIZE=0x20000 \
      "$SIGN_TOOL" --ecc384 --sha384 "$name" "$PRIVATE_KEY" "$version" )
    [ -s "$WORK/${name}_v${version}_signed.bin" ] || {
        echo "signing failed for $name"; exit 10; }
    cp "$WORK/${name}_v${version}_signed.bin" "$out"

    # --- size check: the signed FIT must fit the 44 MB partition ---------
    local size
    size=$(stat -c %s "$out")
    if [ "$size" -ge "$PART_SIZE" ]; then
        echo "signed FIT too large: ${size} >= partition ${PART_SIZE}" \
             "(44 MB)"; exit 7;
    fi
    echo "   SIGNED: $out  ($(( size / MB )) MB)" \
         "[partition budget: $(( PART_SIZE / MB )) MB]"
}

# v2 first: the guest writes it to UPDATE, and the full initramfs holds it.
[ "$FIT_V2" = "1" ] && build_fit fit_v2 2 "$INITRAMFS_PLAIN" "$OUT_V2"
# v1 (full initramfs): test_linux.sh puts it in the BOOT partition.
[ "$FIT_V1" = "1" ] && build_fit fit_v1 1 "$INITRAMFS" "$OUT_V1"

# L5c: v1c before v2c. test_linux.sh builds the v2c initramfs (which
# holds v1c) between two runs of this script.
[ "$FIT_V1C" = "1" ] && \
    build_fit fit_v1c 1 "$INITRAMFS_PLAIN" "$OUT_V1C"
if [ "$FIT_V2C" = "1" ]; then
    [ -s "$INITRAMFS_V1C" ] || {
        echo "initramfs-extra.cpio.gz missing: $INITRAMFS_V1C" \
             "(run mk_initramfs.sh with EXTRA_FIT=$OUT_V1C first)"
        exit 14; }
    build_fit fit_v2c 2 "$INITRAMFS_V1C" "$OUT_V2C"
fi

if [ "$FIT_V2" != "1" ] || [ "$FIT_V1" != "1" ]; then
    out=""
    [ "$FIT_V1" = "1" ] && out="$OUT_V1"
    [ "$FIT_V2" = "1" ] && out="$out $OUT_V2" | sed 's/ $//'
    [ "$FIT_V1C" = "1" ] && out="$out $OUT_V1C"
    [ "$FIT_V2C" = "1" ] && out="$out $OUT_V2C"
    out="${out# }"
    echo "SIGNED FIT: $out (partial build: FIT_V1=$FIT_V1" \
         "FIT_V2=$FIT_V2 FIT_V1C=$FIT_V1C FIT_V2C=$FIT_V2C)"
    echo "FIT-OK"
    exit 0
fi

echo "SIGNED FITS: $OUT_V1 / $OUT_V2"
echo "  sign: ECC384/SHA384  header: 512 B  sector: 0x20000"
echo "  kernel:  $(( $(stat -c %s "$BUILD/Image.gz") / KB )) KB gz" \
     "-> load 0x24000000"
echo "  fdt:     $(( $(stat -c %s "$KERNEL_DTB") / KB )) KB"
echo "  ramdisk (v1/full):  $(( $(stat -c %s "$INITRAMFS") / KB )) KB gz" \
     "-> load 0x30000000"
echo "  ramdisk (v2/plain):" \
     "$(( $(stat -c %s "$INITRAMFS_PLAIN") / KB )) KB gz" \
     "-> load 0x30000000"
echo "FIT-OK"
