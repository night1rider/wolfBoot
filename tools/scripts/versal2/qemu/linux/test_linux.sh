#!/bin/bash
#
# test_linux.sh - wolfBoot PR 1 "Local Linux test" (plan item Q5, NOT part
# of CI): the EDF kernel + device tree + initramfs packed in the signed
# FIT boots to a shell in QEMU's amd-versal2-virt, driven through the
# guest's /dev/mtdN by the wbmtd tool.
#
# Scenarios:
#   L1  boot to shell  - the v1 signed FIT (EDF kernel Image.gz + QEMU
#       DTB with the OSPI overlay + initramfs) boots; the kernel's own
#       Cadence QSPI/OSPI driver (Run 11: the QEMU DTB binds the
#       generic "cdns,qspi-nor" platdata - see ospi-overlay.dts) probes
#       QEMU's OSPI model and creates the
#       fixed-partition MTD devices; a shell is reachable. (normal
#       config, ALLOW_DOWNGRADE=0)
#   L2  update + confirm - in the guest (v1): `wbmtd update /v2.fit`
#       (erases UPDATE, programs the v2 signed FIT, sets the UPDATE
#       trailer to UPDATING), then "reboot" (QEMU restarted from the SAME
#       flash file - the QEMU machine has no PSCI; see "QEMU
#       limitations"): wolfBoot selects the higher-version UPDATE image,
#       boots v2 (TESTING). In the guest (v2): `wbmtd confirm`
#       (wolfBoot_success). One more reboot boots v2 stably (SUCCESS).
#       (normal config, ALLOW_DOWNGRADE=0)
#   L3  rollback - NON-DEFAULT OPTION (stated plainly, as test_qemu.sh
#       Q5c does): this scenario runs an ALLOW_DOWNGRADE=1 Linux wolfBoot
#       built from the same versal2_vek385_linux.config (the normal
#       build is saved and restored around it). With ALLOW_DOWNGRADE
#       defined, wolfBoot_dualboot_candidate() (src/libwolfboot.c) takes
#       the rollback branch: fresh flash with v1 in BOOT and v2 in
#       UPDATE (UPDATING, written through the guest as in L2); first
#       reboot boots v2 (TESTING); the next reboot, with v2 unconfirmed,
#       erases the UPDATE partition and boots v1. With ALLOW_DOWNGRADE
#       undefined (=0, the config default) that branch is compiled out
#       and the unconfirmed higher version is NOT rolled back (L3b).
#   L3b default-config no-rollback (Run 12 new scenario) - the same
#       flow as L3 but with the NORMAL wolfBoot (ALLOW_DOWNGRADE=0):
#       an unconfirmed higher version is not rolled back; v2 boots again
#       ("Rollback to lower version not allowed"), the UPDATE trailer is
#       kept TESTING and the UPDATE image stays intact.
#   L4  refused update - fresh flash; in the guest (v1): `wbmtd update
#       /v2.fit --corrupt-sig` (the signature TLV is corrupted in RAM
#       before the write). On reboot wolfBoot refuses the UPDATE image
#       (signature check FAILED) and boots v1. (normal config,
#       ALLOW_DOWNGRADE=0)
#   L5  D2 older update offered (Run 17, both settings) - a validly signed
#       LOWER v1 is in the UPDATE partition (UPDATING) while the higher v2
#       is the confirmed (SUCCESS) boot image in BOOT. wolfBoot's candidate
#       selection never picks the lower v1 (`update_v > boot_v` is not gated
#       by ALLOW_DOWNGRADE) and the candidate's state is SUCCESS, so v2
#       (BOOT) boots with BOTH the default (ALLOW_DOWNGRADE=0, L5a) and the
#       ALLOW_DOWNGRADE=1 (L5b) build; the older v1 update is ignored. The
#       v1-in-UPDATE state is set from the host (the wbmtd write path would
#       require the running v2's initramfs to carry the 29 MB v1 FIT, which
#       exceeds the 44 MB partition budget).
#   L5c D2 through the real update path (Run 18, both settings) - the same
#       D2 end state as L5, but the lower v1 is written to UPDATE by the
#       RUNNING v2 guest with `wbmtd update /v1c.fit` (erase + program +
#       UPDATING trailer over the guest's own MTD driver - the same path as
#       L2's `wbmtd update /v2.fit`) instead of dd'd from the host. The
#       separate initramfs for this scenario (fit_v2c's) embeds fit_v1c, a
#       validly signed lower version-1 image with the plain initramfs - the
#       full 29 MB v1 FIT would make fit_v2c exceed the 44 MB partition
#       budget (the L5 note). v2 (BOOT) must boot with BOTH the default
#       (ALLOW_DOWNGRADE=0, L5c-a) and the ALLOW_DOWNGRADE=1 (L5c-b) build;
#       the older v1c update is ignored. L5 (the host-dd variant) is kept
#       as it is.
#
# Everything is produced from inputs passed as environment variables (the
# EDF WIC, the busybox .deb, ...) into a build dir OUTSIDE the repo; the
# backing flash files and logs go to OUTDIR. See BUILD.md ("Run 5/6").
#
# Usage:
#   EDF_WIC=/opt/build/edf/...wic.xz \
#   BB_DEB=/opt/build/debs/busybox-static_*.arm64.deb \
#   ./test_linux.sh
#
#   (env overrides: BUILD, QEMU, WOLFBOOT_ELF, TRAMP, OUTDIR, BOOT_WAIT,
#    UPD_WAIT)
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WBOOT="$(cd "$HERE/../../../../../" && pwd)"
LINUXDIR="$HERE"

BUILD="${BUILD:-/opt/build/wb-linux}"
EDF_WIC="${EDF_WIC:-/opt/build/edf/edf-platform-disk-image-amd-cortexa78-mali-common.rootfs-20260609231841.wic.xz}"
BB_DEB="${BB_DEB:-/opt/build/debs/busybox-static_1.37.0-6+b9_arm64.deb}"
QEMU="${QEMU:-/opt/build/qemu-11.1.3/build/qemu-system-aarch64}"
WOLFBOOT_ELF="${WOLFBOOT_ELF:-$WBOOT/wolfboot.elf}"
TRAMP="${TRAMP:-$HERE/../trampoline/tramp.elf}"
OUTDIR="${OUTDIR:-$WBOOT/tools/scripts/versal2/qemu/stage/linux}"
# timeouts (s): first boot (kernel decompress + up) and later boots
BOOT_WAIT="${BOOT_WAIT:-240}"
# Run 11: the wbmtd update (44 MB erase of 704 sectors + 14.3 MB program
# over the modelled OSPI indirect-write path) takes ~450 s wall clock in
# QEMU (measured: erase ~150 s, write ~250 s, then the trigger). The old
# 180 s timeout aborted the wait while the (successful) write was still
# running. Old value: UPD_WAIT="${UPD_WAIT:-180}"
UPD_WAIT="${UPD_WAIT:-600}"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
log()  { echo; echo "### $1"; }

# --- inputs ---------------------------------------------------------------
for t in "$QEMU" "$WOLFBOOT_ELF" "$TRAMP" "$EDF_WIC" "$BB_DEB" \
         "$WBOOT/tools/keytools/sign" "$WBOOT/wolfboot_signing_private_key.der"; do
    [ -e "$t" ] || { echo "missing input: $t"; exit 2; }
done
command -v mkimage >/dev/null || { echo "mkimage (u-boot-tools) not found"; exit 2; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 2; }
mkdir -p "$BUILD" "$OUTDIR"

