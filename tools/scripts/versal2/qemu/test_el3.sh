#!/bin/bash
#
# test_el3.sh - QEMU tests for wolfBoot TARGET=versal2 at EL3
# (VERSAL2_EL3=1), on AMD's QEMU fork (Xilinx/qemu, arm-generic-fdt).
#
# QEMU starts the CPU at EL3 in wolfBoot. wolfBoot checks the signed FIT
# in BOOT, loads BL31 from its "atf" image and jumps to it; BL31 then
# starts the test-app (BL33) at EL2. Upstream versal2 TF-A takes no
# handoff data: it starts BL33 at its build-time PRELOADED_BL33_BASE, so
# the TF-A given here must be built with PRELOADED_BL33_BASE=$BL33.
#
# Scenarios:
#   E1  EL3 boot       - wolfBoot runs at EL3, loads BL31, BL31 starts the
#                        test-app at EL2.
#   E2  corrupt FIT    - one byte of the signed FIT is changed: wolfBoot
#                        refuses it and BL31 never runs.
#   E3  wrong BL33     - kernel-1 is not at VERSAL2_BL33_BASE: wolfBoot
#                        refuses the handoff and BL31 never runs.
#   E4  no BL31        - a FIT without "atf": wolfBoot stops (an image
#                        can't run at EL3 without BL31).
#
# Usage:
#   ./test_el3.sh --bl31 <bl31.elf> --qemu <amd-qemu> --hw-dtb <dtb>
#
# Needs: aarch64-linux-gnu- tools, mkimage (u-boot-tools), and the keys
# from a normal wolfBoot build (wolfboot_signing_private_key.der).
#
set -uo pipefail

QEMU_DIR="$(cd "$(dirname "$0")" && pwd)"
WOLFBOOT_DIR="${WOLFBOOT_DIR:-$(cd "$QEMU_DIR/../../../.." && pwd)}"
OUTDIR="${OUTDIR:-$QEMU_DIR/stage/el3}"
TIMEOUT="${TIMEOUT:-60}"
BL33="${BL33:-0x30000000}"
BOOT_ADDR=0x1DC0000
FLASH_SIZE=268435456
BL31=""; QEMU=""; DTB=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bl31)   BL31="${2:-}"; shift 2 ;;
    --qemu)   QEMU="${2:-}"; shift 2 ;;
    --hw-dtb) DTB="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done
for f in "$BL31" "$QEMU" "$DTB"; do
  [ -n "$f" ] && [ -f "$f" ] || { echo "missing input: '$f'"; exit 2; }
done
command -v mkimage >/dev/null || { echo "mkimage not found"; exit 2; }

PASS=0; FAIL=0
log() { echo "[test] $*"; }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }

# expect <log> <pattern> <label>: the log must contain the pattern.
expect() {
  if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (see $1)"; fi
}
# refuse <log> <pattern> <label>: the log must not contain the pattern.
refuse() {
  if grep -qF -- "$2" "$1"; then fail "$3 (see $1)"; else ok "$3"; fi
}

rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
cd "$WOLFBOOT_DIR"

# --- build: EL3 wolfBoot, test-app at BL33, BL31 binary ---------------------
# The repo's wolfboot.elf is saved and put back at the end.
[ -f wolfboot.elf ] && cp wolfboot.elf "$OUTDIR/wolfboot.elf.saved"
cp config/examples/versal2_vek385.config .config
make clean TARGET=versal2 >/dev/null 2>&1
# DMA reads don't finish on the AMD QEMU fork, so use STIG reads.
if make TARGET=versal2 VERSAL2_EL3=1 VERSAL2_BL33_BASE="$BL33" \
     WOLFBOOT_OSPI_DMA=0 > "$OUTDIR/build.log" 2>&1; then
  cp wolfboot.elf "$OUTDIR/wolfboot_el3.elf"
  ok "EL3 wolfBoot built (VERSAL2_EL3=1 VERSAL2_BL33_BASE=$BL33)"
else
  fail "EL3 wolfBoot build (see $OUTDIR/build.log)"; exit 1
