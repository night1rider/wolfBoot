#!/bin/bash
#
# test_qemu.sh - QEMU tests for wolfBoot TARGET=versal2 (VEK385,
# Cortex-A78AE).
#
# Runs these scenarios in QEMU's amd-versal2-virt machine (QEMU 11.1.3):
#   Q2   smoke boot        - signed v1 test-app boots and reaches the app.
#   Q4   flash check       - the real flash code (hal/wolfhal.c ext_flash
#                            code on the VEK385 wolfHAL drivers, STIG
#                            path) reads the
#                            flash ID (9Fh), erases a 128 KB test sector in
#                            the UPDATE partition (0xDC), programs a 4 KB
#                            pattern (0x12) and reads it back (0x13); the
#                            pattern is also checked in the backing flash
#                            file from the host. With RUN_Q4_DMA=1 the DMA
#                            variant also runs (CSU DMA reads, 1 KB and
#                            4 KB, via the versal2_dma hook).
#   Q5a  update            - a higher-version signed image (v2) is selected.
#   Q5b  refused update    - a corrupt v2 is refused; v1 boots.
#   Q5c  rollback          - an unconfirmed (TESTING) v2 rolls back to v1
#                            (ALLOW_DOWNGRADE=1 build).
#   Q5d  truncated update  - a truncated v2 is detected; v1 boots.
#   Q5e  power-cut         - QEMU boots v1, half of an update image is
#                            written into the UPDATE partition while QEMU
#                            runs, QEMU is SIGKILLed, and the same flash
#                            file is restarted: the partial update must be
#                            rejected and v1 must boot.
#   Q5f  no rollback       - unconfirmed (TESTING) v2 with the default
#                            (ALLOW_DOWNGRADE=0) build: v2 boots again and
#                            the UPDATE partition is kept.
#   Q5g/Q5h older update   - a validly signed lower v1 offered as the update
#                            while the higher v2 is the confirmed boot
#                            image: v2 boots and the v1 update is ignored,
#                            with both the ALLOW_DOWNGRADE=0 (Q5g) and =1
#                            (Q5h) builds.
#   Q5i/Q5j fallback       - the higher v2 in BOOT is corrupted and a valid
#                            lower v1 is in UPDATE: v1 boots via the
#                            version-independent fallback, with both the
#                            =0 (Q5i) and =1 (Q5j) builds.
#
# This is QEMU-only. It does not touch board hardware, eFUSEs, SLCR,
# voltages, or the ZynqMP RPU. It drives the OSPI NOR flash through the
# wolfBoot OSPI driver (STIG opcode allow-list + address guard + 128 KB
# sector erase).
#
# Prerequisites:
#   - QEMU 11.1.3 with the amd-versal2-virt machine.
#   - aarch64 cross compiler (aarch64-linux-gnu-gcc).
#   - wolfBoot, the trampoline, the Q4 test ELFs and the signed v1/v2
#     images, built by build_test_images.sh (next to this script).
#
# Usage:
#   QEMU=/opt/build/qemu-11.1.3/build/qemu-system-aarch64 ./test_qemu.sh
#
# TF-A mode: real TF-A BL31 -> wolfBoot on AMD's QEMU fork (Xilinx/qemu,
# xlnx_rel_v2026.1.1). The machine is `arm-generic-fdt` (the LMB DTB
# machine), the console is chardev "serial3" (the DTB's UART1,
# 0xF1930000; the DTB wires UARTs by chardev ID, not by -serial order),
# and the APU cores are released from CRF warm reset (the PLM does this
# on silicon):
#
#   ./test_qemu.sh --tfa <bl31.elf> --qemu <amd-qemu> --hw-dtb <dtb>
#
# In the AMD fork the CSU-DMA OSPI read path does not complete (the Q4
# DMA ELF never prints "Q4 DMA-1K READBACK"/"Q4-TEST-DONE"), so --tfa
# mode runs the suite with WOLFBOOT_OSPI_DMA=0 (STIG) wolfBoot builds and
# reports the Q4 DMA check as a model limitation. The default mode (no
# --tfa) runs the DMA checks.
#
# Build identity: each scenario runs the build it claims to run.
#   - Default mode checks, before the first DMA scenario, that
#     wolfboot.elf is the versal2_vek385.config build with the DMA read
#     path (versal2_dma present per nm, plus a .meta file next to the
#     ELF with the config sha256 and partition addresses). On a mismatch
#     it rebuilds the default (DMA) build.
#   - --tfa mode builds its STIG wolfBoot under OUTDIR and never
#     overwrites the repo's wolfboot.elf; its summary is labelled STIG.
#
set -uo pipefail

# --- configuration -------------------------------------------------------
QEMU="${QEMU:-/opt/build/qemu-11.1.3/build/qemu-system-aarch64}"
WOLFBOOT_DIR="${WOLFBOOT_DIR:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
CC="${CC:-aarch64-linux-gnu-gcc}"
STAGE="$(cd "$(dirname "$0")" && pwd)/stage"
Q4DIR="$(cd "$(dirname "$0")" && pwd)/q4"
OUTDIR="${OUTDIR:-$STAGE}"
TRAMP="$STAGE/tramp.elf"
WOLFBOOT_ELF="$WOLFBOOT_DIR/wolfboot.elf"
WOLFBOOT_DG_ELF="${WOLFBOOT_DG_ELF:-/tmp/wolfboot_downgrade.elf}"
Q4_STIG_ELF="$Q4DIR/flash_test.elf"
Q4_DMA_ELF="$Q4DIR/flash_test_dma.elf"
RUN_Q4_DMA="${RUN_Q4_DMA:-1}"
KEY="$WOLFBOOT_DIR/wolfboot_signing_private_key.der"
IMG_V1="${IMG_V1:-$OUTDIR/img_v1_signed.bin}"
IMG_V2="${IMG_V2:-$OUTDIR/img_v2_signed.bin}"
TIMEOUT="${TIMEOUT:-60}"
PASS=0
FAIL=0

