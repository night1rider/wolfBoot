#!/bin/bash
#
# test_qemu.sh - QEMU verification for wolfBoot TARGET=versal2 (VEK385 / Cortex-A78AE).
#
# Runs the acceptance scenarios in QEMU's amd-versal2-virt machine
# (run 2: QEMU 11.1.3, the first release with the machine upstream):
#   Q2   smoke boot        - signed v1 test-app boots and reaches the app.
#   Q4   flash check       - the real OSPI driver core (STIG path) reads the
#                            flash ID (9Fh), erases a 128 KB test sector in
#                            the UPDATE partition (0xDC), programs a 4 KB
#                            pattern (0x12) and reads it back (0x13); the
#                            pattern is additionally verified in the backing
#                            flash file from the host. With RUN_Q4_DMA=1 the
#                            DMA variant is also run (CSU DMA reads, 1 KB
#                            and 4 KB, via ospi_dma_read()).
#   Q5a  update            - a higher-version signed image (v2) is selected.
#   Q5b  refused update    - a corrupt v2 is refused; v1 boots.
#   Q5c  rollback          - an unconfirmed (TESTING) v2 rolls back to v1.
#   Q5d  truncated update  - a pre-truncated v2 (extra power-cut scenario)
#                            is detected; v1 boots.
#   Q5e  power-cut         - REAL power cut: QEMU boots v1, an update image
#                            is written into the UPDATE partition WHILE QEMU
#                            is running, QEMU is SIGKILLed mid-update, and
#                            the SAME flash file is restarted: the partial
#                            update must be rejected and v1 must boot.
#   Q5f  D1(=0) no-rollback - unconfirmed (TESTING) v2 with the DEFAULT
#                            (ALLOW_DOWNGRADE=0) build: v2 boots again, the
#                            UPDATE partition is kept (run 17; the
#                            ALLOW_DOWNGRADE=1 half of this scenario is Q5c).
#   Q5g/Q5h D2 older update - a validly signed LOWER v1 offered as the update
#                            while the higher v2 is the confirmed boot image:
#                            v2 boots and the v1 update is ignored, with BOTH
#                            the ALLOW_DOWNGRADE=0 (Q5g) and =1 (Q5h) builds
#                            (run 17).
#   Q5i/Q5j D3 fallback     - the higher v2 in BOOT is corrupted (fails
#                            verification) and a valid lower v1 is in UPDATE:
#                            v1 boots via the version-independent fallback,
#                            with BOTH the =0 (Q5i) and =1 (Q5j) builds
#                            (run 17).
#
# This is QEMU-only. It does not touch board hardware, eFUSEs, SLCR,
# voltages, or the ZynqMP RPU. It drives the OSPI NOR flash through the
# wolfBoot OSPI driver (STIG opcode allow-list + address guard + 128 KB
# sector erase).
#
# Prerequisites:
#   - QEMU 11.1.3 with the amd-versal2-virt machine (see BUILD.md, Run 2).
#   - aarch64 cross compiler (aarch64-linux-gnu-gcc).
#   - wolfBoot tree built for TARGET=versal2 (see BUILD.md).
#   - Q4 test ELFs: make -C tools/scripts/versal2/qemu/q4 && make -C ... dma
#
# Usage:
#   QEMU=/opt/build/qemu-11.1.3/build/qemu-system-aarch64 ./test_qemu.sh
#
# Run 15: real TF-A -> wolfBoot on AMD's QEMU fork (Xilinx/qemu,
# xlnx_rel_v2026.1.1). In this mode the machine is `arm-generic-fdt`
# (the LMB DTB machine), the console is the chardev "serial3" (the
# DTB's UART1, 0xF1930000 - the DTB wires UARTs by chardev ID, not by
# -serial order), and the APU cores are released from CRF warm reset
# (the PLM does this on silicon; see BUILD.md "Run 15"):
#
#   ./test_qemu.sh --tfa <bl31.elf> --qemu <amd-qemu> --hw-dtb <dtb>
#
# Model difference, stated (run 15 evidence, see BUILD.md "Run 15"): in
# this fork the CSU-DMA OSPI read path does not complete (the Q4 DMA ELF
# never prints "Q4 DMA-1K READBACK"/"Q4-TEST-DONE"), so --tfa mode runs
# the suite with the WOLFBOOT_OSPI_DMA=0 (STIG) wolfBoot builds. The Q4
# DMA check is reported as a documented model limitation there, not
# silently skipped; the upstream-QEMU flow (default, no --tfa) is
# unchanged and still runs the DMA checks.
#
# Run 16: the scripts test the build they claim to test.
#   - upstream mode verifies, before the first DMA-labelled scenario, that
#     the wolfboot.elf it runs is the versal2_vek385.config build WITH the
#     DMA read path (ospi_dma_read present via nm + a .meta file with the
#     config sha256 / partition addresses written next to it, the same
#     approach as test_linux.sh's stale-cache fix). A mismatch rebuilds
#     the default (DMA) build; the DMA-labelled checks are never run on a
#     STIG or otherwise mismatched ELF (run 15's --tfa suite left a STIG
#     build at the repo's wolfboot.elf and the next upstream run executed
#     it silently under a "(default DMA)" summary).
#   - --tfa mode builds its STIG wolfBoot under OUTDIR and never
#     overwrites the repo's wolfboot.elf, and its summary line is labelled
#     STIG, not "default DMA".
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

# --- run 15: --tfa mode (real TF-A BL31, AMD QEMU fork) ------------------
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
  [ -n "$TFA_BL31" ] && [ -f "$TFA_BL31" ] || { echo "--tfa: bl31.elf missing: $TFA_BL31"; exit 2; }
  [ -n "$TFA_DTB" ]  && [ -f "$TFA_DTB" ]  || { echo "--hw-dtb: DTB missing: $TFA_DTB"; exit 2; }
fi

# OSPI flash geometry (must match config/examples/versal2_vek385.config,
# run-13 layout: Bank A's first 8 MB are reserved for BOOT.BIN - run 13
# layout decision, AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt;
# the old run-3 4 MB reservation values are kept below for reference).
# Old (run 3-12), kept for reference:
#   BOOT_ADDR=0x19C0000
#   UPD_ADDR=0x4600000
BOOT_ADDR=0x1DC0000
UPD_ADDR=0x49C0000
FLASH_SIZE=$((256*1024*1024))
IMG_SIZE=0x2C00000
# Q4 test sector (must match q4/flash_test.c)
Q4_TSEC=$((UPD_ADDR + 0x200000))
Q4_PATLEN=4096
# UPDATE partition trailer: state byte then 4-byte magic at end of UPDATE.
UPD_END=$((UPD_ADDR + IMG_SIZE))          # 0x75C0000 (old: 0x7200000)
STATE_OFF=$((UPD_END - 5))                # state byte
MAGIC_OFF=$((UPD_END - 4))                # WOLFBOOT_MAGIC_TRAIL (0x544F4F42 LE)
TESTING_STATE=0x10

