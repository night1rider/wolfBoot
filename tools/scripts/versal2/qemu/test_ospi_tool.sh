#!/bin/bash
#
# test_ospi_tool.sh - QEMU test of the board OSPI tool
# (tools/scripts/versal2/board/ospi_tool) for TARGET=versal2.
#
# Runs the same steps as the VEK385 board run, in QEMU 11.1.3's
# amd-versal2-virt machine (DMA reads):
#   T1  scan an erased flash: every region erased, DMA reads == STIG reads.
#   T2  write v1 to BOOT; read back OK; the host sees the same bytes and
#       the rest of the flash still erased.
#   T3  wolfBoot boots v1 from that flash.
#   T4  write v2 to UPDATE; wolfBoot boots v2 (higher version).
#   T5  write a corrupt v2 to UPDATE; wolfBoot refuses it and boots v1.
#   T6  no image at 0x30000000: the tool refuses and the flash is unchanged.
#
# Needs the outputs of build_test_images.sh (wolfboot.elf, trampoline,
# signed v1/v2). Each QEMU run stops as soon as its last line shows up.
#
#   QEMU=/path/to/qemu-system-aarch64 ./test_ospi_tool.sh
#
set -uo pipefail

# --- configuration -------------------------------------------------------
QEMU="${QEMU:-/opt/build/qemu-11.1.3/build/qemu-system-aarch64}"
WOLFBOOT_DIR="${WOLFBOOT_DIR:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
STAGE="$(cd "$(dirname "$0")" && pwd)/stage"
TOOLDIR="$WOLFBOOT_DIR/tools/scripts/versal2/board/ospi_tool"
OUTDIR="${OUTDIR:-$STAGE/ospi_tool}"
TRAMP="$STAGE/tramp.elf"
WOLFBOOT_ELF="$WOLFBOOT_DIR/wolfboot.elf"
IMG_V1="$STAGE/img_v1_signed.bin"
IMG_V2="$STAGE/img_v2_signed.bin"
TIMEOUT="${TIMEOUT:-300}"
PASS=0
FAIL=0

# OSPI flash layout. Must match config/examples/versal2_vek385.config.
BOOT_ADDR=0x1DC0000
UPD_ADDR=0x49C0000

log() { echo "[test] $*"; }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }

check() {
  # check <log> <regex> <label>
  if grep -aqE "$2" "$1"; then
    ok "$3"
  else
    fail "$3 (no '$2' in $1)"
  fi
}