# --- --tfa mode (real TF-A BL31, AMD QEMU fork) --------------------------
TFA_MODE=0
TFA_BL31=""
TFA_DTB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tfa)    TFA_MODE=1; TFA_BL31="${2:-}"; shift 2 ;;
    --qemu)   QEMU="${2:-}"; shift 2 ;;
    --hw-dtb) TFA_DTB="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$TFA_MODE" = "1" ]; then
  [ -n "$TFA_BL31" ] && [ -f "$TFA_BL31" ] || \
    { echo "--tfa: bl31.elf missing: $TFA_BL31"; exit 2; }
  [ -n "$TFA_DTB" ]  && [ -f "$TFA_DTB" ]  || \
    { echo "--hw-dtb: DTB missing: $TFA_DTB"; exit 2; }
fi

# OSPI flash layout. Must match config/examples/versal2_vek385.config.
BOOT_ADDR=0x1DC0000
UPD_ADDR=0x49C0000
FLASH_SIZE=$((256*1024*1024))
IMG_SIZE=0x2C00000
# Q4 test sector (must match q4/flash_test.c)
Q4_TSEC=$((UPD_ADDR + 0x200000))
Q4_PATLEN=4096
# Each partition ends with a state byte (END-5) and a 4-byte magic (END-4).
# See src/libwolfboot.c get_trailer_at and include/wolfboot/wolfboot.h:673.
BOOT_END=$((BOOT_ADDR + IMG_SIZE))        # 0x49C0000
UPD_END=$((UPD_ADDR + IMG_SIZE))          # 0x75C0000
TESTING_STATE=0x10
UPDATING_STATE=0x70
SUCCESS_STATE=0x00
# Length of the cut-off update image (Q5d, Q5e)
PART_LEN=0x28000

log() { echo "[test] $*"; }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }

run_qemu() {
  # run_qemu <flash> <wolfboot.elf> <logfile> [label]
  # With a label, --tfa mode also checks the TF-A log lines.
  # We use SIGKILL because the AMD QEMU fork ignores SIGTERM.
  local flash="$1" wb="$2" logf="$3" label="${4:-}"
  if [ "$TFA_MODE" = "1" ]; then
    # BL31 starts at EL3. wolfBoot loads at 0x40000000, where BL31 jumps.
    # The two 0x3cf writes take APU cores 0/1 out of reset (the PLM does
    # this on the board). The console UART1 is chardev "serial3".
    timeout -s KILL "$TIMEOUT" "$QEMU" \
      -M arm-generic-fdt -bios none -m 4G -dtb "$TFA_DTB" \
      -device loader,file="$TFA_BL31",cpu-num=0 \
      -device loader,file="$wb",addr=0x40000000 \
      -device loader,data=0x3cf,data-len=4,addr=0xec200300 \
      -device loader,data=0x3cf,data-len=4,addr=0xec200304 \
      -drive file="$flash",format=raw,if=mtd \
      -chardev file,id=serial3,path="$logf" \
      -chardev null,id=serial2 \
      -display none >/dev/null 2>&1
    [ -n "$label" ] && check_tfa_chain "$logf" "$label"
    return 0
  fi
  timeout -s KILL "$TIMEOUT" "$QEMU" \
    -M amd-versal2-virt,ospi-flash=mt35xu02gbba -m 4G \
    -drive if=mtd,file="$flash",format=raw \
    -device loader,file="$wb",cpu-num=0 \
    -device loader,file="$TRAMP",cpu-num=0 \
    -serial null -serial "file:$logf" \
    -display none >/dev/null 2>&1
  return 0
}

run_qemu_q4() {
  # run_qemu_q4 <flash> <q4-test.elf> <logfile>
  local flash="$1" elf="$2" logf="$3"
  if [ "$TFA_MODE" = "1" ]; then
    timeout -s KILL "$TIMEOUT" "$QEMU" \
      -M arm-generic-fdt -bios none -m 4G -dtb "$TFA_DTB" \
      -device loader,file="$elf",cpu-num=0 \
      -device loader,data=0x3cf,data-len=4,addr=0xec200300 \
      -device loader,data=0x3cf,data-len=4,addr=0xec200304 \
      -drive file="$flash",format=raw,if=mtd \
      -chardev file,id=serial3,path="$logf" \
      -chardev null,id=serial2 \
      -display none >/dev/null 2>&1
    return 0
  fi
  timeout -s KILL "$TIMEOUT" "$QEMU" \
    -M amd-versal2-virt,ospi-flash=mt35xu02gbba -m 4G \
    -drive if=mtd,file="$flash",format=raw \
    -device loader,file="$elf",cpu-num=0 \
    -serial null -serial "file:$logf" \
    -display none >/dev/null 2>&1
  return 0
}

run_qemu_bg() {
  # run_qemu_bg <flash> <wolfboot.elf> <logfile>: like run_qemu, but with
  # no timeout, for the Q5e power cut. `exec` makes $! the QEMU process
  # itself, so the caller's kill really stops QEMU.
  local flash="$1" wb="$2" logf="$3"
  if [ "$TFA_MODE" = "1" ]; then
    exec "$QEMU" \
      -M arm-generic-fdt -bios none -m 4G -dtb "$TFA_DTB" \
      -device loader,file="$TFA_BL31",cpu-num=0 \
      -device loader,file="$wb",addr=0x40000000 \
      -device loader,data=0x3cf,data-len=4,addr=0xec200300 \
      -device loader,data=0x3cf,data-len=4,addr=0xec200304 \
      -drive file="$flash",format=raw,if=mtd \
      -chardev file,id=serial3,path="$logf" \
      -chardev null,id=serial2 \
      -display none >/dev/null 2>&1
    return 0
  fi
  exec "$QEMU" \
    -M amd-versal2-virt,ospi-flash=mt35xu02gbba -m 4G \
    -drive if=mtd,file="$flash",format=raw \
    -device loader,file="$wb",cpu-num=0 \
    -device loader,file="$TRAMP",cpu-num=0 \
    -serial null -serial "file:$logf" \
    -display none >/dev/null 2>&1
  return 0
}