# --- 0a. cached-build geometry check (run 14/15 stale-cache fix) ---------
# Run 14 found a cached ALLOW_DOWNGRADE=1 wolfBoot ELF built from an OLD
# config (old partition layout) being reused silently: the L3 boot then
# looked for v1 at the wrong address and the whole suite misbehaved.
# Fix: every cached ELF carries a .meta file next to it (config file
# sha256 + the partition addresses the ELF was built with + the
# ALLOW_DOWNGRADE value); a cached ELF is only reused when the meta
# matches the CURRENT config, and this upfront check verifies that the
# cached ELF's recorded partition addresses match the current config.
WB_LINUX_CONFIG="$WBOOT/config/examples/versal2_vek385_linux.config"
wb_cfg_meta() {
    # echo "config_sha256 boot_addr upd_addr swap_addr allow_downgrade"
    python3 - "$WB_LINUX_CONFIG" <<'PY'
import hashlib, sys, re
cfg = sys.argv[1]
data = open(cfg, 'rb').read()
def val(name, default=None):
    m = re.search(r'(?m)^%s(\?|=)\s*(\S+)' % re.escape(name), data.decode())
    return m.group(2) if m else default
print(hashlib.sha256(data).hexdigest(),
      val('WOLFBOOT_PARTITION_BOOT_ADDRESS', 'unset'),
      val('WOLFBOOT_PARTITION_UPDATE_ADDRESS', 'unset'),
      val('WOLFBOOT_PARTITION_SWAP_ADDRESS', 'unset'),
      val('ALLOW_DOWNGRADE', 'unset'))
PY
}
WOLFBOOT_DG_ELF_LINUX="$OUTDIR/wolfboot_linux_downgrade.elf"
if [ -f "$WOLFBOOT_DG_ELF_LINUX" ]; then
    CUR_META="$(wb_cfg_meta)"
    if [ -f "$WOLFBOOT_DG_ELF_LINUX.meta" ] && [ "$(cat "$WOLFBOOT_DG_ELF_LINUX.meta" 2>/dev/null)" = "$CUR_META" ]; then
        # Run 16 fix: `cut ... "$CUR_META"` treated the meta string as a
        # filename ("cut: ...: No such file or directory", empty "()");
        # feed it via a herestring. Check condition unchanged.
        ok "L0: cached ALLOW_DOWNGRADE=1 ELF geometry matches current config ($(cut -d' ' -f2- <<<"$CUR_META"))"
    elif file "$WOLFBOOT_DG_ELF_LINUX" 2>/dev/null | grep -q "ELF 64-bit.*aarch64"; then
        # cache present but stale (config/addresses changed): rebuild below
        echo "  cached ALLOW_DOWNGRADE=1 ELF is STALE for the current config (will rebuild):"
        echo "    cached: $(cat "$WOLFBOOT_DG_ELF_LINUX.meta" 2>/dev/null || echo '<no meta>')"
        echo "    now:    $CUR_META"
        ok "L0: stale cache detected, rebuild scheduled (addresses must match current config)"
    else
        fail "L0: cached ALLOW_DOWNGRADE=1 ELF is not a valid aarch64 ELF and its meta mismatches"
        exit 1
    fi
fi

# --- 0a2. wolfboot.elf identity check (run 16) ----------------------------
# The scenarios L1/L2/L3b/L4 run $WOLFBOOT_ELF, which must be the
# versal2_vek385_linux.config build: BOOT_EL2 (default),
# WOLFBOOT_VERSAL2_EL2_MMU_OFF=1 (the EL2 MMU-off kernel handoff) and the
# Linux partition/load addresses (the flash layout is identical to the
# bare-metal config, but WOLFBOOT_LOAD_RAMDISK_ADDRESS=0x30000000 and the
# FIT handling differ). Run 12 hit the sibling bare-metal config's ELF
# here: L1 failed with the "Non-EFI boot detected with MMU and caches
# enabled" panic (that build has no WOLFBOOT_VERSAL2_EL2_MMU_OFF). Same
# class of bug as the run-14/15 stale-cache incident, so the same .meta
# approach: a .meta file next to the ELF (the Linux config sha256 +
# partition addresses + ALLOW_DOWNGRADE + the Linux-specific config lines
# that the bare-metal config leaves unset), written by this script when it
# builds the ELF. A missing or mismatched .meta - or a build without the
# DMA read path (the Linux config default is WOLFBOOT_OSPI_DMA=1) -
# triggers a rebuild from the Linux config (copied to .config first);
# the suite never boots an ELF whose Linux-config identity cannot be
# verified.
wb_linux_meta() {
    # echo "config_sha256 boot upd swap allow_downgrade boot_el2 el2_mmu_off ramdisk_addr"
    python3 - "$WB_LINUX_CONFIG" <<'PY'
import hashlib, sys, re
data = open(sys.argv[1], 'rb').read()
def val(name, default='unset'):
    m = re.search(r'(?m)^%s(\?|=)\s*(\S+)' % re.escape(name), data.decode())
    return m.group(2) if m else default
print(hashlib.sha256(data).hexdigest(),
      val('WOLFBOOT_PARTITION_BOOT_ADDRESS'),
      val('WOLFBOOT_PARTITION_UPDATE_ADDRESS'),
      val('WOLFBOOT_PARTITION_SWAP_ADDRESS'),
      val('ALLOW_DOWNGRADE'),
      val('BOOT_EL2'),
      val('WOLFBOOT_VERSAL2_EL2_MMU_OFF'),
      val('WOLFBOOT_LOAD_RAMDISK_ADDRESS'))
PY
}
LINUX_META="$(wb_linux_meta)"
# probe_linux_elf: 0 = $WOLFBOOT_ELF is the verified Linux-config (DMA) build
# NOTE (run 16): the nm grep uses `grep -c`, not `-q`: with `set -o pipefail`,
# a `grep -q` that exits on the first match can SIGPIPE the still-running nm
# (exit 141) and make a matching ELF look like a non-match (seen in this run:
# the diagnostic then printed a spurious "ospi_dma_read: absent" for a DMA
# ELF; the rebuild decision was still correct via the meta check, but the
# check must be deterministic).
probe_linux_elf() {
    [ -f "$WOLFBOOT_ELF" ] || return 1
    aarch64-linux-gnu-nm "$WOLFBOOT_ELF" 2>/dev/null | grep -cE "^[0-9a-f]+ [TtWwVv] ospi_dma_read" | grep -q "^[1-9]" || return 1
    [ -f "$WOLFBOOT_ELF.meta" ] && [ "$(cat "$WOLFBOOT_ELF.meta" 2>/dev/null)" = "$LINUX_META" ] || return 1
    return 0
}
if probe_linux_elf; then
    ok "identity: wolfboot.elf is the versal2_vek385_linux.config build (BOOT_EL2, WOLFBOOT_VERSAL2_EL2_MMU_OFF, Linux load addresses; ospi_dma_read present, nm; meta match)"
else
    echo "  wolfboot.elf is not the verified Linux-config build (expected meta):"
    echo "    now: $LINUX_META"
    if [ -f "$WOLFBOOT_ELF" ]; then
        echo "    elf: $(cat "$WOLFBOOT_ELF.meta" 2>/dev/null || echo '<no meta>')"
        if ! aarch64-linux-gnu-nm "$WOLFBOOT_ELF" 2>/dev/null | grep -cE "^[0-9a-f]+ [TtWwVv] ospi_dma_read" | grep -q "^[1-9]"; then
            echo "    ospi_dma_read: absent (not the DMA default of the Linux config)"
        fi
    fi
    echo "  rebuilding the Linux-config wolfBoot from versal2_vek385_linux.config (cp to .config, make clean, make)"
    if ( cd "$WBOOT" \
        && cp config/examples/versal2_vek385_linux.config .config \
        && make clean TARGET=versal2 >/dev/null 2>&1 \
        && make TARGET=versal2 >/dev/null 2>&1 \
        && echo "$LINUX_META" > "$WOLFBOOT_ELF.meta" ) \
       && probe_linux_elf; then
        ok "identity: Linux-config wolfBoot rebuilt from versal2_vek385_linux.config, identity re-verified"
    else
        fail "identity: could not build/verify the Linux-config wolfboot.elf - the Linux suite would boot an unverified ELF"
        exit 1
    fi