log() { echo "[test] $*"; }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }

run_qemu() {
  # run_qemu <flash> <wolfboot.elf> <logfile>
  # Run 15: all QEMU runs use `timeout -s KILL` (run 14: the AMD-fork
  # QEMU ignored SIGTERM; SIGKILL always ends it).
  local flash="$1" wb="$2" logf="$3"
  if [ "$TFA_MODE" = "1" ]; then
    # AMD QEMU fork: arm-generic-fdt (LMB DTB machine). BL31 is loaded
    # with -device loader cpu-num=0 (sets the EL3 PC to the BL31 entry;
    # the CPU starts in EL3 at reset, what RESET_TO_BL31 needs). The two
    # CRF writes (RST_APU0/RST_APU1 <- 0x3cf) release the APU warm reset
    # of cores 0/1 - on silicon the PLM firmware does this write; without
    # it the cores never execute (run 15 evidence, BUILD.md "Run 15").
    # wolfBoot is loaded at 0x40000000 (its entry; BL31 jumps there).
    # Console: the DTB wires the UARTs by chardev ID - UART1 (0xF1930000,
    # the console) is chardev "serial3"; -serial order does NOT apply.
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
  # run_qemu_bg <flash> <wolfboot.elf> <logfile> - same as run_qemu but
  # WITHOUT the timeout wrapper, for the Q5e power-cut scenario (the
  # caller starts it with & and SIGKILLs it mid-update).
  # `exec`: the caller's $! must be the QEMU process itself (killing the
  # subshell would orphan QEMU and the power cut would not happen).
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
  # check_tfa_chain <log> <label> (run 15, --tfa mode only): the boot log
  # must show the real TF-A chain: BL31 executed (its banner) and the
  # "Non secure code at 0x40000000" hand-off line, before wolfBoot.
  if grep -q "BL31: Executing from" "$1" && grep -q "BL31: Non secure code at 0x40000000" "$1"; then
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
# Old (run 3-12) literals (run 13 layout decision: 8 MB BOOT.BIN
# reservation, AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
#   put(0x19C0000, open(boot,'rb').read())
#   if upd != '-':
#       put(0x4600000, open(upd,'rb').read())
PY
}

check_app() {
  # check_app <log> <expected_version> <label>
  local log="$1" ver="$2" label="$3"
  if grep -q "TESTAPP-VERSION: $ver" "$log" && grep -q "Application running successfully" "$log"; then
    ok "$label: app v$ver reached and is running"
  else
    fail "$label: expected app v$ver running (log: $log)"
  fi
}

# --- prerequisites -------------------------------------------------------
[ -x "$QEMU" ]        || { log "QEMU not found at $QEMU (set QEMU=...)"; exit 2; }
"$QEMU" --version | head -1 | grep -q "11.1.3" || log "WARNING: QEMU is not 11.1.3: $("$QEMU" --version 2>/dev/null | head -1)"
[ -f "$WOLFBOOT_ELF" ]|| { log "wolfboot.elf not built (see BUILD.md)"; exit 2; }
[ -f "$TRAMP" ]       || { log "trampoline not built"; exit 2; }
[ -f "$IMG_V1" ]      || { log "v1 signed image missing"; exit 2; }
[ -f "$IMG_V2" ]      || { log "v2 signed image missing"; exit 2; }
mkdir -p "$OUTDIR"