run_until() {
  # run_until <log> <regex> <qemu args...>: start QEMU, stop it when the
  # log matches <regex> or after TIMEOUT seconds.
  local logf="$1" done_re="$2" pid t=0
  shift 2
  rm -f "$logf"
  "$QEMU" -M amd-versal2-virt,ospi-flash=mt35xu02gbba -m 4G \
    -serial null -serial "file:$logf" -display none "$@" \
    >/dev/null 2>&1 &
  pid=$!
  while [ "$t" -lt "$TIMEOUT" ]; do
    sleep 1
    t=$((t+1))
    if grep -aqE "$done_re" "$logf" 2>/dev/null; then
      break
    fi
  done
  sleep 1
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

run_tool() {
  # run_tool <flash> <tool.elf> <log> [image]: the image goes to 0x30000000
  local flash="$1" elf="$2" logf="$3" img="${4:-}" extra=()
  if [ -n "$img" ]; then
    extra=(-device "loader,file=$img,addr=0x30000000,force-raw=on")
  fi
  run_until "$logf" "OT-DONE rc=" -drive if=mtd,file="$flash",format=raw \
    -device loader,file="$elf",cpu-num=0 "${extra[@]}"
}

run_wolfboot() {
  # run_wolfboot <flash> <log>: wolfBoot + the EL3 -> EL2 trampoline
  run_until "$2" "Application running|PANIC|No valid image" \
    -drive if=mtd,file="$1",format=raw \
    -device loader,file="$WOLFBOOT_ELF",cpu-num=0 \
    -device loader,file="$TRAMP",cpu-num=0
}

erased_flash() {
  python3 -c "open('$1','wb').write(b'\xff'*0x10000000)"
}

# --- prerequisites -------------------------------------------------------
[ -x "$QEMU" ]         || { log "QEMU not found: $QEMU (set QEMU=...)"; exit 2; }
[ -f "$WOLFBOOT_ELF" ] || { log "wolfboot.elf not built"; exit 2; }
[ -f "$TRAMP" ]        || { log "trampoline not built"; exit 2; }
[ -f "$IMG_V1" ]       || { log "v1 signed image missing"; exit 2; }
[ -f "$IMG_V2" ]       || { log "v2 signed image missing"; exit 2; }
mkdir -p "$OUTDIR"

log "building the ospi_tool (DMA reads)"
make -C "$TOOLDIR" clean >/dev/null
if make -C "$TOOLDIR" all write >"$OUTDIR/build.log" 2>&1; then
  ok "ospi_tool built"
else
  fail "ospi_tool build (see $OUTDIR/build.log)"
  exit 1
fi
SCAN="$TOOLDIR/ospi_scan.elf"
WBOOT="$TOOLDIR/ospi_write_boot.elf"
WUPD="$TOOLDIR/ospi_write_update.elf"
FL="$OUTDIR/flash.bin"

# --- T1 scan --------------------------------------------------------------
log "T1 scan an erased flash"
erased_flash "$FL"
run_tool "$FL" "$SCAN" "$OUTDIR/t1.log"
check "$OUTDIR/t1.log" "OT-DONE rc=0" "T1: scan rc=0"
check "$OUTDIR/t1.log" "DMA-VS-STIG: OK" "T1: DMA read == STIG read"
for r in BOOT UPDATE DTS_BOOT DTS_UPDATE SWAP; do
  check "$OUTDIR/t1.log" "OT-SCAN $r .* erased=yes" "T1: $r erased"
done

# --- T2 write v1 ----------------------------------------------------------
log "T2 write v1 to BOOT"
run_tool "$FL" "$WBOOT" "$OUTDIR/t2.log" "$IMG_V1"
check "$OUTDIR/t2.log" "READBACK OK" "T2: v1 written and read back"
# The image must be at BOOT, and everything else still 0xFF.
if python3 - "$FL" "$IMG_V1" "$BOOT_ADDR" <<'PY'
import sys
fl = open(sys.argv[1], 'rb').read()
img = open(sys.argv[2], 'rb').read()
a = int(sys.argv[3], 0)
ok = fl[a:a + len(img)] == img
rest = fl[:a] + fl[a + len(img):]
ok = ok and rest.count(b'\xff') == len(rest)
sys.exit(0 if ok else 1)
PY
then
  ok "T2: host sees v1 at BOOT and nothing else changed"
else
  fail "T2: flash file does not match"
fi

# --- T3 boot v1 -----------------------------------------------------------
log "T3 wolfBoot boots v1"
run_wolfboot "$FL" "$OUTDIR/t3.log"
check "$OUTDIR/t3.log" "TESTAPP-VERSION: 1" "T3: test-app v1 started"
check "$OUTDIR/t3.log" "Application running successfully" "T3: app running"

# --- T4 write v2, boot v2 ------------------------------------------------
log "T4 write v2 to UPDATE, wolfBoot boots v2"
run_tool "$FL" "$WUPD" "$OUTDIR/t4.log" "$IMG_V2"
check "$OUTDIR/t4.log" "READBACK OK" "T4: v2 written and read back"
run_wolfboot "$FL" "$OUTDIR/t4b.log"
check "$OUTDIR/t4b.log" "TESTAPP-VERSION: 2" "T4: test-app v2 started"

# --- T5 corrupt v2 is refused -------------------------------------------
log "T5 write a corrupt v2 to UPDATE, wolfBoot boots v1"
python3 - "$IMG_V2" "$OUTDIR/img_v2_corrupt.bin" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
for i in range(64):
    d[0x10000 + i] ^= 0xFF
open(sys.argv[2], 'wb').write(d)
PY
run_tool "$FL" "$WUPD" "$OUTDIR/t5.log" "$OUTDIR/img_v2_corrupt.bin"
check "$OUTDIR/t5.log" "READBACK OK" "T5: corrupt v2 written"
run_wolfboot "$FL" "$OUTDIR/t5b.log"
check "$OUTDIR/t5b.log" "Checking integrity...FAILED" "T5: corrupt v2 refused"
check "$OUTDIR/t5b.log" "TESTAPP-VERSION: 1" "T5: fell back to v1"

# --- T6 no image ----------------------------------------------------------
log "T6 no image to write"
erased_flash "$OUTDIR/flash_neg.bin"
run_tool "$OUTDIR/flash_neg.bin" "$WBOOT" "$OUTDIR/t6.log"
check "$OUTDIR/t6.log" "no WOLF header" "T6: refused (no WOLF header)"
check "$OUTDIR/t6.log" "OT-DONE rc=1" "T6: rc=1"
if python3 - "$OUTDIR/flash_neg.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if d.count(b'\xff') == len(d) else 1)
PY
then
  ok "T6: flash unchanged"
else
  fail "T6: flash changed"
fi
rm -f "$FL" "$OUTDIR/flash_neg.bin"

echo "==========================================="
echo " ospi_tool QEMU results: PASS=$PASS FAIL=$FAIL"
echo "==========================================="
if [ "$FAIL" -eq 0 ]; then
  log "ALL TESTS PASSED"; exit 0
else
  log "SOME TESTS FAILED"; exit 1
fi