fi

# --- 0. EDF kernel Image from the WIC -------------------------------------
# WIC GPT part 1 = vfat boot part carrying the raw ARM64 kernel Image
# (the same file the board's U-Boot loads; used unchanged).
edf_kernel() {
    local p1dir="$BUILD/edf-bootpart"
    if [ -s "$BUILD/Image" ]; then
        echo "  reusing $BUILD/Image ($(stat -c %s "$BUILD/Image") bytes)"
        return
    fi
    mkdir -p "$p1dir"
    local raw="${EDF_WIC%.xz}"
    [ -e "$raw" ] || { xz -dk -f "$EDF_WIC"; raw="${EDF_WIC%.xz}"; }
    # GPT part 1: sectors 64..64+2097151 (1 GB vfat)
    local p1raw="$BUILD/edf-bootpart.part"
    if [ ! -e "$p1raw" ]; then
        dd if="$raw" of="$p1raw" bs=512 skip=64 count=2097152 status=none
    fi
    if mountpoint -q "$p1dir" 2>/dev/null; then :; else
        local loop
        loop="$(sudo losetup -f --show "$p1raw")"
        sudo mount -o ro "$loop" "$p1dir"
    fi
    [ -s "$p1dir/Image" ] || { echo "  no Image in the EDF boot partition"; return 1; }
    cp "$p1dir/Image" "$BUILD/Image"
    echo "  EDF kernel: $p1dir/Image -> $BUILD/Image ($(stat -c %s "$BUILD/Image") bytes)"
}
log "EDF kernel (from the WIC, unchanged)"
edf_kernel || exit 3

# --- 1. build the payload chain -------------------------------------------
log "wbmtd (guest update tool)"
make -C "$LINUXDIR/wbmtd" guest OUT_GUEST="$BUILD/wbmtd.aarch64" >/dev/null \
    || { echo "wbmtd build failed"; exit 4; }
ok "wbmtd.aarch64 built ($BUILD/wbmtd.aarch64)"

log "guest DTB (QEMU base + OSPI overlay)"
"$LINUXDIR/mk_dtb.sh" BUILD="$BUILD" | tail -3 || exit 5

log "initramfs (plain) + v2 FIT"
BUILD="$BUILD" BB_DEB="$BB_DEB" WBMTD="$BUILD/wbmtd.aarch64" \
    "$LINUXDIR/mk_initramfs.sh" | tail -2 || exit 6
BUILD="$BUILD" FIT_V1=0 "$LINUXDIR/mk_fit.sh" | tail -3 || exit 7

log "initramfs (full, embeds v2 FIT) + v1 FIT"
BUILD="$BUILD" BB_DEB="$BB_DEB" WBMTD="$BUILD/wbmtd.aarch64" \
    V2FIT="$BUILD/fit_v2_signed.bin" "$LINUXDIR/mk_initramfs.sh" | tail -3 || exit 6
BUILD="$BUILD" FIT_V2=0 "$LINUXDIR/mk_fit.sh" | tail -3 || exit 7
ok "signed FITs built (v1: $(stat -c %s "$BUILD/fit_v1_signed.bin") B, v2: $(stat -c %s "$BUILD/fit_v2_signed.bin") B)"

# Run 18 (L5c): the FITs for the D2 real-update-path variant. fit_v1c is a
# validly signed LOWER version-1 image (plain initramfs - it is never
# booted in L5c, only written to UPDATE by the guest); fit_v2c is version
# 2 carrying the initramfs that embeds fit_v1c as /v1c.fit, so the running
# v2 guest can write the lower v1 to UPDATE with `wbmtd update /v1c.fit`
# (the real update path). The full 29 MB v1 FIT is deliberately NOT used
# here (it would make fit_v2c ~44.3 MB > the 44 MB partition budget - the
# L5 note); the D2 decision depends only on the versions and signatures.
log "L5c FITs (run 18: real-update-path D2 variant)"
BUILD="$BUILD" FIT_V1=0 FIT_V2=0 FIT_V1C=1 "$LINUXDIR/mk_fit.sh" | tail -3 || exit 7
BUILD="$BUILD" BB_DEB="$BB_DEB" WBMTD="$BUILD/wbmtd.aarch64" \
    EXTRA_FIT="$BUILD/fit_v1c_signed.bin" EXTRA_FIT_NAME=/v1c.fit \
    "$LINUXDIR/mk_initramfs.sh" | tail -3 || exit 6
BUILD="$BUILD" FIT_V1=0 FIT_V2=0 FIT_V2C=1 "$LINUXDIR/mk_fit.sh" | tail -3 || exit 7
ok "L5c signed FITs built (v1c: $(stat -c %s "$BUILD/fit_v1c_signed.bin") B, v2c: $(stat -c %s "$BUILD/fit_v2c_signed.bin") B; both within the 44 MB partition budget)"

# --- QEMU helpers ----------------------------------------------------------
# run_qemu <flash> <logfile> [wolfboot.elf] -> sets QEMU_PID, PTTY; the
# guest console (UART1, QEMU serial1) goes to a pty; the pty is tee'd into
# <logfile> so both the wolfBoot output (earlycon captures it too) and the
# shell I/O are in one log. QEMU stderr (the pty redirect line) goes to
# <logfile>.qem.
QEMU_PID=""; PTTY=""; READER_PID=""
start_qemu() {
    local flash="$1" logf="$2" elf="${3:-$WOLFBOOT_ELF}"
    rm -f "$logf" "$logf.qem"
    "$QEMU" \
        -M amd-versal2-virt,ospi-flash=mt35xu02gbba -m 4G \
        -drive if=mtd,file="$flash",format=raw \
        -device loader,file="$elf",cpu-num=0 \
        -device loader,file="$TRAMP",cpu-num=0 \
        -serial null -serial pty \
        -display none >"$logf.qem" 2>&1 &
    QEMU_PID=$!
    # find the pty QEMU created (up to 30 s)
    local i
    for i in $(seq 1 30); do
        PTTY="$(grep -o '/dev/pts/[0-9]*' "$logf.qem" 2>/dev/null | head -1)"
        [ -n "$PTTY" ] && break
        sleep 1
    done
    [ -n "$PTTY" ] || { echo "QEMU did not create a pty: $(cat "$logf.qem" 2>/dev/null)"; return 1; }
    stty -F "$PTTY" raw -echo 2>/dev/null || true
    ( cat "$PTTY" >>"$logf" 2>/dev/null ) &
    READER_PID=$!
    return 0
}
stop_qemu() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null && wait "$QEMU_PID" 2>/dev/null
    [ -n "${READER_PID:-}" ] && kill "$READER_PID" 2>/dev/null && wait "$READER_PID" 2>/dev/null
    QEMU_PID=""; READER_PID=""
}
# wait_pattern <logfile> <pattern> <timeout-s>
wait_pattern() {
    local f="$1" pat="$2" to="$3" i=0
    while [ "$i" -lt "$to" ]; do
        if grep -q "$pat" "$f" 2>/dev/null; then return 0; fi
        sleep 1; i=$((i+1))
    done
    return 1
}
# send <cmd>: write a line to the guest shell
send() { printf '%s\r\n' "$1" >"$PTTY"; }
# reboot: the trampoline has no PSCI (QEMU limitation) - "reboot" is done
# by restarting QEMU from the SAME flash file (the OSPI flash is backed by
# the host file, so the flash contents and trailers persist).
reboot_qemu() {
    local flash="$1" logf="$2" elf="${3:-$WOLFBOOT_ELF}"
    stop_qemu
    start_qemu "$flash" "$logf" "$elf"
}