# --- Run 16: default-DMA build identity check (upstream mode) -------------
# The scenarios from Q4 down are labelled "(default DMA)" and run
# $WOLFBOOT_ELF (the repo's wolfboot.elf in upstream mode). That label must
# be true: run 15's --tfa suite left a STIG (WOLFBOOT_OSPI_DMA=0) build at
# the repo's wolfboot.elf, and the next upstream run executed it silently
# under the "(default DMA): PASS=23" summary. Same class of bug as the
# test_linux.sh stale-cache incident (run 14/15), so the same fix shape:
# a .meta file next to the ELF (config sha256 + partition addresses +
# ALLOW_DOWNGRADE), written by this script at build time. Before the first
# DMA-labelled scenario, verify:
#   1. the ELF carries the CSU-DMA read path (a defined ospi_dma_read
#      symbol, aarch64-linux-gnu-nm);
#   2. the ELF's .meta matches the current
#      config/examples/versal2_vek385.config (a manual build without a
#      .meta has an unprovable identity -> treated as a mismatch).
# On a mismatch the default (DMA) build is rebuilt from the config (copied
# to .config first, as the CI job does) and re-verified; the suite exits
# (clear message) instead of running the DMA-labelled checks on a build
# that fails the identity check.
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
# identity_probe <elf> <meta> <present|absent>: 0 = identity holds; prints
# the failing part otherwise. Probing only - no counters (it runs again
# before the counted check, and after a rebuild).
# NOTE (run 16): the nm grep must NOT use `-q` (early exit): with
# `set -o pipefail`, a `grep -q` that exits on the first match can SIGPIPE
# the still-running nm (exit 141) and make a matching ELF look like a
# non-match (or, in the `!`-gated TFA build check, the opposite). `grep -c`
# drains nm's whole output first, so the pipeline is deterministic.
identity_probe() {
  local elf="$1" meta="$2" dma="$3" have=absent cur
  [ -f "$elf" ] || { echo "    $elf: missing"; return 1; }
  aarch64-linux-gnu-nm "$elf" 2>/dev/null | grep -cE "^[0-9a-f]+ [TtWwVv] ospi_dma_read" | grep -q "^[1-9]" && have=present
  if [ "$have" != "$dma" ]; then
    echo "    ospi_dma_read: expected $dma, found $have (nm $elf)"
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
if [ "$TFA_MODE" != "1" ]; then
  CUR_META="$(wb_meta "$WB_CFG")"
  if identity_probe "$WOLFBOOT_ELF" "$CUR_META" "present"; then
    ok "identity: wolfboot.elf has the DMA read path (ospi_dma_read present, nm)"
    ok "identity: wolfboot.elf config/partition meta matches versal2_vek385.config"
  else
    log "identity: wolfboot.elf is NOT the verified default (DMA) versal2 build -"
    identity_probe "$WOLFBOOT_ELF" "$CUR_META" "present"
    log "rebuilding the default (DMA) wolfBoot from versal2_vek385.config (cp to .config, make clean, make)"
    if ( cd "$WOLFBOOT_DIR" \
         && cp "$WB_CFG" .config \
         && make clean TARGET=versal2 >/dev/null 2>&1 \
         && make TARGET=versal2 >/dev/null 2>&1 \
         && echo "$CUR_META" > "$WOLFBOOT_ELF.meta" ); then
      if identity_probe "$WOLFBOOT_ELF" "$CUR_META" "present"; then
        ok "identity: default (DMA) build rebuilt from versal2_vek385.config, identity re-verified"
      else
        fail "identity: rebuilt wolfboot.elf still fails the default-DMA identity check"
        exit 1
      fi
    else
      fail "identity: default (DMA) rebuild failed - the DMA-labelled checks will NOT run on a mismatched build"
      exit 1
    fi
  fi
fi

# Run 15 (--tfa mode): the AMD fork's CSU-DMA OSPI read path does not
# complete (evidence: the Q4 DMA ELF never reaches "Q4 DMA-1K READBACK" /
# "Q4-TEST-DONE" there), so the whole suite runs the WOLFBOOT_OSPI_DMA=0
# (STIG) wolfBoot builds. Build the STIG wolfBoot up front and use it as
# the suite's wolfboot.elf for every scenario below. (Upstream mode, the
# default, is unchanged: the suite uses the default DMA build and the
# final STIG section re-runs the A/B boots with the STIG build.)
# Run 16: the STIG build is produced UNDER OUTDIR and used as the suite's
# ELF; the repo's wolfboot.elf is backed up around the (make clean) build
# and restored, so a --tfa run leaves the repo's build exactly as it found
# it (run 15 copied the STIG build over it, and the next upstream run
# picked it up silently - the identity check above now catches that class
# of bug in upstream mode).
if [ "$TFA_MODE" = "1" ]; then
  TFA_WB_ELF="$OUTDIR/wolfboot_tfa_stig.elf"
  TFA_BAK="$OUTDIR/wolfboot_normal.elf.tfa_bak"
  log "TFA mode: building STIG wolfBoot (WOLFBOOT_OSPI_DMA=0) under OUTDIR - model limitation, see header"
  [ -f "$WOLFBOOT_ELF" ] && cp "$WOLFBOOT_ELF" "$TFA_BAK"
  # the built ELF must not carry the DMA read path (ospi_dma_read defined);
  # otherwise the suite would not be running the STIG build it claims.
  # (grep -c, not -q: see the identity_probe note on the SIGPIPE race)
  if ( cd "$WOLFBOOT_DIR" \
       && cp config/examples/versal2_vek385.config .config \
       && make clean TARGET=versal2 >/dev/null 2>&1 \
       && make TARGET=versal2 WOLFBOOT_OSPI_DMA=0 >/dev/null 2>&1 \
       && cp wolfboot.elf "$TFA_WB_ELF" \
       && ! aarch64-linux-gnu-nm "$TFA_WB_ELF" 2>/dev/null | grep -cE "^[0-9a-f]+ [TtWwVv] ospi_dma_read" | grep -q "^[1-9]" ); then
    # restore the repo build (the suite runs the OUTDIR ELF)
    [ -f "$TFA_BAK" ] && cp "$TFA_BAK" "$WOLFBOOT_ELF"
    ok "TFA: STIG wolfBoot built (WOLFBOOT_OSPI_DMA=0)"
    # the suite's main ELF for TFA mode (never the repo's wolfboot.elf)
    WOLFBOOT_ELF="$TFA_WB_ELF"
  else
    [ -f "$TFA_BAK" ] && cp "$TFA_BAK" "$WOLFBOOT_ELF"
    fail "TFA: STIG wolfBoot build failed"
    exit 1
  fi
fi

# --- Q4 flash check -------------------------------------------------------
log "Q4 flash check (ID / 128 KB erase / pattern write / readback)"
make_flash "$OUTDIR/flash_q4.bin" "$IMG_V1" "-"
run_qemu_q4 "$OUTDIR/flash_q4.bin" "$Q4_STIG_ELF" "$OUTDIR/q4.log"
grep -q "Q4 ID: 2C 5B 1C OK"        "$OUTDIR/q4.log" && ok "Q4: flash ID 2C 5B 1C (MT35XU02G)" \
                                                       || { fail "Q4: flash ID"; cat "$OUTDIR/q4.log"; }
grep -q "Q4 ERASE: OK"              "$OUTDIR/q4.log" && ok "Q4: 128 KB sector erase (0xDC)" \
                                                       || fail "Q4: erase"
grep -q "Q4 ERASED-READ: OK"        "$OUTDIR/q4.log" && ok "Q4: erased region reads 0xFF" \
                                                       || fail "Q4: erased read"
grep -q "Q4 PROGRAM: OK"            "$OUTDIR/q4.log" && ok "Q4: 4 KB pattern programmed (0x12)" \
                                                       || fail "Q4: program"
grep -q "Q4 READBACK: OK"           "$OUTDIR/q4.log" && ok "Q4: 4 KB pattern read back (0x13)" \
                                                       || fail "Q4: readback"
grep -q "Q4-TEST-DONE rc=0"         "$OUTDIR/q4.log" && ok "Q4: test finished rc=0" \
                                                       || fail "Q4: done marker"
# Host-side: the pattern must be in the backing flash file, and the rest of
# the erased 128 KB sector must be 0xFF.
if python3 - "$OUTDIR/flash_q4.bin" "$Q4_TSEC" "$Q4_PATLEN" <<'PY'
import sys
d = open(sys.argv[1],'rb').read()
base, n = int(sys.argv[2],0), int(sys.argv[3],0)
exp = bytearray((i*0x11)&0xFF if (i//256)==0 else (0xA5^i)&0xFF for i in range(n))
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
    # Run 15 model limitation (documented, NOT silently skipped): the AMD
    # fork's CSU-DMA OSPI read path does not complete - the Q4 DMA ELF
    # (WOLFBOOT_OSPI_DMA=1) never prints "Q4 DMA-1K READBACK" or
    # "Q4-TEST-DONE" on that machine (run 15 evidence, BUILD.md "Run 15").
    # The STIG read path is fully verified above (Q4 ID/ERASE/PROGRAM/
    # READBACK + host-side pattern check), and the suite runs the STIG
    # wolfBoot builds. This marker counts as neither PASS nor FAIL.
    echo "  [SKIP-MODEL] Q4 DMA: AMD QEMU fork CSU-DMA OSPI read path does not complete (no Q4 DMA-1K READBACK / Q4-TEST-DONE); STIG path verified instead - run 15"
  else
    log "Q4 DMA check (CSU DMA reads via ospi_dma_read, WOLFBOOT_OSPI_DMA=1)"
    make_flash "$OUTDIR/flash_q4dma.bin" "$IMG_V1" "-"
    run_qemu_q4 "$OUTDIR/flash_q4dma.bin" "$Q4_DMA_ELF" "$OUTDIR/q4dma.log"
    grep -q "Q4 DMA-1K READBACK: OK" "$OUTDIR/q4dma.log" \
      && ok "Q4 DMA: 1 KB DMA read" || { fail "Q4 DMA: 1 KB read"; sed -n '/DMA-1K/,$p' "$OUTDIR/q4dma.log"; }
    grep -q "Q4 DMA-4K READBACK: OK" "$OUTDIR/q4dma.log" \
      && ok "Q4 DMA: 4 KB DMA read" || fail "Q4 DMA: 4 KB read"
  fi
fi

# --- Q2 smoke -------------------------------------------------------------
log "Q2 smoke boot (v1)"
make_flash "$OUTDIR/flash_q2.bin" "$IMG_V1" "-"
run_qemu "$OUTDIR/flash_q2.bin" "$WOLFBOOT_ELF" "$OUTDIR/q2.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q2.log" "Q2"; fi
grep -q "Firmware Valid" "$OUTDIR/q2.log" && ok "Q2: Firmware Valid" || fail "Q2: Firmware Valid missing"
check_app "$OUTDIR/q2.log" 1 "Q2"

# --- Q5a update -----------------------------------------------------------
log "Q5a update (v1 -> v2, higher version wins)"
make_flash "$OUTDIR/flash_upd.bin" "$IMG_V1" "$IMG_V2"
run_qemu "$OUTDIR/flash_upd.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5a.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5a.log" "Q5a"; fi
grep -q "Trying Update partition" "$OUTDIR/q5a.log" && ok "Q5a: selected Update partition" || fail "Q5a: Update partition not selected"
check_app "$OUTDIR/q5a.log" 2 "Q5a"

# --- Q5b refused update ---------------------------------------------------
log "Q5b refused update (corrupt v2)"
python3 - "$IMG_V2" "$OUTDIR/img_v2_corrupt.bin" <<'PY'
import sys,random
src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src,'rb').read())
random.seed(1)
for i in range(64):
    d[0x10000+i] ^= 0xFF
open(dst,'wb').write(d)
PY
make_flash "$OUTDIR/flash_bad.bin" "$IMG_V1" "$OUTDIR/img_v2_corrupt.bin"
run_qemu "$OUTDIR/flash_bad.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5b.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5b.log" "Q5b"; fi
grep -q "Checking integrity...FAILED" "$OUTDIR/q5b.log" && ok "Q5b: integrity check FAILED (refused)" || fail "Q5b: integrity did not fail"
check_app "$OUTDIR/q5b.log" 1 "Q5b (fell back to v1)"

# --- Q5c rollback ---------------------------------------------------------
log "Q5c rollback (unconfirmed v2 in TESTING -> v1)"
# Run 18 (fix): the build-if-missing must also verify the cached ELF's
# identity. A previous run in the OTHER mode leaves a config-correct
# /tmp/wolfboot_downgrade.elf with the wrong read path (upstream mode:
# the default DMA build; --tfa mode needs the STIG build because the
# fork's CSU-DMA read path does not complete - running the DMA build on
# the fork times out the image reads: "Versions: Boot 0, Update 0",
# 3 Q5c FAILs seen live in run 18 when the upstream suite had just run).
# The Q5f identity block re-checks/rebuilds if needed, but it runs after
# the Q5c boot, so the Q5c gate is identity-aware too: identity_probe
# (config/partition meta with ALLOW_DOWNGRADE=1 + the mode-expected
# ospi_dma_read nm state). The Q5c checks below are unchanged.
Q5C_META_DG="$(wb_meta "$WB_CFG" | awk '{ $NF="=1"; print }')"
Q5C_DMA_EXPECT="present"
[ "$TFA_MODE" = "1" ] && Q5C_DMA_EXPECT="absent"
Q5C_DG_OK=1
identity_probe "$WOLFBOOT_DG_ELF" "$Q5C_META_DG" "$Q5C_DMA_EXPECT" >/dev/null || Q5C_DG_OK=0
if [ "$Q5C_DG_OK" = "0" ]; then
  log "  cached ALLOW_DOWNGRADE=1 build missing or fails the identity check (mode-expected ospi_dma_read state + config meta) - rebuilding"
  log "  building ALLOW_DOWNGRADE=1 wolfBoot (saving the normal build)"
  cp "$WOLFBOOT_ELF" "$OUTDIR/wolfboot_normal.elf.bak"
  # Run 16 (TFA mode): the suite's ELF lives in OUTDIR, so the downgrade
  # build's make-clean would otherwise leave the downgrade build at the
  # repo's wolfboot.elf; save/restore the repo's ELF around the build too,
  # so a --tfa run leaves the repo exactly as it found it.
  if [ "$TFA_MODE" = "1" ] && [ "$WOLFBOOT_ELF" != "$WOLFBOOT_DIR/wolfboot.elf" ] && [ -f "$WOLFBOOT_DIR/wolfboot.elf" ]; then
    cp "$WOLFBOOT_DIR/wolfboot.elf" "$OUTDIR/wolfboot_repo.elf.q5c_bak"
  fi
  # TFA mode: the downgrade build is also STIG (same model limitation as
  # the main suite, run 15 - the fork's DMA read path does not complete).
  if [ "$TFA_MODE" = "1" ]; then
    ( cd "$WOLFBOOT_DIR" && make clean TARGET=versal2 >/dev/null 2>&1 \
      && make TARGET=versal2 ALLOW_DOWNGRADE=1 WOLFBOOT_OSPI_DMA=0 >/dev/null 2>&1 \
      && cp wolfboot.elf "$WOLFBOOT_DG_ELF" )
  else
    ( cd "$WOLFBOOT_DIR" && make clean TARGET=versal2 >/dev/null 2>&1 \
      && make TARGET=versal2 ALLOW_DOWNGRADE=1 >/dev/null 2>&1 \
      && cp wolfboot.elf "$WOLFBOOT_DG_ELF" )
  fi
  # restore the normal build so later scenarios use it
  cp "$OUTDIR/wolfboot_normal.elf.bak" "$WOLFBOOT_ELF"
  # Run 16 (TFA mode): restore the repo's ELF (see above)
  [ -f "$OUTDIR/wolfboot_repo.elf.q5c_bak" ] && cp "$OUTDIR/wolfboot_repo.elf.q5c_bak" "$WOLFBOOT_DIR/wolfboot.elf"
fi
make_flash "$OUTDIR/flash_rb.bin" "$IMG_V1" "$IMG_V2"
# Stamp the UPDATE trailer: state=TESTING + magic, so dualboot_candidate rolls back.
python3 - "$OUTDIR/flash_rb.bin" <<PY
data = bytearray(open("$OUTDIR/flash_rb.bin",'rb').read())
data[$STATE_OFF] = $TESTING_STATE
data[$MAGIC_OFF:$MAGIC_OFF+4] = bytes([0x42,0x4F,0x4F,0x54])  # 0x544F4F42 LE
open("$OUTDIR/flash_rb.bin",'wb').write(data)
PY
run_qemu "$OUTDIR/flash_rb.bin" "$WOLFBOOT_DG_ELF" "$OUTDIR/q5c.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5c.log" "Q5c"; fi
grep -q "Trying Boot partition" "$OUTDIR/q5c.log" && ok "Q5c: fell back to Boot partition" || fail "Q5c: Boot partition not selected"
check_app "$OUTDIR/q5c.log" 1 "Q5c (rolled back to v1)"
# Confirm the failed update was erased.
# Old (run 3-12) slice, kept for reference (run 13 layout decision: 8 MB
# BOOT.BIN reservation, AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
#   sys_exit=0 if all(b==0xFF for b in d[0x4600000:0x4600100]) else 1
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
python3 - "$IMG_V2" "$OUTDIR/img_v2_trunc.bin" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
open(dst,'wb').write(open(src,'rb').read()[:0x28000])
PY
make_flash "$OUTDIR/flash_pc.bin" "$IMG_V1" "$OUTDIR/img_v2_trunc.bin"
run_qemu "$OUTDIR/flash_pc.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5d.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5d.log" "Q5d"; fi
grep -q "Checking integrity...FAILED" "$OUTDIR/q5d.log" && ok "Q5d: interrupted update detected" || fail "Q5d: interrupted update not detected"
check_app "$OUTDIR/q5d.log" 1 "Q5d (recovered to v1)"

# --- Q5e real power-cut -----------------------------------------------------
# Start QEMU with v1 in BOOT and an EMPTY UPDATE partition. Wait for the app
# to boot, then write the first half of the v2 image into the UPDATE
# partition of the SAME backing file while QEMU is still running (the
# update write in progress), SIGKILL QEMU (the power cut), and restart from
# the same flash file. The partial update must be rejected and v1 must boot.
log "Q5e real power-cut (kill QEMU mid-update, restart same flash)"
make_flash "$OUTDIR/flash_pc2.bin" "$IMG_V1" "-"
# fresh log: the wait loop below must match THIS boot's output, not a
# stale q5e1.log left by a previous suite run in the same OUTDIR
# (run 15: a re-run in the same OUTDIR matched the old content and cut
# power before the guest had booted)
: > "$OUTDIR/q5e1.log"
run_qemu_bg "$OUTDIR/flash_pc2.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5e1.log" &
QEMU_PID=$!
# wait for the app to be up (up to 60 s)
up=0
for i in $(seq 1 60); do
  if grep -q "Application running successfully" "$OUTDIR/q5e1.log" 2>/dev/null; then
    up=1; break
  fi
  sleep 1
done
if [ "$up" -ne 1 ]; then
  fail "Q5e: v1 did not boot before the update write"
  kill -9 "$QEMU_PID" 2>/dev/null
  wait "$QEMU_PID" 2>/dev/null
else
  # update write in progress: first half of v2 into the UPDATE partition
  python3 - "$IMG_V2" "$OUTDIR/flash_pc2.bin" "$UPD_ADDR" <<'PY'
import sys
src, dst, off = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
data = bytearray(open(src,'rb').read())[:0x28000]
d = bytearray(open(dst,'rb').read())
d[off:off+len(data)] = data
open(dst,'wb').write(d)
PY
  # QEMU is running (idle in the app, not touching flash); cut power now
  sleep 1
  kill -9 "$QEMU_PID" 2>/dev/null
  wait "$QEMU_PID" 2>/dev/null
  ok "Q5e: power cut applied mid-update (QEMU SIGKILLed)"
  # restart from the SAME flash file
  run_qemu "$OUTDIR/flash_pc2.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5e2.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5e2.log" "Q5e restart"; fi
  grep -q "Checking integrity...FAILED" "$OUTDIR/q5e2.log" \
    && ok "Q5e: partial update rejected on restart" \
    || fail "Q5e: partial update not rejected"
  check_app "$OUTDIR/q5e2.log" 1 "Q5e (recovered to v1 after power cut)"
fi

# --- Run 17: D1/D2/D3 ALLOW_DOWNGRADE scenario matrix (additive) ------------
# Each scenario below runs with BOTH an ALLOW_DOWNGRADE=0 (default) build and
# an ALLOW_DOWNGRADE=1 build (same flash setup, only the build differs). The
# source-derived expectations (src/libwolfboot.c wolfBoot_dualboot_candidate
# 2543-2586, the #ifndef ALLOW_DOWNGRADE block 2573-2580; src/update_ram.c
# backup_on_failure fallback 425-449) are recorded in BUILD.md "Run 17":
#   Q5f  D1 =0  unconfirmed update (v1 BOOT, v2 UPDATE TESTING): the default
#            build refuses to roll back to the lower v1 ("Rollback to lower
#            version not allowed", libwolfboot.c:2578); v2 boots again,
#            TESTING kept, UPDATE intact. (The ALLOW_DOWNGRADE=1 half of D1
#            is Q5c above: rolls back to v1, UPDATE erased.)
#   Q5g  D2 =0  older update offered (v2 BOOT SUCCESS, valid lower v1 UPDATE
#            UPDATING): candidate selection `update_v > boot_v`
#            (libwolfboot.c:2562-2564) is not gated by ALLOW_DOWNGRADE, so the
#            lower v1 is never the candidate; v2 (BOOT) boots, v1 ignored.
#   Q5h  D2 =1  same flash as Q5g, ALLOW_DOWNGRADE=1 build: identical result
#            (v2 boots) - records that ALLOW_DOWNGRADE=1 does not make an
#            older signed "update" bootable.
#   Q5i  D3 =0  fallback to older (v2 BOOT corrupted, valid v1 UPDATE): the
#            higher-version v2 candidate is selected but fails verification;
#            the fallback (update_ram.c:425-449, version-independent) switches
#            to the UPDATE partition and v1 boots.
#   Q5j  D3 =1  same flash as Q5i, ALLOW_DOWNGRADE=1 build: identical result
#            (v1 boots via the same fallback path).
#
# Build identity: the default (ALLOW_DOWNGRADE=0) build is $WOLFBOOT_ELF
# (upstream: the repo's wolfboot.elf, verified by the upfront identity check;
# --tfa: the STIG build under OUTDIR). The ALLOW_DOWNGRADE=1 build is
# $WOLFBOOT_DG_ELF (built by Q5c above). Before booting, each scenario's ELF
# is verified via its .meta (config sha256 + partition addresses + the
# ALLOW_DOWNGRADE value) + the ospi_dma_read nm probe, so each scenario
# provably runs the build it claims. The default build is left in place after
# this section (it is never rebuilt here; the downgrade build is saved aside
# to $WOLFBOOT_DG_ELF and the repo's wolfboot.elf is saved/restored around
# any downgrade rebuild).

# BOOT partition trailer offsets (mirror the UPDATE ones above; the trailer
# is [state byte at END-5][4-byte magic at END-4], src/libwolfboot.c
# get_trailer_at). IMG_STATE values (include/wolfboot/wolfboot.h:673-686,
# non-inverted default): TESTING=0x10 (TESTING_STATE above), UPDATING=0x70,
# SUCCESS=0x00.
BOOT_END=$((BOOT_ADDR + IMG_SIZE))          # 0x49C0000
BOOT_STATE_OFF=$((BOOT_END - 5))
BOOT_MAGIC_OFF=$((BOOT_END - 4))
UPDATING_STATE=0x70
SUCCESS_STATE=0x00
MAGIC_LE="0x42,0x4F,0x4F,0x54"             # WOLFBOOT_MAGIC_TRAIL 0x544F4F42 LE

# The default (ALLOW_DOWNGRADE=0) build's meta: wb_meta's last field is the
# config file's ALLOW_DOWNGRADE value ("=0" for both versal2 configs).
# The ALLOW_DOWNGRADE=1 build's meta is the SAME config (same sha256 +
# partitions) with the last field recording the make-line override (=1).
META_DEFAULT="$(wb_meta "$WB_CFG")"
META_DG="$(echo "$META_DEFAULT" | awk '{ $NF="=1"; print }')"
# the ospi_dma_read flag expected in the current mode's builds (upstream mode
# runs the DMA default; --tfa mode runs the WOLFBOOT_OSPI_DMA=0 STIG builds)
DMA_EXPECT="present"
[ "$TFA_MODE" = "1" ] && DMA_EXPECT="absent"

# Ensure the default build's .meta records ALLOW_DOWNGRADE=0. Upstream mode
# already wrote it in the upfront identity check; --tfa mode built the STIG
# ELF under OUTDIR without a meta. If the ELF itself is not the default build
# (nm probe mismatch) the suite stops - the =0 scenarios never run on a
# mismatched build.
if ! identity_probe "$WOLFBOOT_ELF" "$META_DEFAULT" "$DMA_EXPECT"; then
  echo "$META_DEFAULT" > "$WOLFBOOT_ELF.meta"
  if identity_probe "$WOLFBOOT_ELF" "$META_DEFAULT" "$DMA_EXPECT"; then
    ok "identity: default (ALLOW_DOWNGRADE=0) build .meta recorded/verified for Q5f-Q5j"
  else
    fail "identity: default build is not the ALLOW_DOWNGRADE=0 build (ospi_dma_read nm mismatch) - Q5f-Q5j will NOT run"
    exit 1
  fi
fi
ok "identity: default build (ALLOW_DOWNGRADE=0) = $WOLFBOOT_ELF (Q5f/Q5g/Q5i)"

# Ensure the ALLOW_DOWNGRADE=1 build ($WOLFBOOT_DG_ELF, built by Q5c above)
# has its .meta recording ALLOW_DOWNGRADE=1. Q5c builds the ELF but does not
# write its .meta, so the meta is (re)recorded here: if the identity check
# fails the build is (re)built (Q5c pattern: repo wolfboot.elf saved and
# restored around the make) and the .meta written. A present, matching .meta
# reuses the ELF (no rebuild).
if ! identity_probe "$WOLFBOOT_DG_ELF" "$META_DG" "$DMA_EXPECT"; then
  log "identity: ALLOW_DOWNGRADE=1 build missing .meta/mismatched - (re)building + recording identity"
  [ -f "$WOLFBOOT_DIR/wolfboot.elf" ] && cp "$WOLFBOOT_DIR/wolfboot.elf" "$OUTDIR/wolfboot_repo.elf.dg_bak"
  if [ "$TFA_MODE" = "1" ]; then
    ( cd "$WOLFBOOT_DIR" && make clean TARGET=versal2 >/dev/null 2>&1 \
      && make TARGET=versal2 ALLOW_DOWNGRADE=1 WOLFBOOT_OSPI_DMA=0 >/dev/null 2>&1 \
      && cp wolfboot.elf "$WOLFBOOT_DG_ELF" )
  else
    ( cd "$WOLFBOOT_DIR" && make clean TARGET=versal2 >/dev/null 2>&1 \
      && make TARGET=versal2 ALLOW_DOWNGRADE=1 >/dev/null 2>&1 \
      && cp wolfboot.elf "$WOLFBOOT_DG_ELF" )
  fi
  echo "$META_DG" > "$WOLFBOOT_DG_ELF.meta"
  [ -f "$OUTDIR/wolfboot_repo.elf.dg_bak" ] && cp "$OUTDIR/wolfboot_repo.elf.dg_bak" "$WOLFBOOT_DIR/wolfboot.elf"
  if identity_probe "$WOLFBOOT_DG_ELF" "$META_DG" "$DMA_EXPECT"; then
    ok "identity: ALLOW_DOWNGRADE=1 build verified (.meta ALLOW_DOWNGRADE=1) for Q5h/Q5j"
  else
    fail "identity: ALLOW_DOWNGRADE=1 build fails the identity check after (re)build - Q5h/Q5j will NOT run"
    exit 1
  fi
fi
ok "identity: ALLOW_DOWNGRADE=1 build = $WOLFBOOT_DG_ELF (Q5h/Q5j)"

# --- Q5f D1 =0: unconfirmed v2 in TESTING, default build -> no rollback -----
# Same flash as Q5c (v1 BOOT, v2 UPDATE, UPDATE trailer TESTING) but the
# ALLOW_DOWNGRADE=0 build: the #ifndef ALLOW_DOWNGRADE guard
# (src/libwolfboot.c:2573-2580) sees fallback_v=1 < candidate_v=2, prints
# "Rollback to lower version not allowed" and keeps the TESTING v2 candidate
# (no erase, no switch). Expected: v2 boots again, TESTING kept, UPDATE intact.
log "Q5f D1(=0): unconfirmed v2 in TESTING, ALLOW_DOWNGRADE=0 -> v2 boots again (no rollback)"
make_flash "$OUTDIR/flash_d1_0.bin" "$IMG_V1" "$IMG_V2"
python3 - "$OUTDIR/flash_d1_0.bin" <<PY
data = bytearray(open("$OUTDIR/flash_d1_0.bin",'rb').read())
data[$STATE_OFF] = $TESTING_STATE
data[$MAGIC_OFF:$MAGIC_OFF+4] = bytes([$MAGIC_LE])
open("$OUTDIR/flash_d1_0.bin",'wb').write(data)
PY
run_qemu "$OUTDIR/flash_d1_0.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5f.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5f.log" "Q5f"; fi
grep -q "Rollback to lower version not allowed" "$OUTDIR/q5f.log" \
  && ok "Q5f: rollback to the lower v1 refused ('Rollback to lower version not allowed')" \
  || fail "Q5f: 'Rollback to lower version not allowed' missing (see $OUTDIR/q5f.log)"
grep -q "Trying Update partition" "$OUTDIR/q5f.log" \
  && ok "Q5f: the TESTING v2 (Update partition) is selected again" \
  || fail "Q5f: Update partition not selected (see $OUTDIR/q5f.log)"
check_app "$OUTDIR/q5f.log" 2 "Q5f (v2 boots again, no rollback)"
# The UPDATE image must be INTACT (no rollback ran, so no erase of UPDATE).
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

# --- Q5g/Q5h D2: older update offered (v2 BOOT SUCCESS, v1 UPDATE UPDATING) -
# A validly signed LOWER v1 is offered as the update while the higher v2 is
# the confirmed (SUCCESS) boot image. Candidate selection (src/libwolfboot.c:
# 2562-2564, `if (update_v > boot_v) candidate = PART_UPDATE`) never picks the
# lower v1; the candidate's (BOOT's) state is SUCCESS, not TESTING, so the
# ALLOW_DOWNGRADE branch is not reached either. Expected with BOTH settings:
# v2 (BOOT) boots, the v1 update is ignored and left untouched.
log "Q5g/Q5h D2: older v1 offered as update (v2 BOOT SUCCESS, v1 UPDATE UPDATING)"
make_flash "$OUTDIR/flash_d2.bin" "$IMG_V2" "$IMG_V1"
python3 - "$OUTDIR/flash_d2.bin" <<PY
data = bytearray(open("$OUTDIR/flash_d2.bin",'rb').read())
# BOOT trailer: state=SUCCESS + magic (the v2 is the confirmed boot image)
data[$BOOT_STATE_OFF] = $SUCCESS_STATE
data[$BOOT_MAGIC_OFF:$BOOT_MAGIC_OFF+4] = bytes([$MAGIC_LE])
# UPDATE trailer: state=UPDATING + magic (the v1 was just written as an update)
data[$STATE_OFF] = $UPDATING_STATE
data[$MAGIC_OFF:$MAGIC_OFF+4] = bytes([$MAGIC_LE])
open("$OUTDIR/flash_d2.bin",'wb').write(data)
PY
run_qemu "$OUTDIR/flash_d2.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5g.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5g.log" "Q5g"; fi
grep -q "Versions: Boot 2, Update 1" "$OUTDIR/q5g.log" \
  && ok "Q5g(=0): wolfBoot sees 'Versions: Boot 2, Update 1'" \
  || fail "Q5g(=0): 'Versions: Boot 2, Update 1' missing (see $OUTDIR/q5g.log)"
grep -q "Trying Boot partition" "$OUTDIR/q5g.log" \
  && ok "Q5g(=0): the Boot partition (v2) is selected; the older v1 update is not" \
  || fail "Q5g(=0): Boot partition not selected (see $OUTDIR/q5g.log)"
check_app "$OUTDIR/q5g.log" 2 "Q5g(=0) (v2 boots; older v1 update ignored)"
run_qemu "$OUTDIR/flash_d2.bin" "$WOLFBOOT_DG_ELF" "$OUTDIR/q5h.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5h.log" "Q5h"; fi
grep -q "Versions: Boot 2, Update 1" "$OUTDIR/q5h.log" \
  && ok "Q5h(=1): wolfBoot sees 'Versions: Boot 2, Update 1'" \
  || fail "Q5h(=1): 'Versions: Boot 2, Update 1' missing (see $OUTDIR/q5h.log)"
grep -q "Trying Boot partition" "$OUTDIR/q5h.log" \
  && ok "Q5h(=1): the Boot partition (v2) is selected even with ALLOW_DOWNGRADE=1" \
  || fail "Q5h(=1): Boot partition not selected (see $OUTDIR/q5h.log)"
check_app "$OUTDIR/q5h.log" 2 "Q5h(=1) (v2 boots; older v1 update ignored)"

# --- Q5i/Q5j D3: fallback to an older image (v2 BOOT corrupted, v1 UPDATE) --
# The higher-version v2 is in BOOT but its payload is corrupted (the header/
# version stay readable, so boot_v=2 and the candidate is the BOOT v2); a
# valid lower v1 is in UPDATE. The candidate (v2) fails verification and the
# fallback (src/update_ram.c:425-449, backup_on_failure - version-INdependent,
# not gated by ALLOW_DOWNGRADE) switches to the UPDATE partition, so v1 boots
# with BOTH settings. (The corrupted copy is written aside; IMG_V2 itself is
# not modified.)
log "Q5i/Q5j D3: corrupted v2 in BOOT, valid v1 in UPDATE -> v1 boots via the fallback"
python3 - "$IMG_V2" "$OUTDIR/img_v2_badsig.bin" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src,'rb').read())
for i in range(64):
    d[0x10000+i] ^= 0xFF   # corrupt the payload (header/version intact -> boot_v=2)