check_tfa_chain() {
  # check_tfa_chain <log> <label>: the log must show that BL31 ran and
  # handed off to 0x40000000 (--tfa mode only).
  if grep -q "BL31: Executing from" "$1" && \
     grep -q "BL31: Non secure code at 0x40000000" "$1"; then
    ok "$2: TF-A BL31 (EL3) ran and handed off at 0x40000000"
  else
    fail "$2: TF-A chain missing (log: $1)"
  fi
}

make_flash() {
  # make_flash <out> <boot_img> <upd_img|->  (use '-' for empty UPDATE)
  local out="$1" boot="$2" upd="$3"
  python3 - "$out" "$boot" "$upd" "$BOOT_ADDR" "$UPD_ADDR" <<'PY'
import sys
out, boot, upd, boot_addr, upd_addr = sys.argv[1:6]
size = 256*1024*1024
data = bytearray(b'\xff'*size)
def put(addr, blob):
    data[addr:addr+len(blob)] = blob
put(int(boot_addr, 0), open(boot,'rb').read())
if upd != '-':
    put(int(upd_addr, 0), open(upd,'rb').read())
open(out,'wb').write(data)
PY
}

set_trailer() {
  # set_trailer <flash> <boot|update> <state> [<boot|update> <state>]...
  # Writes the state byte and the magic at the end of each partition.
  local flash="$1" args=()
  shift
  while [ $# -ge 2 ]; do
    case "$1" in
      boot)   args+=("$BOOT_END" "$2") ;;
      update) args+=("$UPD_END" "$2") ;;
    esac
    shift 2
  done
  python3 - "$flash" "${args[@]}" <<'PY'
import sys
f, v = sys.argv[1], [int(x, 0) for x in sys.argv[2:]]
d = bytearray(open(f, 'rb').read())
for end, state in zip(v[0::2], v[1::2]):
    d[end - 5] = state
    d[end - 4:end] = bytes([0x42, 0x4F, 0x4F, 0x54])  # 0x544F4F42 LE
open(f, 'wb').write(d)
PY
}

corrupt_image() {
  # corrupt_image <src> <dst>: flip 64 bytes at 0x10000. The header and
  # version stay readable. <src> is not changed.
  python3 - "$1" "$2" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
for i in range(64):
    d[0x10000 + i] ^= 0xFF
open(sys.argv[2], 'wb').write(d)
PY
}

check_app() {
  # check_app <log> <expected_version> <label>
  local log="$1" ver="$2" label="$3"
  if grep -q "TESTAPP-VERSION: $ver" "$log" && \
     grep -q "Application running successfully" "$log"; then
    ok "$label: app v$ver reached and is running"
  else
    fail "$label: expected app v$ver running (log: $log)"
  fi
}

# --- prerequisites -------------------------------------------------------
[ -x "$QEMU" ]        || { log "QEMU not found: $QEMU (set QEMU=...)"; exit 2; }
"$QEMU" --version | head -1 | grep -q "11.1.3" || \
  log "WARNING: QEMU is not 11.1.3: $("$QEMU" --version 2>/dev/null | head -1)"
[ -f "$WOLFBOOT_ELF" ]|| { log "wolfboot.elf not built"; exit 2; }
[ -f "$TRAMP" ]       || { log "trampoline not built"; exit 2; }
[ -f "$IMG_V1" ]      || { log "v1 signed image missing"; exit 2; }
[ -f "$IMG_V2" ]      || { log "v2 signed image missing"; exit 2; }
mkdir -p "$OUTDIR"