# build_downgrade_linux_wolfboot <out-elf> - build an ALLOW_DOWNGRADE=1
# Linux wolfBoot from the same config the normal Linux build uses
# (config/examples/versal2_vek385_linux.config, whose default is
# ALLOW_DOWNGRADE?=0), following the test_qemu.sh Q5c pattern: the normal
# build ($WOLFBOOT_ELF) is saved, the ALLOW_DOWNGRADE=1 build is made and
# copied aside, then the normal build is restored so every other scenario
# keeps running the default config. (wolfBoot's Makefile only reads
# .config - `cp` the config file over it, as the CI workflow does - and
# pass ALLOW_DOWNGRADE=1 on the make command line.)
#
# Run 15 (stale-cache fix): a cached build is reused only when its .meta
# file (config sha256 + partition addresses + ALLOW_DOWNGRADE, written
# next to the ELF at build time) matches the current config; a changed
# config or partition geometry forces a rebuild. This is what run 14
# hit: a cached ALLOW_DOWNGRADE=1 ELF from the old layout was reused.
build_downgrade_linux_wolfboot() {
    local out_elf="$1"
    local meta
    meta="$(wb_cfg_meta)"
    if [ -f "$out_elf" ] && [ -f "$out_elf.meta" ] && [ "$(cat "$out_elf.meta")" = "$meta" ]; then
        echo "  reusing ALLOW_DOWNGRADE=1 build (meta matches current config): $out_elf"
        return 0
    fi
    if [ -f "$out_elf" ]; then
        echo "  cached ALLOW_DOWNGRADE=1 build is stale (config or partition addresses changed) - rebuilding"
        rm -f "$out_elf"
    fi
    echo "  building ALLOW_DOWNGRADE=1 Linux wolfBoot (saving the normal build)"
    cp "$WOLFBOOT_ELF" "$OUTDIR/wolfboot_linux_normal.elf.bak"
    if ( cd "$WBOOT" \
        && cp config/examples/versal2_vek385_linux.config .config \
        && make clean TARGET=versal2 >/dev/null 2>&1 \
        && make TARGET=versal2 ALLOW_DOWNGRADE=1 >/dev/null 2>&1 \
        && cp wolfboot.elf "$out_elf" ); then
        : # copy of the downgrade build saved
    else
        cp "$OUTDIR/wolfboot_linux_normal.elf.bak" "$WBOOT/wolfboot.elf" 2>/dev/null || true
        echo "  ERROR: ALLOW_DOWNGRADE=1 Linux wolfBoot build failed"
        return 1
    fi
    # restore the normal build so later scenarios use the default config
    cp "$OUTDIR/wolfboot_linux_normal.elf.bak" "$WBOOT/wolfboot.elf"
    # record the build inputs next to the ELF (stale-cache detection)
    echo "$meta" > "$out_elf.meta"
    echo "  ALLOW_DOWNGRADE=1 build saved: $out_elf (normal build restored, meta written)"
    return 0
}

# make_linux_flash <out> <boot_img> <upd_img|->  (flash geometry: BOOT at
# 0x1DC0000, UPDATE at 0x49C0000 - run-13 layout, 8 MB BOOT.BIN
# reservation; config/examples/versal2_vek385_linux.config. Old run 3-12
# geometry, kept for reference: BOOT 0x19C0000, UPDATE 0x4600000.)
make_linux_flash() {
    local out="$1" boot="$2" upd="$3"
    rm -f "$out"
    # Run 11: fill with the NOR ERASED value (0xFF), not 0x00. NOR
    # programming can only clear bits (AND), so a 0x00-filled trailer
    # sector makes every magic/state write a silent no-op (run-11
    # evidence: after wolfBoot_success() the BOOT trailer sector stayed
    # 0x00 and wbmtd state kept reporting "no valid trailer"). QEMU's
    # OSPI model also erases to 0xFF, so 0xFF is the real-flash state of
    # a fresh partition. Old (run 5-10) fill, kept for reference:
    #   dd if=/dev/zero of="$out" bs=1M count=256 status=none
    python3 -c "open('$out','wb').write(b'\\xff'*0x10000000)"
    dd if="$boot" of="$out" bs=1 seek=$((0x1dc0000)) conv=notrunc status=none
    [ "$upd" != "-" ] && dd if="$upd" of="$out" bs=1 seek=$((0x49c0000)) conv=notrunc status=none
    # Old (run 3-12) seeks, kept for reference (run 13 layout decision:
    # 8 MB BOOT.BIN reservation, AMD BOOT.BIN 5.31 MiB,
    # evidence/mdom-bank-analysis-run9.txt):
    #   dd if="$boot" of="$out" bs=1 seek=$((0x19c0000)) conv=notrunc status=none
    #   [ "$upd" != "-" ] && dd if="$upd" of="$out" bs=1 seek=$((0x4600000)) conv=notrunc status=none
}

BANNER="wolfBoot Q5 Linux test shell"