open(dst,'wb').write(d)
PY
make_flash "$OUTDIR/flash_d3.bin" "$OUTDIR/img_v2_badsig.bin" "$IMG_V1"
python3 - "$OUTDIR/flash_d3.bin" <<PY
data = bytearray(open("$OUTDIR/flash_d3.bin",'rb').read())
# BOOT trailer: state=SUCCESS + magic (the corrupted v2 was the active image)
data[$BOOT_STATE_OFF] = $SUCCESS_STATE
data[$BOOT_MAGIC_OFF:$BOOT_MAGIC_OFF+4] = bytes([$MAGIC_LE])
open("$OUTDIR/flash_d3.bin",'wb').write(data)
PY
run_qemu "$OUTDIR/flash_d3.bin" "$WOLFBOOT_ELF" "$OUTDIR/q5i.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5i.log" "Q5i"; fi
grep -q "Checking integrity...FAILED" "$OUTDIR/q5i.log" \
  && ok "Q5i(=0): the corrupted v2 (Boot partition) fails verification" \
  || fail "Q5i(=0): the corrupted v2 was not refused (see $OUTDIR/q5i.log)"
grep -q "Active is now: 1" "$OUTDIR/q5i.log" \
  && ok "Q5i(=0): fallback switched to the Update partition" \
  || fail "Q5i(=0): no fallback to the Update partition (see $OUTDIR/q5i.log)"