# --- default-DMA build identity check (default mode) ---------------------
# Make sure wolfboot.elf is really the DMA build of versal2_vek385.config:
# it must have versal2_dma, and its .meta file must match the config.
# If not, rebuild it. If it still fails, stop the suite.
WB_CFG="$WOLFBOOT_DIR/config/examples/versal2_vek385.config"
wb_meta() {
  # wb_meta <config-file> -> "config_sha256 boot upd swap allow_downgrade"
  python3 - "$1" <<'PY'
import hashlib, sys, re
data = open(sys.argv[1], 'rb').read()
def val(name, default='unset'):
    m = re.search(r'(?m)^%s(\?|=)\s*(\S+)' % re.escape(name), data.decode())
    return m.group(2) if m else default
print(hashlib.sha256(data).hexdigest(),
      val('WOLFBOOT_PARTITION_BOOT_ADDRESS'),
      val('WOLFBOOT_PARTITION_UPDATE_ADDRESS'),
      val('WOLFBOOT_PARTITION_SWAP_ADDRESS'),
      val('ALLOW_DOWNGRADE'))
PY
}
# has_dma_read <elf>: returns 0 if the ELF has versal2_dma.
# Use grep -c, not -q: -q can stop early and kill nm with SIGPIPE, which
# breaks the result under pipefail.
has_dma_read() {
  aarch64-linux-gnu-nm "$1" 2>/dev/null |
    grep -cE "^[0-9a-f]+ [TtWwVvRrDdBb] versal2_dma$" |
    grep -q "^[1-9]"
}
# identity_probe <elf> <meta> <present|absent>: returns 0 if the build
# matches, else prints what is wrong. It does not count PASS/FAIL.
identity_probe() {
  local elf="$1" meta="$2" dma="$3" have=absent cur
  [ -f "$elf" ] || { echo "    $elf: missing"; return 1; }
  has_dma_read "$elf" && have=present
  if [ "$have" != "$dma" ]; then
    echo "    versal2_dma: expected $dma, found $have (nm $elf)"
    return 1
  fi
  cur="<no meta file>"
  [ -f "$elf.meta" ] && cur="$(cat "$elf.meta" 2>/dev/null)"
  if [ "$cur" != "$meta" ]; then
    echo "    meta: elf=$cur"
    echo "          now=$meta"
    return 1
  fi
  return 0
}
# build_wolfboot <dest.elf> [make args...]: build wolfBoot from
# versal2_vek385.config and copy the ELF to <dest.elf>. The repo's own
# wolfboot.elf is saved and put back, unless it is <dest.elf>.
build_wolfboot() {
  local dest="$1" repo="$WOLFBOOT_DIR/wolfboot.elf"
  local bak="$OUTDIR/wolfboot_repo.elf.bak" rc=0
  shift
  rm -f "$bak"
  [ "$dest" != "$repo" ] && [ -f "$repo" ] && cp "$repo" "$bak"
  ( cd "$WOLFBOOT_DIR" \
    && cp "$WB_CFG" .config \
    && make clean TARGET=versal2 >/dev/null 2>&1 \
    && make TARGET=versal2 "$@" >/dev/null 2>&1 \
    && { [ "$dest" = "$repo" ] || cp wolfboot.elf "$dest"; } ) || rc=1
  [ -f "$bak" ] && cp "$bak" "$repo"
  return $rc
}
# ALLOW_DOWNGRADE=1 build for Q5c/Q5h/Q5j. In --tfa mode it is a STIG
# build, because DMA reads do not finish on the AMD QEMU fork.
build_downgrade() {
  if [ "$TFA_MODE" = "1" ]; then
    build_wolfboot "$WOLFBOOT_DG_ELF" ALLOW_DOWNGRADE=1 WOLFBOOT_OSPI_DMA=0
  else
    build_wolfboot "$WOLFBOOT_DG_ELF" ALLOW_DOWNGRADE=1
  fi
}
if [ "$TFA_MODE" != "1" ]; then
  CUR_META="$(wb_meta "$WB_CFG")"
  if identity_probe "$WOLFBOOT_ELF" "$CUR_META" "present"; then
    ok "identity: wolfboot.elf has the DMA read path (versal2_dma, nm)"
    ok "identity: wolfboot.elf meta matches versal2_vek385.config"
  else
    log "identity: wolfboot.elf is NOT the verified default (DMA) build -"
    identity_probe "$WOLFBOOT_ELF" "$CUR_META" "present"
    log "rebuilding the default (DMA) wolfBoot from versal2_vek385.config"
    if build_wolfboot "$WOLFBOOT_ELF" \
       && echo "$CUR_META" > "$WOLFBOOT_ELF.meta"; then
      if identity_probe "$WOLFBOOT_ELF" "$CUR_META" "present"; then
        ok "identity: default (DMA) build rebuilt, identity re-verified"
      else
        fail "identity: rebuilt wolfboot.elf still fails the identity check"
        exit 1
      fi
    else
      fail "identity: default (DMA) rebuild failed - DMA checks NOT run"
      exit 1
    fi
  fi
fi

# --tfa mode: DMA reads do not finish on the AMD QEMU fork, so every
# scenario uses a STIG build (WOLFBOOT_OSPI_DMA=0) made under OUTDIR.
# The repo's wolfboot.elf is not changed.
if [ "$TFA_MODE" = "1" ]; then
  TFA_WB_ELF="$OUTDIR/wolfboot_tfa_stig.elf"
  log "TFA mode: building STIG wolfBoot (WOLFBOOT_OSPI_DMA=0) under OUTDIR"
  # The STIG build must not have versal2_dma.
  if build_wolfboot "$TFA_WB_ELF" WOLFBOOT_OSPI_DMA=0 \
     && ! has_dma_read "$TFA_WB_ELF"; then
    ok "TFA: STIG wolfBoot built (WOLFBOOT_OSPI_DMA=0)"
    # From here on, --tfa mode uses this ELF.
    WOLFBOOT_ELF="$TFA_WB_ELF"
  else
    fail "TFA: STIG wolfBoot build failed"
    exit 1
  fi
fi

# --- Q4 flash check -------------------------------------------------------
log "Q4 flash check (ID / 128 KB erase / pattern write / readback)"
make_flash "$OUTDIR/flash_q4.bin" "$IMG_V1" "-"
run_qemu_q4 "$OUTDIR/flash_q4.bin" "$Q4_STIG_ELF" "$OUTDIR/q4.log"
grep -q "Q4 ID: 2C 5B 1C OK" "$OUTDIR/q4.log" \
  && ok "Q4: flash ID 2C 5B 1C (MT35XU02G)" \
  || { fail "Q4: flash ID"; cat "$OUTDIR/q4.log"; }
grep -q "Q4 ERASE: OK" "$OUTDIR/q4.log" \
  && ok "Q4: 128 KB sector erase (0xDC)" \
  || fail "Q4: erase"
grep -q "Q4 ERASED-READ: OK" "$OUTDIR/q4.log" \
  && ok "Q4: erased region reads 0xFF" \
  || fail "Q4: erased read"
grep -q "Q4 PROGRAM: OK" "$OUTDIR/q4.log" \
  && ok "Q4: 4 KB pattern programmed (0x12)" \
  || fail "Q4: program"
grep -q "Q4 READBACK: OK" "$OUTDIR/q4.log" \
  && ok "Q4: 4 KB pattern read back (0x13)" \
  || fail "Q4: readback"