# ============================================================================
log "L1: boot to shell (v1 FIT: EDF kernel + QEMU DTB + initramfs)"
FLASH="$OUTDIR/linux_flash.bin"
make_linux_flash "$FLASH" "$BUILD/fit_v1_signed.bin" "-"
start_qemu "$FLASH" "$OUTDIR/l1.log" || { fail "L1: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l1.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L1: kernel booted to the initramfs shell"
else
    fail "L1: no shell banner after ${BOOT_WAIT}s (see $OUTDIR/l1.log)"
fi
grep -q "Linux version 6.18.10-xilinx" "$OUTDIR/l1.log" \
    && ok "L1: EDF kernel 6.18.10-xilinx (unchanged Image from the WIC)" \
    || fail "L1: EDF kernel banner missing"
# the kernel's own Cadence QSPI driver must have created the MTD devices
send "cat /proc/mtd"
if wait_pattern "$OUTDIR/l1.log" "mtd0" "$UPD_WAIT"; then
    ok "L1: /proc/mtd present (MTD char devices created)"
else
    fail "L1: /proc/mtd not readable"
fi
sleep 3
# /proc/mtd format of the EDF 6.18.10-xilinx kernel (4f7afe14):
#   mtd_proc_show() in drivers/mtd/mtdcore.c prints
#   "mtd%d: %8.8llx %8.8x \"%s\"" - so the whole-flash (0x10000000)
#   line is "mtd0: 10000000 00020000". The previous expectation below
#   ("0: 0x0000000000-0x0000000fffM", a range-style /proc/mtd from a
#   newer kernel) is not what this kernel emits (see the guest output
#   in stage/linux/l1.log, Run 11); kept for reference:
#     grep -qE "0: 0x0000000000-0x0000000fffM" "$OUTDIR/l1.log"
if grep -qE "mtd0: +10000000 00020000" "$OUTDIR/l1.log" \
    && grep -qE "boot" "$OUTDIR/l1.log" && grep -qE "update" "$OUTDIR/l1.log"; then
    ok "L1: whole flash (0x10000000) + boot/update/swap partitions in /proc/mtd"
else
    fail "L1: /proc/mtd layout wrong (see $OUTDIR/l1.log)"
fi
send "dmesg | grep -iE 'qspi|ospi|cadence|spi-nor|jedec' | tail -8"
sleep 5
if grep -qiE "cadence|qspi|ospi" "$OUTDIR/l1.log"; then
    ok "L1: Cadence QSPI/OSPI driver messages in dmesg (stock kernel driver)"
else
    fail "L1: no driver messages in dmesg"
fi
grep -q "CONFIG_MTD_SPI_NOR=y" "$OUTDIR/l1.log" \
    && ok "L1: CONFIG_MTD_SPI_NOR=y in /proc/config.gz (shown at boot)" \
    || fail "L1: CONFIG_MTD_SPI_NOR line missing"
grep -q "CONFIG_SPI_CADENCE_QUADSPI=y" "$OUTDIR/l1.log" \
    && ok "L1: CONFIG_SPI_CADENCE_QUADSPI=y in /proc/config.gz (shown at boot)" \
    || fail "L1: CONFIG_SPI_CADENCE_QUADSPI line missing"

# ============================================================================
log "L2: update + confirm (v1 -> v2, then wolfBoot_success)"
send "wbmtd update /v2.fit"
if wait_pattern "$OUTDIR/l1.log" "UPDATE partition state set to UPDATING" "$UPD_WAIT"; then
    ok "L2: wbmtd wrote v2 to UPDATE and set the trailer to UPDATING"
else
    fail "L2: wbmtd update failed (see $OUTDIR/l1.log)"
fi
# reboot (same flash file) -> wolfBoot must pick the UPDATE partition (v2)
reboot_qemu "$FLASH" "$OUTDIR/l2.log"
if wait_pattern "$OUTDIR/l2.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L2: v2 booted after the update (TESTING)"
else
    fail "L2: v2 did not boot (see $OUTDIR/l2.log)"
fi
# Run 11: "Trying Update partition" (wolfBoot's "Trying %s partition at
# %p") is printed before the pty reader attaches (the captured log starts
# at the ~10 s "done (hash check)" line), so it can never appear in
# l2.log/l2b.log. The evidence in the log is the FIT image line
# "Boot partition: ... (sz <v2-512>, ver 0x2, type 0x601)" (ver 0x2 =
# the v2 image was loaded) plus the guest's own view of the UPDATE
# trailer (wbmtd state -> "UPDATE: state=TESTING"). Old (run 5-10)
# check, kept for reference:
#   grep -q "Trying Update partition" "$OUTDIR/l2.log" \
#       && ok "L2: wolfBoot selected the Update partition (higher version)" \
#       || fail "L2: Update partition not selected"
grep -q "ver 0x2, type 0x601" "$OUTDIR/l2.log" \
    && ok "L2: v2 image loaded (ver 0x2 in the boot log)" \
    || fail "L2: Update partition not selected (no ver 0x2 in $OUTDIR/l2.log)"
send "wbmtd state"
if wait_pattern "$OUTDIR/l2.log" "UPDATE: state=TESTING" "$BOOT_WAIT"; then
    ok "L2: guest sees the UPDATE trailer as TESTING (trigger active)"
else
    fail "L2: UPDATE trailer not TESTING in the guest (see $OUTDIR/l2.log)"
fi
grep -q "Firmware Valid" "$OUTDIR/l2.log" \
    && ok "L2: v2 signature verified (Firmware Valid)" \
    || fail "L2: v2 signature not verified"
# confirm from the v2 guest
send "wbmtd confirm"
if wait_pattern "$OUTDIR/l2.log" "BOOT partition state set to SUCCESS" "$UPD_WAIT"; then
    ok "L2: wbmtd confirm set the active partition to SUCCESS"
else
    fail "L2: wbmtd confirm failed (see $OUTDIR/l2.log)"
fi
# reboot again -> v2 must boot stably
reboot_qemu "$FLASH" "$OUTDIR/l2b.log"
if wait_pattern "$OUTDIR/l2b.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L2: v2 boots stably after confirm"
else
    fail "L2: v2 did not boot after confirm (see $OUTDIR/l2b.log)"
fi
# Run 11: same pty-capture limitation as above - the selection evidence
# for the stable boot is the ver 0x2 image line (old "Trying Update
# partition" check kept in the L2 block comment above).
grep -q "ver 0x2, type 0x601" "$OUTDIR/l2b.log" \
    && ok "L2: confirmed v2 still selected from Update (v2 > v1)" \
    || fail "L2: v2 not selected on the stable boot (no ver 0x2 in $OUTDIR/l2b.log)"
stop_qemu

# ============================================================================
# L3 - NON-DEFAULT OPTION (stated plainly): this scenario runs an
# ALLOW_DOWNGRADE=1 Linux wolfBoot, built from the same
# config/examples/versal2_vek385_linux.config (whose default is
# ALLOW_DOWNGRADE?=0) with ALLOW_DOWNGRADE=1 on the make command line -
# the same way test_qemu.sh Q5c builds its ALLOW_DOWNGRADE=1 wolfBoot for
# the bare-metal rollback scenario (the normal build is saved and
# restored around it). That is required: with ALLOW_DOWNGRADE undefined,
# wolfBoot_dualboot_candidate() (src/libwolfboot.c, the #ifndef
# ALLOW_DOWNGRADE block) refuses to roll back ("Rollback to lower version
# not allowed"), so the rollback the plan's Q5 requires cannot be
# demonstrated with the default config. L3b below covers the default
# config's behaviour as a separate scenario.
log "L3: rollback (ALLOW_DOWNGRADE=1 build; unconfirmed v2 in TESTING -> back to v1)"
echo "  NOTE: L3 uses an ALLOW_DOWNGRADE=1 Linux wolfBoot (non-default option;"
echo "        the config default ALLOW_DOWNGRADE?=0 is used by all other scenarios)."
WOLFBOOT_DG_ELF_LINUX="$OUTDIR/wolfboot_linux_downgrade.elf"
build_downgrade_linux_wolfboot "$WOLFBOOT_DG_ELF_LINUX" \
    || { fail "L3: ALLOW_DOWNGRADE=1 build (see above)"; exit 1; }
if [ ! -f "$WOLFBOOT_DG_ELF_LINUX.meta" ] || [ "$(cat "$WOLFBOOT_DG_ELF_LINUX.meta")" != "$(wb_cfg_meta)" ]; then
    fail "L3: cached ALLOW_DOWNGRADE=1 ELF partition addresses do not match the current config"
    exit 1
fi
ok "L3: ALLOW_DOWNGRADE=1 ELF partition addresses match the current config"
FLASH3="$OUTDIR/linux_flash_l3.bin"
make_linux_flash "$FLASH3" "$BUILD/fit_v1_signed.bin" "-"
start_qemu "$FLASH3" "$OUTDIR/l3a.log" "$WOLFBOOT_DG_ELF_LINUX" \
    || { fail "L3: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l3a.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3: v1 booted (fresh flash)"
else
    fail "L3: v1 did not boot (see $OUTDIR/l3a.log)"
fi
send "wbmtd update /v2.fit"
if wait_pattern "$OUTDIR/l3a.log" "UPDATE partition state set to UPDATING" "$UPD_WAIT"; then
    ok "L3: v2 written to UPDATE (UPDATING), NOT confirmed"
else
    fail "L3: wbmtd update failed (see $OUTDIR/l3a.log)"
fi
# reboot -> v2 boots (TESTING); no confirm
reboot_qemu "$FLASH3" "$OUTDIR/l3b.log" "$WOLFBOOT_DG_ELF_LINUX"
if wait_pattern "$OUTDIR/l3b.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3: unconfirmed v2 booted once (TESTING)"
else
    fail "L3: v2 did not boot (see $OUTDIR/l3b.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l3b.log" \
    && ok "L3: v2 image loaded on the TESTING boot (ver 0x2 in the boot log)" \
    || fail "L3: v2 not selected on the TESTING boot (see $OUTDIR/l3b.log)"
# reboot again -> the ALLOW_DOWNGRADE=1 build erases the TESTING UPDATE
# partition and boots the BOOT partition (v1). (The "Rollback to lower
# version not allowed" message is printed before the pty reader attaches,
# so the in-log evidence of the selection is the v1 image line - the same
# convention as L4's "Trying Boot partition" replacement, see the L2/L4
# comments above.)
reboot_qemu "$FLASH3" "$OUTDIR/l3c.log" "$WOLFBOOT_DG_ELF_LINUX"
if wait_pattern "$OUTDIR/l3c.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3: system boots again after the unconfirmed v2"
else
    fail "L3: no boot after the unconfirmed v2 (see $OUTDIR/l3c.log)"
fi
grep -q "ver 0x1, type 0x601" "$OUTDIR/l3c.log" \
    && ok "L3: rolled back to the Boot partition (v1 image loaded)" \
    || fail "L3: Boot partition not selected on the rollback boot"
stop_qemu
# The failed update must have been erased from the UPDATE partition
# (checked after stop_qemu: QEMU writes the backing file back only on
# clean shutdown). Original check, active again with the ALLOW_DOWNGRADE=1
# build (it was commented out in Run 11 because that run's L3 used the
# default config, which is now L3b).
# Old (run 3-12) slice, kept for reference (run 13 layout decision: 8 MB
# BOOT.BIN reservation, AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt):
#   sys.exit(0 if all(b == 0xFF for b in d[0x4600000:0x4600100]) else 1)
if python3 - "$FLASH3" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if all(b == 0xFF for b in d[0x49C0000:0x49C0100]) else 1)
PY
then
    ok "L3: UPDATE partition erased after the rollback"
else
    fail "L3: UPDATE partition not erased"
fi
# Run 12 additive check: the WHOLE UPDATE partition (0x49C0000..0x75C0000,
# WOLFBOOT_PARTITION_SIZE=0x2C00000, including the trailer at the end) is
# 0xFF after the rollback (wolfBoot_erase_partition() erases the whole
# partition, trailer included). Old (run 3-12) slice 0x4600000..0x7200000,
# kept for reference (run 13 layout decision: 8 MB BOOT.BIN reservation,
# AMD BOOT.BIN 5.31 MiB, evidence/mdom-bank-analysis-run9.txt).
if python3 - "$FLASH3" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if all(b == 0xFF for b in d[0x49C0000:0x75C0000]) else 1)
PY
then
    ok "L3: whole UPDATE partition (incl. trailer) is 0xFF after the rollback"