check_app "$OUTDIR/q5i.log" 1 "Q5i(=0) (v1 boots via the fallback to the older image)"
run_qemu "$OUTDIR/flash_d3.bin" "$WOLFBOOT_DG_ELF" "$OUTDIR/q5j.log"
if [ "$TFA_MODE" = "1" ]; then check_tfa_chain "$OUTDIR/q5j.log" "Q5j"; fi
grep -q "Checking integrity...FAILED" "$OUTDIR/q5j.log" \
  && ok "Q5j(=1): the corrupted v2 (Boot partition) fails verification" \
  || fail "Q5j(=1): the corrupted v2 was not refused (see $OUTDIR/q5j.log)"
grep -q "Active is now: 1" "$OUTDIR/q5j.log" \
  && ok "Q5j(=1): fallback switched to the Update partition" \
  || fail "Q5j(=1): no fallback to the Update partition (see $OUTDIR/q5j.log)"
check_app "$OUTDIR/q5j.log" 1 "Q5j(=1) (v1 boots via the fallback, ALLOW_DOWNGRADE=1)"

# --- STIG (WOLFBOOT_OSPI_DMA=0) fallback suite run -------------------------
# OSPI DMA is the config default (WOLFBOOT_OSPI_DMA=1). STIG remains the
# selectable fallback (WOLFBOOT_OSPI_DMA=0). Prove the fallback end-to-end:
# build a STIG wolfBoot (the DMA read path compiled out) and re-run the A/B
# boot scenarios that exercise wolfBoot's OWN OSPI read path (Q2 reads the
# BOOT partition, Q5a reads the UPDATE partition). The Q4 standalone ELFs
# above already verify the STIG and CSU-DMA register sequences in isolation;
# this run verifies the STIG path inside the real A/B boot flow. The build
# backup/restore follows the Q5c pattern so the repo's default (DMA)
# wolfboot.elf is left in place.
log "STIG suite run (WOLFBOOT_OSPI_DMA=0 fallback build)"
STIG_ELF="$OUTDIR/wolfboot_stig.elf"
STIG_PASS=0; STIG_FAIL=0
sok()   { echo "  [ OK ] (STIG) $1"; STIG_PASS=$((STIG_PASS+1)); }
sfail() { echo "  [FAIL] (STIG) $1"; STIG_FAIL=$((STIG_FAIL+1)); }
check_app_stig() {
  # check_app_stig <log> <expected_version> <label>  (STIG counters)
  if grep -q "TESTAPP-VERSION: $2" "$1" && grep -q "Application running successfully" "$1"; then
    sok "$3: app v$2 reached and is running (STIG reads)"
  else
    sfail "$3: expected app v$2 running (STIG log: $1)"
  fi
}