grep -q "Q4-TEST-DONE rc=0" "$OUTDIR/q4.log" \
  && ok "Q4: test finished rc=0" \
  || fail "Q4: done marker"
# Check the flash file on the host: the pattern must be there, and the
# rest of the 128 KB sector must be 0xFF.
if python3 - "$OUTDIR/flash_q4.bin" "$Q4_TSEC" "$Q4_PATLEN" <<'PY'
import sys
d = open(sys.argv[1],'rb').read()
base, n = int(sys.argv[2],0), int(sys.argv[3],0)
exp = bytearray((i*0x11)&0xFF if (i//256)==0 else (0xA5^i)&0xFF
                for i in range(n))
ok_pat = d[base:base+n] == bytes(exp)
ok_rest = all(b==0xFF for b in d[base+n:base+0x20000])
raise SystemExit(0 if (ok_pat and ok_rest) else 1)
PY
then
  ok "Q4: pattern verified in backing flash file (host side)"
else
  fail "Q4: pattern not found in backing flash file"
fi

if [ "$RUN_Q4_DMA" = "1" ]; then
  if [ "$TFA_MODE" = "1" ]; then
    # DMA reads do not finish on the AMD QEMU fork, so report a skip.
    # The STIG path was checked above. A skip is not a PASS or a FAIL.
    echo "  [SKIP-MODEL] Q4 DMA: AMD QEMU fork CSU-DMA OSPI read path" \
         "does not complete (no Q4 DMA-1K READBACK / Q4-TEST-DONE);" \
         "STIG path verified instead"
  else
    log "Q4 DMA check (CSU DMA reads via versal2_dma, WOLFBOOT_OSPI_DMA=1)"
    make_flash "$OUTDIR/flash_q4dma.bin" "$IMG_V1" "-"
    run_qemu_q4 "$OUTDIR/flash_q4dma.bin" "$Q4_DMA_ELF" "$OUTDIR/q4dma.log"
    grep -q "Q4 DMA-1K READBACK: OK" "$OUTDIR/q4dma.log" \
      && ok "Q4 DMA: 1 KB DMA read" \
      || { fail "Q4 DMA: 1 KB read"
           sed -n '/DMA-1K/,$p' "$OUTDIR/q4dma.log"; }
    grep -q "Q4 DMA-4K READBACK: OK" "$OUTDIR/q4dma.log" \
      && ok "Q4 DMA: 4 KB DMA read" || fail "Q4 DMA: 4 KB read"
  fi
fi

# --- Q2 smoke -------------------------------------------------------------
log "Q2 smoke boot (v1)"
make_flash "$OUTDIR/flash_q2.bin" "$IMG_V1" "-"
run_qemu "$OUTDIR/flash_q2.bin" "$WOLFBOOT_ELF" "$OUTDIR/q2.log" "Q2"
grep -q "Firmware Valid" "$OUTDIR/q2.log" \
  && ok "Q2: Firmware Valid" \
  || fail "Q2: Firmware Valid missing"
check_app "$OUTDIR/q2.log" 1 "Q2"

# --- Q5a update -----------------------------------------------------------
log "Q5a update (v1 -> v2, higher version wins)"
make_flash "$OUTDIR/flash_upd.bin" "$IMG_V1" "$IMG_V2"
run_qemu "$OUTDIR/flash_upd.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5a.log" "Q5a"
grep -q "Trying Update partition" "$OUTDIR/q5a.log" \
  && ok "Q5a: selected Update partition" \
  || fail "Q5a: Update partition not selected"
check_app "$OUTDIR/q5a.log" 2 "Q5a"

# --- Q5b refused update ---------------------------------------------------
log "Q5b refused update (corrupt v2)"
corrupt_image "$IMG_V2" "$OUTDIR/img_v2_corrupt.bin"
make_flash "$OUTDIR/flash_bad.bin" "$IMG_V1" "$OUTDIR/img_v2_corrupt.bin"
run_qemu "$OUTDIR/flash_bad.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5b.log" "Q5b"
grep -q "Checking integrity...FAILED" "$OUTDIR/q5b.log" \
  && ok "Q5b: integrity check FAILED (refused)" \
  || fail "Q5b: integrity did not fail"
check_app "$OUTDIR/q5b.log" 1 "Q5b (fell back to v1)"

# --- Q5c rollback ---------------------------------------------------------
log "Q5c rollback (unconfirmed v2 in TESTING -> v1)"
# Reuse the saved ALLOW_DOWNGRADE=1 ELF only if it matches this mode.
# A run in the other mode may have left a DMA or STIG build there.
Q5C_META_DG="$(wb_meta "$WB_CFG" | awk '{ $NF="=1"; print }')"
Q5C_DMA_EXPECT="present"
[ "$TFA_MODE" = "1" ] && Q5C_DMA_EXPECT="absent"
Q5C_DG_OK=1
identity_probe "$WOLFBOOT_DG_ELF" "$Q5C_META_DG" "$Q5C_DMA_EXPECT" \
  >/dev/null || Q5C_DG_OK=0
if [ "$Q5C_DG_OK" = "0" ]; then
  log "  cached ALLOW_DOWNGRADE=1 build missing or fails the identity" \
      "check - rebuilding"
  log "  building ALLOW_DOWNGRADE=1 wolfBoot (saving the normal build)"
  build_downgrade
fi
make_flash "$OUTDIR/flash_rb.bin" "$IMG_V1" "$IMG_V2"
# Mark UPDATE as TESTING (not confirmed), so wolfBoot rolls back.
set_trailer "$OUTDIR/flash_rb.bin" update "$TESTING_STATE"
run_qemu "$OUTDIR/flash_rb.bin" "$WOLFBOOT_DG_ELF" "$OUTDIR/q5c.log" "Q5c"
grep -q "Trying Boot partition" "$OUTDIR/q5c.log" \
  && ok "Q5c: fell back to Boot partition" \
  || fail "Q5c: Boot partition not selected"
check_app "$OUTDIR/q5c.log" 1 "Q5c (rolled back to v1)"
# Confirm the failed update was erased.
if python3 -c "
d=open('$OUTDIR/flash_rb.bin','rb').read()
sys_exit=0 if all(b==0xFF for b in d[0x49C0000:0x49C0100]) else 1
raise SystemExit(sys_exit)"; then
  ok "Q5c: UPDATE partition erased after rollback"
else
  fail "Q5c: UPDATE partition not erased after rollback"
fi

# --- Q5d truncated update (extra) ------------------------------------------
log "Q5d power-cut (truncated v2 -> recover to v1)"
head -c $((PART_LEN)) "$IMG_V2" > "$OUTDIR/img_v2_trunc.bin"
make_flash "$OUTDIR/flash_pc.bin" "$IMG_V1" "$OUTDIR/img_v2_trunc.bin"
run_qemu "$OUTDIR/flash_pc.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5d.log" "Q5d"
grep -q "Checking integrity...FAILED" "$OUTDIR/q5d.log" \
  && ok "Q5d: interrupted update detected" \
  || fail "Q5d: interrupted update not detected"
check_app "$OUTDIR/q5d.log" 1 "Q5d (recovered to v1)"

# --- Q5e real power-cut -----------------------------------------------------
# Boot v1, write part of v2 into UPDATE while QEMU runs, then kill QEMU.
# Restart from the same flash file: the partial update must be rejected.
log "Q5e real power-cut (kill QEMU mid-update, restart same flash)"
make_flash "$OUTDIR/flash_pc2.bin" "$IMG_V1" "-"
# Empty the log first, so an old log can't fool the wait loop below.
: > "$OUTDIR/q5e1.log"
run_qemu_bg "$OUTDIR/flash_pc2.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5e1.log" &
QEMU_PID=$!
# wait for the app to be up (up to 60 s)
up=0
for i in $(seq 1 60); do
  if grep -q "Application running successfully" "$OUTDIR/q5e1.log" \
       2>/dev/null; then
    up=1; break
  fi
  sleep 1
done
if [ "$up" -ne 1 ]; then
  fail "Q5e: v1 did not boot before the update write"
  kill -9 "$QEMU_PID" 2>/dev/null
  wait "$QEMU_PID" 2>/dev/null
else
  # The update write: put part of v2 into the UPDATE partition.
  dd if="$IMG_V2" of="$OUTDIR/flash_pc2.bin" bs=4096 \
     count=$((PART_LEN / 4096)) seek=$((UPD_ADDR / 4096)) \
     conv=notrunc status=none
  # QEMU is idle in the app. Cut the power now.
  sleep 1
  kill -9 "$QEMU_PID" 2>/dev/null
  wait "$QEMU_PID" 2>/dev/null
  ok "Q5e: power cut applied mid-update (QEMU SIGKILLed)"
  # restart from the SAME flash file
  run_qemu "$OUTDIR/flash_pc2.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5e2.log" \
    "Q5e restart"
  grep -q "Checking integrity...FAILED" "$OUTDIR/q5e2.log" \
    && ok "Q5e: partial update rejected on restart" \
    || fail "Q5e: partial update not rejected"
  check_app "$OUTDIR/q5e2.log" 1 "Q5e (recovered to v1 after power cut)"
fi

# --- ALLOW_DOWNGRADE scenario matrix (Q5f-Q5j) ---------------------------
# The same flash setups run with the ALLOW_DOWNGRADE=0 build ($WOLFBOOT_ELF)
# and the =1 build ($WOLFBOOT_DG_ELF). Expected results come from
# src/libwolfboot.c wolfBoot_dualboot_candidate and src/update_ram.c.

# Expected .meta for each build: same config, but the last field is the
# ALLOW_DOWNGRADE value (=0 from the config, or =1 from the make line).
META_DEFAULT="$(wb_meta "$WB_CFG")"
META_DG="$(echo "$META_DEFAULT" | awk '{ $NF="=1"; print }')"
# Default mode uses DMA builds; --tfa mode uses STIG builds.
DMA_EXPECT="present"
[ "$TFA_MODE" = "1" ] && DMA_EXPECT="absent"

# Make sure the default build has a .meta with ALLOW_DOWNGRADE=0 (--tfa
# mode has none yet). Stop if the ELF itself is the wrong build.
if ! identity_probe "$WOLFBOOT_ELF" "$META_DEFAULT" "$DMA_EXPECT"; then
  echo "$META_DEFAULT" > "$WOLFBOOT_ELF.meta"
  if identity_probe "$WOLFBOOT_ELF" "$META_DEFAULT" "$DMA_EXPECT"; then
    ok "identity: default (ALLOW_DOWNGRADE=0) build .meta recorded"
  else
    fail "identity: default build is not the ALLOW_DOWNGRADE=0 build" \
         "(versal2_dma nm mismatch) - Q5f-Q5j will NOT run"
    exit 1
  fi
fi
ok "identity: default build (ALLOW_DOWNGRADE=0) = $WOLFBOOT_ELF" \
   "(Q5f/Q5g/Q5i)"

# Make sure the ALLOW_DOWNGRADE=1 build has a matching .meta. Q5c does not
# write one, so rebuild here and write it. A matching .meta skips this.
if ! identity_probe "$WOLFBOOT_DG_ELF" "$META_DG" "$DMA_EXPECT"; then
  log "identity: ALLOW_DOWNGRADE=1 build missing .meta/mismatched -" \
      "(re)building + recording identity"
  build_downgrade
  echo "$META_DG" > "$WOLFBOOT_DG_ELF.meta"
  if identity_probe "$WOLFBOOT_DG_ELF" "$META_DG" "$DMA_EXPECT"; then
    ok "identity: ALLOW_DOWNGRADE=1 build verified (.meta) for Q5h/Q5j"
  else
    fail "identity: ALLOW_DOWNGRADE=1 build fails the identity check" \
         "after (re)build - Q5h/Q5j will NOT run"
    exit 1
  fi
fi
ok "identity: ALLOW_DOWNGRADE=1 build = $WOLFBOOT_DG_ELF (Q5h/Q5j)"

# --- Q5f =0: unconfirmed v2 in TESTING, default build -> no rollback -----
# Same flash as Q5c, but the ALLOW_DOWNGRADE=0 build. wolfBoot will not
# roll back to the lower v1 (src/libwolfboot.c), so v2 boots again and
# UPDATE is not erased.
log "Q5f (=0): unconfirmed v2 in TESTING, ALLOW_DOWNGRADE=0 ->" \
    "v2 boots again (no rollback)"
make_flash "$OUTDIR/flash_d1_0.bin" "$IMG_V1" "$IMG_V2"
set_trailer "$OUTDIR/flash_d1_0.bin" update "$TESTING_STATE"
run_qemu "$OUTDIR/flash_d1_0.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5f.log" "Q5f"
grep -q "Rollback to lower version not allowed" "$OUTDIR/q5f.log" \
  && ok "Q5f: rollback to the lower v1 refused" \
  || fail "Q5f: 'Rollback to lower version not allowed' missing" \
          "(see $OUTDIR/q5f.log)"
grep -q "Trying Update partition" "$OUTDIR/q5f.log" \
  && ok "Q5f: the TESTING v2 (Update partition) is selected again" \
  || fail "Q5f: Update partition not selected (see $OUTDIR/q5f.log)"
check_app "$OUTDIR/q5f.log" 2 "Q5f (v2 boots again, no rollback)"
# No rollback ran, so the UPDATE image must still be there.
if python3 - "$OUTDIR/flash_d1_0.bin" "$IMG_V2" <<'PY'
import sys
d = open(sys.argv[1],'rb').read()
v = open(sys.argv[2],'rb').read()[:0x1000]
sys.exit(0 if d[0x49C0000:0x49C1000] == v else 1)
PY
then
  ok "Q5f: UPDATE image intact (v2 still present, no rollback ran)"
else
  fail "Q5f: UPDATE image missing after the no-rollback boot"
fi

# --- Q5g/Q5h: older update offered (v2 BOOT SUCCESS, v1 UPDATE UPDATING) --
# A signed older v1 is offered as an update while v2 is confirmed in BOOT.
# wolfBoot only picks an update with a higher version (src/libwolfboot.c),
# so v2 boots with both builds and v1 is ignored.
log "Q5g/Q5h: older v1 offered as update" \
    "(v2 BOOT SUCCESS, v1 UPDATE UPDATING)"
make_flash "$OUTDIR/flash_d2.bin" "$IMG_V2" "$IMG_V1"
# BOOT = SUCCESS (v2 is confirmed). UPDATE = UPDATING (v1 was just written).
set_trailer "$OUTDIR/flash_d2.bin" boot "$SUCCESS_STATE" \
  update "$UPDATING_STATE"
run_qemu "$OUTDIR/flash_d2.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5g.log" "Q5g"
grep -q "Versions: Boot 2, Update 1" "$OUTDIR/q5g.log" \
  && ok "Q5g(=0): wolfBoot sees 'Versions: Boot 2, Update 1'" \
  || fail "Q5g(=0): 'Versions: Boot 2, Update 1' missing" \
          "(see $OUTDIR/q5g.log)"
grep -q "Trying Boot partition" "$OUTDIR/q5g.log" \
  && ok "Q5g(=0): the Boot partition (v2) is selected, not the older v1" \
  || fail "Q5g(=0): Boot partition not selected (see $OUTDIR/q5g.log)"
check_app "$OUTDIR/q5g.log" 2 "Q5g(=0) (v2 boots; older v1 update ignored)"
run_qemu "$OUTDIR/flash_d2.bin" "$WOLFBOOT_DG_ELF" "$OUTDIR/q5h.log" "Q5h"
grep -q "Versions: Boot 2, Update 1" "$OUTDIR/q5h.log" \
  && ok "Q5h(=1): wolfBoot sees 'Versions: Boot 2, Update 1'" \
  || fail "Q5h(=1): 'Versions: Boot 2, Update 1' missing" \
          "(see $OUTDIR/q5h.log)"
grep -q "Trying Boot partition" "$OUTDIR/q5h.log" \
  && ok "Q5h(=1): the Boot partition (v2) is selected with ALLOW_DOWNGRADE=1" \
  || fail "Q5h(=1): Boot partition not selected (see $OUTDIR/q5h.log)"
check_app "$OUTDIR/q5h.log" 2 "Q5h(=1) (v2 boots; older v1 update ignored)"

# --- Q5i/Q5j: fallback to an older image (v2 BOOT corrupted, v1 UPDATE) --
# BOOT has a broken v2 and UPDATE has a good v1. v2 fails the check, and
# the fallback (src/update_ram.c backup_on_failure) boots v1 with both
# builds, whatever the version.
log "Q5i/Q5j: corrupted v2 in BOOT, valid v1 in UPDATE ->" \
    "v1 boots via the fallback"
# Break the payload but keep the header, so wolfBoot still sees v2.
corrupt_image "$IMG_V2" "$OUTDIR/img_v2_badsig.bin"
make_flash "$OUTDIR/flash_d3.bin" "$OUTDIR/img_v2_badsig.bin" "$IMG_V1"
# BOOT = SUCCESS (the broken v2 was the active image).
set_trailer "$OUTDIR/flash_d3.bin" boot "$SUCCESS_STATE"
run_qemu "$OUTDIR/flash_d3.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5i.log" "Q5i"
grep -q "Checking integrity...FAILED" "$OUTDIR/q5i.log" \
  && ok "Q5i(=0): the corrupted v2 (Boot partition) fails verification" \
  || fail "Q5i(=0): the corrupted v2 was not refused (see $OUTDIR/q5i.log)"
grep -q "Active is now: 1" "$OUTDIR/q5i.log" \
  && ok "Q5i(=0): fallback switched to the Update partition" \
  || fail "Q5i(=0): no fallback to the Update partition (see $OUTDIR/q5i.log)"
check_app "$OUTDIR/q5i.log" 1 "Q5i(=0) (v1 boots via the fallback)"
run_qemu "$OUTDIR/flash_d3.bin" "$WOLFBOOT_DG_ELF" "$OUTDIR/q5j.log" "Q5j"
grep -q "Checking integrity...FAILED" "$OUTDIR/q5j.log" \
  && ok "Q5j(=1): the corrupted v2 (Boot partition) fails verification" \
  || fail "Q5j(=1): the corrupted v2 was not refused (see $OUTDIR/q5j.log)"
grep -q "Active is now: 1" "$OUTDIR/q5j.log" \
  && ok "Q5j(=1): fallback switched to the Update partition" \
  || fail "Q5j(=1): no fallback to the Update partition (see $OUTDIR/q5j.log)"
check_app "$OUTDIR/q5j.log" 1 \
  "Q5j(=1) (v1 boots via the fallback, ALLOW_DOWNGRADE=1)"

# --- STIG (WOLFBOOT_OSPI_DMA=0) fallback suite run -------------------------
# DMA is the default; STIG (WOLFBOOT_OSPI_DMA=0) is the backup read path.
# Build a STIG wolfBoot and re-run Q2 (reads BOOT) and Q5a (reads UPDATE)
# to prove STIG works in a real boot.
log "STIG suite run (WOLFBOOT_OSPI_DMA=0 fallback build)"
STIG_ELF="$OUTDIR/wolfboot_stig.elf"
STIG_PASS=0; STIG_FAIL=0
sok()   { echo "  [ OK ] (STIG) $1"; STIG_PASS=$((STIG_PASS+1)); }
sfail() { echo "  [FAIL] (STIG) $1"; STIG_FAIL=$((STIG_FAIL+1)); }
check_app_stig() {
  # check_app_stig <log> <expected_version> <label>  (STIG counters)
  if grep -q "TESTAPP-VERSION: $2" "$1" && \
     grep -q "Application running successfully" "$1"; then
    sok "$3: app v$2 reached and is running (STIG reads)"
  else
    sfail "$3: expected app v$2 running (STIG log: $1)"
  fi
}

# Build the STIG ELF on the side. The DMA wolfboot.elf stays in place.
if build_wolfboot "$STIG_ELF" WOLFBOOT_OSPI_DMA=0; then
  sok "STIG wolfBoot built (WOLFBOOT_OSPI_DMA=0)"
else
  sfail "STIG wolfBoot build (WOLFBOOT_OSPI_DMA=0) failed"
fi

# The STIG build must not have the DMA read code.
if command -v aarch64-linux-gnu-nm >/dev/null 2>&1; then
  if has_dma_read "$STIG_ELF"; then
    sfail "STIG build contains versal2_dma (DMA path not compiled out)"
  else
    sok "STIG build has no DMA read path (versal2_dma absent)"
  fi
fi

# STIG Q2 smoke (fresh flash; reads the BOOT partition over STIG)
make_flash "$OUTDIR/flash_stig_q2.bin" "$IMG_V1" "-"
run_qemu "$OUTDIR/flash_stig_q2.bin" "$STIG_ELF" "$OUTDIR/stig_q2.log"
grep -q "Firmware Valid" "$OUTDIR/stig_q2.log" \
  && sok "STIG Q2: Firmware Valid" \
  || sfail "STIG Q2: Firmware Valid missing"
check_app_stig "$OUTDIR/stig_q2.log" 1 "STIG Q2"

# STIG Q5a update (fresh flash; reads the UPDATE partition over STIG)
make_flash "$OUTDIR/flash_stig_upd.bin" "$IMG_V1" "$IMG_V2"
run_qemu "$OUTDIR/flash_stig_upd.bin" "$STIG_ELF" "$OUTDIR/stig_q5a.log"
grep -q "Trying Update partition" "$OUTDIR/stig_q5a.log" \
  && sok "STIG Q5a: selected Update partition" \
  || sfail "STIG Q5a: Update partition not selected"
check_app_stig "$OUTDIR/stig_q5a.log" 2 "STIG Q5a"

# --- summary --------------------------------------------------------------
echo "==========================================="
# Label the results with the build that ran: STIG in --tfa mode, DMA
# otherwise.
if [ "$TFA_MODE" = "1" ]; then
  echo " Q2/Q4/Q5 QEMU results (STIG, --tfa mode): PASS=$PASS FAIL=$FAIL"
else
  echo " Q2/Q4/Q5 QEMU results (default DMA): PASS=$PASS FAIL=$FAIL"
fi
echo " STIG fallback (WOLFBOOT_OSPI_DMA=0):  PASS=$STIG_PASS FAIL=$STIG_FAIL"
echo "==========================================="
if [ "$FAIL" -eq 0 ] && [ "$STIG_FAIL" -eq 0 ]; then
  log "ALL TESTS PASSED"; exit 0
else
  log "SOME TESTS FAILED"; exit 1
fi