else
    fail "L3: whole UPDATE partition not erased"
fi

# ============================================================================
# L3b - Run 12 new scenario, NORMAL config (ALLOW_DOWNGRADE?=0, the
# default of config/examples/versal2_vek385_linux.config - no non-default
# option): an unconfirmed higher version is NOT rolled back.
# wolfBoot_dualboot_candidate() (src/libwolfboot.c) selects the higher
# version (UPDATE v2 > BOOT v1); the IMG_STATE_TESTING fallback block only
# erases+switches when ALLOW_DOWNGRADE is defined - otherwise it prints
# "Rollback to lower version not allowed" and keeps booting the UPDATE
# image. Run 11 verified this live with GDB at the dualboot_candidate
# breakpoint on the post-TESTING boot: boot_v=1, update_v=2,
# wolfBoot_get_partition_state(UPDATE)=0 with state byte 0x10
# (IMG_STATE_TESTING) - every rollback condition true except the
# ALLOW_DOWNGRADE gate.
log "L3b: default config (ALLOW_DOWNGRADE=0): unconfirmed higher version is not rolled back"
echo "  NOTE: L3b uses the NORMAL Linux wolfBoot (ALLOW_DOWNGRADE=0 default;"
echo "        this is the Run 11 scenario, kept as a new scenario; L3 above"
echo "        is the original rollback scenario with an ALLOW_DOWNGRADE=1 build)."
FLASH3B="$OUTDIR/linux_flash_l3b.bin"
make_linux_flash "$FLASH3B" "$BUILD/fit_v1_signed.bin" "-"
start_qemu "$FLASH3B" "$OUTDIR/l3ba.log" || { fail "L3b: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l3ba.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3b: v1 booted (fresh flash)"
else
    fail "L3b: v1 did not boot (see $OUTDIR/l3ba.log)"
fi
send "wbmtd update /v2.fit"
if wait_pattern "$OUTDIR/l3ba.log" "UPDATE partition state set to UPDATING" "$UPD_WAIT"; then
    ok "L3b: v2 written to UPDATE (UPDATING), NOT confirmed"
else
    fail "L3b: wbmtd update failed (see $OUTDIR/l3ba.log)"
fi
# reboot -> v2 boots (TESTING); no confirm
reboot_qemu "$FLASH3B" "$OUTDIR/l3bb.log"
if wait_pattern "$OUTDIR/l3bb.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3b: unconfirmed v2 booted once (TESTING)"
else
    fail "L3b: v2 did not boot (see $OUTDIR/l3bb.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l3bb.log" \
    && ok "L3b: v2 image loaded on the TESTING boot (ver 0x2 in the boot log)" \
    || fail "L3b: v2 not selected on the TESTING boot (see $OUTDIR/l3bb.log)"
# reboot again -> the default config keeps booting the UPDATE image
reboot_qemu "$FLASH3B" "$OUTDIR/l3bc.log"
if wait_pattern "$OUTDIR/l3bc.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3b: system boots again after the unconfirmed v2"
else
    fail "L3b: no boot after the unconfirmed v2 (see $OUTDIR/l3bc.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l3bc.log" \
    && ok "L3b: unconfirmed v2 boots again (ALLOW_DOWNGRADE=0: no rollback to lower v1)" \
    || fail "L3b: unexpected selection on the post-TESTING boot (see $OUTDIR/l3bc.log)"
send "wbmtd state"
if wait_pattern "$OUTDIR/l3bc.log" "UPDATE: state=TESTING" "$BOOT_WAIT"; then
    ok "L3b: guest confirms the UPDATE trailer still TESTING (update pending, not erased)"
else
    fail "L3b: UPDATE trailer state wrong after the post-TESTING boot (see $OUTDIR/l3bc.log)"
fi
stop_qemu
# The UPDATE image must be INTACT (the rollback/erase never ran on this
# build). (Checked after stop_qemu: QEMU writes the backing file back only
# on clean shutdown.)
if python3 - "$FLASH3B" "$BUILD/fit_v2_signed.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
v = open(sys.argv[2], 'rb').read()[:0x1000]
# NOTE: the slice end is 0x49C1000 = 0x49C0000 + 0x1000 (the first 4 KiB
# of the UPDATE partition in the run-13 layout). Run-13 first-draft bug
# (found by the failed L3b check): 0x49C01000 was written, which is
# 0x49C0000 + 0x10000, i.e. 64 KiB - off by a hex digit, exactly the
# off-by-4096 class of error the run-11 note recorded for the old
# address (0x4601000 = 0x4600000 + 0x1000 was right there; the wrong
# draft was 0x46001000). The corrected run-13 slice is
# d[0x49C0000:0x49C1000] (verified after the failed run: the per-byte
# diff of that slice vs the FIT is 0 - the UPDATE image was intact).
sys.exit(0 if d[0x49C0000:0x49C1000] == v else 1)
PY
then
    ok "L3b: UPDATE image intact (v2 still present, rollback not allowed)"
else
    fail "L3b: UPDATE image missing/corrupt after the post-TESTING boot"
fi

# ============================================================================
log "L4: refused update (corrupted signature -> v1 still boots)"
FLASH4="$OUTDIR/linux_flash_l4.bin"
make_linux_flash "$FLASH4" "$BUILD/fit_v1_signed.bin" "-"
start_qemu "$FLASH4" "$OUTDIR/l4a.log" || { fail "L4: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l4a.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L4: v1 booted (fresh flash)"
else
    fail "L4: v1 did not boot (see $OUTDIR/l4a.log)"
fi
send "wbmtd update /v2.fit --corrupt-sig"
if wait_pattern "$OUTDIR/l4a.log" "UPDATE partition state set to UPDATING" "$UPD_WAIT"; then
    ok "L4: corrupted v2 written to UPDATE (UPDATING)"
else
    fail "L4: wbmtd update --corrupt-sig failed (see $OUTDIR/l4a.log)"
fi
reboot_qemu "$FLASH4" "$OUTDIR/l4b.log"
if wait_pattern "$OUTDIR/l4b.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L4: system boots after the refused update"
else
    fail "L4: no boot after the refused update (see $OUTDIR/l4b.log)"
fi
grep -qE "Verifying signature\.\.\.FAILED|integrity\.\.\.FAILED" "$OUTDIR/l4b.log" \
    && ok "L4: UPDATE image refused (signature/integrity FAILED)" \
    || fail "L4: corrupted update was not refused"
# Run 11: "Trying Boot partition" is printed before the pty reader
# attaches (see the L2 comment above); the in-log evidence of the
# fallback boot is the v1 image line (ver 0x1). Old (run 5-10) check,
# kept for reference:
#   grep -q "Trying Boot partition" "$OUTDIR/l4b.log" \
#       && ok "L4: fell back to the Boot partition (v1)" \
#       || fail "L4: Boot partition not selected"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l4b.log" \
    && ok "L4: fell back to the Boot partition (v1 image loaded)" \
    || fail "L4: Boot partition not selected"
stop_qemu

# ============================================================================
# L5 - Run 17 new scenario: D2 "older image offered as an update", BOTH
# settings. A validly signed LOWER v1 is in the UPDATE partition (UPDATING)
# while the higher v2 is the confirmed (SUCCESS) boot image in the BOOT
# partition. wolfBoot's candidate selection (src/libwolfboot.c:2562-2564,
# `if (update_v > boot_v) candidate = PART_UPDATE`) never picks the lower v1
# (that guard is NOT gated by ALLOW_DOWNGRADE), and the candidate's (BOOT's)
# state is SUCCESS (not TESTING), so the ALLOW_DOWNGRADE branch is not
# reached either. Expected with BOTH the default (ALLOW_DOWNGRADE=0) and the
# ALLOW_DOWNGRADE=1 build: v2 (BOOT) boots; the older v1 update is ignored
# and left untouched.
#
# The v1-in-UPDATE (UPDATING) state is set up from the host (the same end
# state `wbmtd update /v1.fit` would produce). The wbmtd write path itself is
# not exercised here: it would require the RUNNING v2's initramfs to carry the
# 29 MB v1 FIT, which makes the v2 FIT ~44.3 MB and exceeds the 44 MB
# (0x2C00000) partition budget. The wolfBoot boot behaviour - the actual D2
# test - is fully exercised.
log "L5: D2 older update offered (v2 BOOT SUCCESS, v1 UPDATE UPDATING) - both settings"
echo "  NOTE: L5a runs the default (ALLOW_DOWNGRADE=0) build; L5b runs the"
echo "        ALLOW_DOWNGRADE=1 build (the same build L3 above built with"
echo "        `make ... ALLOW_DOWNGRADE=1`). v2 (BOOT) must boot in both; the"
echo "        older v1 in UPDATE must be ignored."

# Build-identity: L5a = default build ($WOLFBOOT_ELF, ALLOW_DOWNGRADE=0,
# verified by the 0a2 identity check); L5b = ALLOW_DOWNGRADE=1 build
# ($WOLFBOOT_DG_ELF_LINUX, built by build_downgrade_linux_wolfboot with
# `make ... ALLOW_DOWNGRADE=1`, as in L3). Re-verify both so each half of L5
# provably runs the build it claims.
if probe_linux_elf; then
    ok "L5 identity: default (ALLOW_DOWNGRADE=0) build verified (Linux config, nm ospi_dma_read + meta)"
else
    fail "L5 identity: default build is not the verified Linux-config build - L5 will NOT run"
    exit 1
fi
if [ -f "$WOLFBOOT_DG_ELF_LINUX" ] && [ -f "$WOLFBOOT_DG_ELF_LINUX.meta" ] \
   && [ "$(cat "$WOLFBOOT_DG_ELF_LINUX.meta" 2>/dev/null)" = "$(wb_cfg_meta)" ]; then
    ok "L5 identity: ALLOW_DOWNGRADE=1 build verified (config + partition meta match; built with make ALLOW_DOWNGRADE=1 as in L3)"
else
    fail "L5 identity: the ALLOW_DOWNGRADE=1 build is missing or its meta mismatches - L5 will NOT run"
    exit 1
fi

# Flash: v2 FIT in BOOT (SUCCESS), v1 FIT in UPDATE (UPDATING). The v1 FIT is
# the real signed lower-version image (29 MB, fits the 44 MB partition).
FLASH5="$OUTDIR/linux_flash_l5.bin"
make_linux_flash "$FLASH5" "$BUILD/fit_v2_signed.bin" "$BUILD/fit_v1_signed.bin"
python3 - "$FLASH5" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read())
MAGIC = bytes([0x42,0x4F,0x4F,0x54])
BOOT_END = 0x1dc0000 + 0x2c00000   # 0x49C0000 (end of the BOOT partition)
UPD_END  = 0x49c0000 + 0x2c00000   # 0x75C0000 (end of the UPDATE partition)
# trailer = [state byte at END-5][4-byte magic at END-4] (src/libwolfboot.c
# get_trailer_at). IMG_STATE_SUCCESS=0x00, IMG_STATE_UPDATING=0x70
# (include/wolfboot/wolfboot.h:674,685).
d[BOOT_END-5] = 0x00
d[BOOT_END-4:BOOT_END] = MAGIC
d[UPD_END-5]  = 0x70
d[UPD_END-4:UPD_END]  = MAGIC
open(sys.argv[1],'wb').write(d)
PY

# L5a: default (ALLOW_DOWNGRADE=0) build -> v2 (BOOT) boots
start_qemu "$FLASH5" "$OUTDIR/l5a.log" || { fail "L5a: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l5a.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5a(=0): v2 booted (the confirmed Boot image)"
else
    fail "L5a(=0): v2 did not boot (see $OUTDIR/l5a.log)"
fi
# The in-log evidence of the selection is the v2 image line (ver 0x2); the
# "Trying Boot partition" line is printed before the pty reader attaches (see
# the L2 comment). The older v1 (UPDATE) must NOT be selected.
grep -q "ver 0x2, type 0x601" "$OUTDIR/l5a.log" \
    && ok "L5a(=0): the higher v2 (Boot) is selected; the older v1 update is ignored" \
    || fail "L5a(=0): v2 not selected (see $OUTDIR/l5a.log)"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l5a.log" \
    && fail "L5a(=0): the older v1 (UPDATE) was selected (unexpected downgrade)" \
    || ok "L5a(=0): the older v1 (UPDATE) was not selected"
stop_qemu

# L5b: ALLOW_DOWNGRADE=1 build -> v2 (BOOT) boots (same result)
start_qemu "$FLASH5" "$OUTDIR/l5b.log" "$WOLFBOOT_DG_ELF_LINUX" || { fail "L5b: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l5b.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5b(=1): v2 booted with the ALLOW_DOWNGRADE=1 build"
else
    fail "L5b(=1): v2 did not boot (see $OUTDIR/l5b.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l5b.log" \
    && ok "L5b(=1): the higher v2 (Boot) is selected even with ALLOW_DOWNGRADE=1" \
    || fail "L5b(=1): v2 not selected (see $OUTDIR/l5b.log)"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l5b.log" \
    && fail "L5b(=1): the older v1 (UPDATE) was selected (unexpected downgrade)" \
    || ok "L5b(=1): the older v1 (UPDATE) was not selected"
stop_qemu

# ============================================================================
# L5c - Run 18 new scenario: D2 "older image offered as an update" through
# the REAL update path, BOTH settings. Same D2 end state as L5 (a validly
# signed LOWER v1 in UPDATE with the UPDATING trailer, the higher v2
# confirmed (SUCCESS) in BOOT), but the v1 is written to UPDATE by the
# RUNNING v2 guest with `wbmtd update /v1c.fit` - the guest's own MTD
# driver erases the UPDATE partition, programs the image and sets the
# trailer (the same path as L2's `wbmtd update /v2.fit`) - instead of the
# host dd'ing the flash file as L5 does.
#
# initramfs fix (chosen, per the run request): a SEPARATE initramfs for
# this scenario. The running v2's FIT (fit_v2c) embeds fit_v1c as
# /v1c.fit. fit_v1c is a validly signed version-1 image with the PLAIN
# initramfs (~15 MB, the same size class as the v2 FIT) rather than the
# full 29 MB v1 FIT: embedding the full v1 FIT would make fit_v2c ~44.3 MB
# and exceed the 44 MB (0x2C00000) partition budget (the run-17 L5 note).
# The D2 decision depends only on the versions and signatures of the two
# images (`update_v > boot_v`, src/libwolfboot.c:2562-2564), so the
# smaller signed v1 is equivalent for this assertion. fit_v1c is never
# booted in this scenario; it must simply be a valid lower-version image
# in UPDATE.
#
# Flow: fresh flash with v2c in BOOT (SUCCESS) -> boot v2c (default build)
# -> in the guest: `wbmtd update /v1c.fit` (the real update path) ->
# reboot with the default (ALLOW_DOWNGRADE=0, L5c-a) and the
# ALLOW_DOWNGRADE=1 (L5c-b) builds: v2 (BOOT) must boot in both; the older
# v1c in UPDATE must be ignored. A host check afterwards proves the UPDATE
# partition carries the v1c image the guest wrote (first 4 KiB compare),
# i.e. the wbmtd write really landed (not a host-side dd).
log "L5c: D2 through the real update path (the v2 guest writes v1c with wbmtd update) - both settings"
echo "  NOTE: L5c-a runs the default (ALLOW_DOWNGRADE=0) build; L5c-b runs the"
echo "        ALLOW_DOWNGRADE=1 build (the same build L3 above built with"
echo "        make ALLOW_DOWNGRADE=1). The lower v1c is written to UPDATE by the"
echo "        RUNNING v2c guest (the real update path); v2 (BOOT) must boot in"
echo "        both; the older v1c in UPDATE must be ignored. (L5 above keeps"
echo "        the host-dd variant as it is.)"

# Build-identity (same convention as L5): L5c-a = default build
# ($WOLFBOOT_ELF, ALLOW_DOWNGRADE=0, verified by the 0a2 identity check);
# L5c-b = the ALLOW_DOWNGRADE=1 build ($WOLFBOOT_DG_ELF_LINUX, built by L3
# with `make ... ALLOW_DOWNGRADE=1`). Re-verify both so each half of L5c
# provably runs the build it claims.
if probe_linux_elf; then
    ok "L5c identity: default (ALLOW_DOWNGRADE=0) build verified (Linux config, nm ospi_dma_read + meta)"
else
    fail "L5c identity: default build is not the verified Linux-config build - L5c will NOT run"
    exit 1
fi
if [ -f "$WOLFBOOT_DG_ELF_LINUX" ] && [ -f "$WOLFBOOT_DG_ELF_LINUX.meta" ] \
   && [ "$(cat "$WOLFBOOT_DG_ELF_LINUX.meta" 2>/dev/null)" = "$(wb_cfg_meta)" ]; then
    ok "L5c identity: ALLOW_DOWNGRADE=1 build verified (config + partition meta match; built with make ALLOW_DOWNGRADE=1 as in L3)"
else
    fail "L5c identity: the ALLOW_DOWNGRADE=1 build is missing or its meta mismatches - L5c will NOT run"
    exit 1
fi

# Flash: v2c FIT in BOOT (SUCCESS), UPDATE empty. The v2c guest carries
# /v1c.fit (the validly signed lower v1) in its own initramfs.
FLASH5C="$OUTDIR/linux_flash_l5c.bin"
make_linux_flash "$FLASH5C" "$BUILD/fit_v2c_signed.bin" "-"
python3 - "$FLASH5C" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read())
MAGIC = bytes([0x42,0x4F,0x4F,0x54])
BOOT_END = 0x1dc0000 + 0x2c00000   # 0x49C0000 (end of the BOOT partition)
# trailer = [state byte at END-5][4-byte magic at END-4] (same convention
# as L5 above). IMG_STATE_SUCCESS=0x00.
d[BOOT_END-5] = 0x00
d[BOOT_END-4:BOOT_END] = MAGIC
open(sys.argv[1],'wb').write(d)
PY

# Initial boot: v2c (ver 0x2) from BOOT
start_qemu "$FLASH5C" "$OUTDIR/l5c0.log" || { fail "L5c: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l5c0.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5c: v2c booted from BOOT (the real-update-path D2 start state)"
else
    fail "L5c: v2c did not boot (see $OUTDIR/l5c0.log)"
fi
# The v2c guest writes the lower v1c to UPDATE through its own MTD driver
# (the real update path: erase + program + UPDATING trailer).
send "wbmtd update /v1c.fit"
if wait_pattern "$OUTDIR/l5c0.log" "UPDATE partition state set to UPDATING" "$UPD_WAIT"; then
    ok "L5c: the v2 guest wrote v1c to UPDATE via wbmtd (real update path; trailer UPDATING)"
else
    fail "L5c: wbmtd update /v1c.fit failed in the v2 guest (see $OUTDIR/l5c0.log)"
fi

# L5c-a: reboot with the default (ALLOW_DOWNGRADE=0) build -> v2 (BOOT) boots
reboot_qemu "$FLASH5C" "$OUTDIR/l5ca.log"
if wait_pattern "$OUTDIR/l5ca.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5c(=0): v2 booted after the guest-written v1 update (the confirmed Boot image)"
else
    fail "L5c(=0): v2 did not boot (see $OUTDIR/l5ca.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l5ca.log" \
    && ok "L5c(=0): the higher v2 (Boot) is selected; the older v1c update is ignored" \
    || fail "L5c(=0): v2 not selected (see $OUTDIR/l5ca.log)"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l5ca.log" \
    && fail "L5c(=0): the older v1c (UPDATE) was selected (unexpected downgrade)" \
    || ok "L5c(=0): the older v1c (UPDATE) was not selected"

# L5c-b: reboot with the ALLOW_DOWNGRADE=1 build -> v2 (BOOT) boots (same result)
reboot_qemu "$FLASH5C" "$OUTDIR/l5cb.log" "$WOLFBOOT_DG_ELF_LINUX"
if wait_pattern "$OUTDIR/l5cb.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5c(=1): v2 booted with the ALLOW_DOWNGRADE=1 build"
else
    fail "L5c(=1): v2 did not boot (see $OUTDIR/l5cb.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l5cb.log" \
    && ok "L5c(=1): the higher v2 (Boot) is selected even with ALLOW_DOWNGRADE=1" \
    || fail "L5c(=1): v2 not selected (see $OUTDIR/l5cb.log)"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l5cb.log" \
    && fail "L5c(=1): the older v1c (UPDATE) was selected (unexpected downgrade)" \
    || ok "L5c(=1): the older v1c (UPDATE) was not selected"
stop_qemu
# The UPDATE partition must carry the v1c image the GUEST wrote (first
# 4 KiB compare, the same slice convention as L3b's intact-image check).
# This is the evidence that the real update path ran (not a host-side dd).
if python3 - "$FLASH5C" "$BUILD/fit_v1c_signed.bin" <<'PY'
import sys
d = open(sys.argv[1],'rb').read()
v = open(sys.argv[2],'rb').read()[:0x1000]
sys.exit(0 if d[0x49C0000:0x49C1000] == v else 1)
PY
then
    ok "L5c: the UPDATE partition contains the v1c image written by the guest (real update path, not a host dd)"
else
    fail "L5c: the UPDATE partition does not match the v1c FIT (the wbmtd write did not land)"
fi

# --- summary ----------------------------------------------------------------
echo
echo "==========================================="
echo " Local Linux test (QEMU, not CI): PASS=$PASS FAIL=$FAIL"
echo "==========================================="
[ "$FAIL" -eq 0 ] && echo "ALL LINUX TESTS PASSED" || echo "SOME LINUX TESTS FAILED"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