# Build the STIG variant aside (keep the default DMA build in place).
cp "$WOLFBOOT_DIR/wolfboot.elf" "$OUTDIR/wolfboot_main.elf.bak"
if ( cd "$WOLFBOOT_DIR" && make clean TARGET=versal2 >/dev/null 2>&1 \
     && make TARGET=versal2 WOLFBOOT_OSPI_DMA=0 >/dev/null 2>&1 \
     && cp wolfboot.elf "$STIG_ELF" ); then
  sok "STIG wolfBoot built (WOLFBOOT_OSPI_DMA=0)"
else
  sfail "STIG wolfBoot build (WOLFBOOT_OSPI_DMA=0) failed"
fi
cp "$OUTDIR/wolfboot_main.elf.bak" "$WOLFBOOT_DIR/wolfboot.elf"

# Sanity: the STIG build must NOT carry the DMA read path.
if command -v aarch64-linux-gnu-nm >/dev/null 2>&1; then
  if aarch64-linux-gnu-nm "$STIG_ELF" 2>/dev/null | grep -q "ospi_dma_read"; then
    sfail "STIG build contains ospi_dma_read (DMA path not compiled out)"
  else
    sok "STIG build has no DMA read path (ospi_dma_read absent)"
  fi
fi

# STIG Q2 smoke (fresh flash; reads the BOOT partition over STIG)
make_flash "$OUTDIR/flash_stig_q2.bin" "$IMG_V1" "-"
run_qemu "$OUTDIR/flash_stig_q2.bin" "$STIG_ELF" "$OUTDIR/stig_q2.log"
grep -q "Firmware Valid" "$OUTDIR/stig_q2.log" && sok "STIG Q2: Firmware Valid" \
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
# Run 16: the label must match the build the suite actually ran. In --tfa
# mode the suite ran the STIG builds (built under OUTDIR; the fork's DMA
# read path does not complete), so it is labelled STIG, not "default DMA"
# (run 15's --tfa summary printed "(default DMA): PASS=28" for the STIG
# suite - the same label bug as the stale ELF, run 16).
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