fi

export IMAGE_HEADER_SIZE=512 WOLFBOOT_PARTITION_SIZE=0x2C00000 \
       WOLFBOOT_SECTOR_SIZE=0x20000
make -C test-app clean TARGET=versal2 >/dev/null 2>&1
if make -C test-app TARGET=versal2 WOLFBOOT_LOAD_ADDRESS="$BL33" \
     WOLFBOOT_VERSION=1 > "$OUTDIR/app.log" 2>&1; then
  cp test-app/image.bin "$OUTDIR/app.bin"
  ok "test-app built at $BL33"
else
  fail "test-app build (see $OUTDIR/app.log)"; exit 1
fi

aarch64-linux-gnu-objcopy -O binary "$BL31" "$OUTDIR/bl31.bin"
entry="$(aarch64-linux-gnu-readelf -h "$BL31" | awk '/Entry point/{print $4}')"
if [ "$entry" = "0x1600000" ]; then
  ok "BL31 entry 0x1600000"
else
  fail "BL31 entry is $entry, expected 0x1600000 (TF-A MEM_BASE)"
fi

# --- FIT images ---------------------------------------------------------
# make_fit <name> <bl33> [noatf]: fill el3.its, run mkimage, sign as v1.
make_fit() {
  local name="$1" bl33="$2" its="$OUTDIR/$1.its"
  sed -e "s|@BUILDDIR@|$OUTDIR|g" -e "s|@BL33@|$bl33|g" \
    "$QEMU_DIR/el3/el3.its" > "$its"
  if [ "${3:-}" = "noatf" ]; then
    # Drop the atf node and the loadables line.
    sed -i -e '/^\t\tatf {/,/^\t\t};/d' -e '/loadables/d' "$its"
  fi
  mkimage -f "$its" "$OUTDIR/$name.itb" >/dev/null || return 1
  tools/keytools/sign --ecc384 --sha384 "$OUTDIR/$name.itb" \
    wolfboot_signing_private_key.der 1 >/dev/null || return 1
  [ -s "$OUTDIR/${name}_v1_signed.bin" ]
}

# make_flash <signed> <flash>: erased 256 MB flash with <signed> in BOOT.
make_flash() {
  head -c "$FLASH_SIZE" /dev/zero | tr '\0' '\377' > "$2"
  dd if="$1" of="$2" bs=1M seek=$((BOOT_ADDR)) oflag=seek_bytes \
    conv=notrunc status=none
}

# run_el3 <flash> <log>: CPU 0 starts at EL3 in wolfBoot. The two 0x3cf
# writes take APU cores 0/1 out of reset (the PLM does this on the board).
# The subshell keeps bash's "Killed" note for the timeout out of the log.
run_el3() {
  ( timeout -s KILL "$TIMEOUT" "$QEMU" \
    -M arm-generic-fdt -bios none -m 4G -dtb "$DTB" \
    -device loader,file="$OUTDIR/wolfboot_el3.elf",cpu-num=0 \
    -device loader,data=0x3cf,data-len=4,addr=0xec200300 \
    -device loader,data=0x3cf,data-len=4,addr=0xec200304 \
    -drive file="$1",format=raw,if=mtd \
    -chardev file,id=serial3,path="$2" \
    -chardev null,id=serial2 \
    -display none >/dev/null 2>&1; true ) 2>/dev/null
  return 0
}

make_fit el3_good "$BL33" && ok "FIT el3_good built and signed" \
  || fail "FIT el3_good"
make_fit el3_wrong_bl33 "$(printf '0x%x' $((BL33 + 0x1000000)))" \
  && ok "FIT el3_wrong_bl33 built and signed" || fail "FIT el3_wrong_bl33"
make_fit el3_noatf "$BL33" noatf \
  && ok "FIT el3_noatf built and signed" || fail "FIT el3_noatf"

# --- E1: EL3 boot ---------------------------------------------------------
log "E1 EL3 boot: wolfBoot (EL3) -> BL31 -> test-app (EL2)"
make_flash "$OUTDIR/el3_good_v1_signed.bin" "$OUTDIR/e1.bin"
run_el3 "$OUTDIR/e1.bin" "$OUTDIR/e1.log"
expect "$OUTDIR/e1.log" "Current EL: 3" "E1: wolfBoot runs at EL3"
expect "$OUTDIR/e1.log" "Firmware Valid" "E1: signed FIT verified"
expect "$OUTDIR/e1.log" "FIT: BL31 (atf) loaded at 0x1600000" \
  "E1: BL31 loaded from the FIT"
expect "$OUTDIR/e1.log" "Handing off to BL31 at 0x1600000 (kernel $BL33)" \
  "E1: handoff to BL31"
expect "$OUTDIR/e1.log" "BL31: Non secure code at $BL33" \
  "E1: BL31 ran and starts BL33 at $BL33"
expect "$OUTDIR/e1.log" "wolfBoot Test Application" "E1: test-app reached"
expect "$OUTDIR/e1.log" "Current EL: 2" "E1: test-app runs at EL2"

# --- E2: corrupt FIT --------------------------------------------------------
log "E2 corrupt FIT: one byte changed, BL31 must not run"
cp "$OUTDIR/el3_good_v1_signed.bin" "$OUTDIR/e2_signed.bin"
size=$(stat -c %s "$OUTDIR/e2_signed.bin")
off=$((size - 64))
byte=$(od -An -tu1 -j "$off" -N1 "$OUTDIR/e2_signed.bin" | tr -d ' ')
printf "$(printf '\\%03o' $(( (byte + 1) % 256 )))" | \
  dd of="$OUTDIR/e2_signed.bin" bs=1 seek="$off" conv=notrunc status=none
make_flash "$OUTDIR/e2_signed.bin" "$OUTDIR/e2.bin"
run_el3 "$OUTDIR/e2.bin" "$OUTDIR/e2.log"
expect "$OUTDIR/e2.log" "Current EL: 3" "E2: wolfBoot runs at EL3"
refuse "$OUTDIR/e2.log" "Firmware Valid" "E2: corrupt FIT not accepted"
refuse "$OUTDIR/e2.log" "BL31:" "E2: BL31 never ran"

# --- E3: wrong BL33 ---------------------------------------------------------
log "E3 wrong BL33: kernel-1 not at $BL33, handoff refused"
make_flash "$OUTDIR/el3_wrong_bl33_v1_signed.bin" "$OUTDIR/e3.bin"
run_el3 "$OUTDIR/e3.bin" "$OUTDIR/e3.log"
expect "$OUTDIR/e3.log" "Firmware Valid" "E3: signed FIT verified"
expect "$OUTDIR/e3.log" "EL3: refused BL31" "E3: handoff refused"
refuse "$OUTDIR/e3.log" "BL31:" "E3: BL31 never ran"

# --- E4: no BL31 ------------------------------------------------------------
log "E4 no BL31: FIT without atf, wolfBoot stops"
make_flash "$OUTDIR/el3_noatf_v1_signed.bin" "$OUTDIR/e4.bin"
run_el3 "$OUTDIR/e4.bin" "$OUTDIR/e4.log"
expect "$OUTDIR/e4.log" "Firmware Valid" "E4: signed FIT verified"
expect "$OUTDIR/e4.log" "EL3: no BL31 (atf) in the boot image" \
  "E4: refused without BL31"
refuse "$OUTDIR/e4.log" "wolfBoot Test Application" \
  "E4: test-app not started at EL3"

# Put the repo's wolfboot.elf back.
[ -f "$OUTDIR/wolfboot.elf.saved" ] && \
  cp "$OUTDIR/wolfboot.elf.saved" wolfboot.elf

echo
echo "==========================================="
echo " EL3 QEMU results: PASS=$PASS FAIL=$FAIL"
echo "==========================================="
if [ "$FAIL" -eq 0 ]; then
  log "ALL EL3 TESTS PASSED"; exit 0
fi
log "SOME EL3 TESTS FAILED"; exit 1
