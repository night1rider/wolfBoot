#!/bin/bash
#
# test_linux.sh - versal2 QEMU local Linux test (NOT part of CI): the EDF
# kernel + device tree + initramfs packed in the signed FIT boots to a
# shell in QEMU's amd-versal2-virt, driven through the guest's /dev/mtdN
# by the wbmtd tool.
#
# Scenarios:
#   L1  boot to shell  - the v1 signed FIT (EDF kernel Image.gz + QEMU
#       DTB with the OSPI overlay + initramfs) boots; the kernel's own
#       Cadence QSPI/OSPI driver (the QEMU DTB binds the generic
#       "cdns,qspi-nor" platdata - see ospi-overlay.dts) probes
#       QEMU's OSPI model and creates the
#       fixed-partition MTD devices; a shell is reachable. (normal
#       config, ALLOW_DOWNGRADE=0)
#   L2  update + confirm - in the guest (v1): `wbmtd update /v2.fit`
#       (erases UPDATE, programs the v2 signed FIT, sets the UPDATE
#       trailer to UPDATING), then "reboot" (QEMU restarted from the SAME
#       flash file - the QEMU machine has no PSCI): wolfBoot selects the
#       higher-version UPDATE image, boots v2 (TESTING). In the guest
#       (v2): `wbmtd confirm` (UPDATE trailer -> SUCCESS). One more reboot
#       boots v2 stably (SUCCESS). (normal config, ALLOW_DOWNGRADE=0)
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
#   L3b default-config no-rollback - the same flow as L3 but with the
#       NORMAL wolfBoot (ALLOW_DOWNGRADE=0): an unconfirmed higher
#       version is not rolled back; v2 boots again ("Rollback to lower
#       version not allowed"), the UPDATE trailer is kept TESTING and the
#       UPDATE image stays intact.
#   L4  refused update - fresh flash; in the guest (v1): `wbmtd update
#       /v2.fit --corrupt-sig` (the signature TLV is corrupted in RAM
#       before the write). On reboot wolfBoot refuses the UPDATE image
#       (signature check FAILED) and boots v1. (normal config,
#       ALLOW_DOWNGRADE=0)
#   L5  D2 older update offered (both settings) - a validly signed
#       LOWER v1 is in the UPDATE partition (UPDATING) while the higher
#       v2 is the confirmed (SUCCESS) boot image in BOOT. wolfBoot's
#       candidate selection never picks the lower v1 (`update_v > boot_v`
#       is not gated by ALLOW_DOWNGRADE) and the candidate's state is
#       SUCCESS, so v2 (BOOT) boots with BOTH the default
#       (ALLOW_DOWNGRADE=0, L5a) and the ALLOW_DOWNGRADE=1 (L5b) build;
#       the older v1 update is ignored. The v1-in-UPDATE state is set
#       from the host (the wbmtd write path would require the running
#       v2's initramfs to carry the 29 MB v1 FIT, which exceeds the
#       44 MB partition budget).
#   L5c D2 through the real update path (both settings) - the same D2
#       end state as L5, but the lower v1 is written to UPDATE by the
#       RUNNING v2 guest with `wbmtd update /v1c.fit` (erase + program +
#       UPDATING trailer over the guest's own MTD driver - the same path
#       as L2's `wbmtd update /v2.fit`) instead of dd'd from the host.
#       The separate initramfs for this scenario (fit_v2c's) embeds
#       fit_v1c, a validly signed lower version-1 image with the plain
#       initramfs - the full 29 MB v1 FIT would make fit_v2c exceed the
#       44 MB partition budget. v2 (BOOT) must boot with BOTH the
#       default (ALLOW_DOWNGRADE=0, L5c-a) and the ALLOW_DOWNGRADE=1
#       (L5c-b) build; the older v1c update is ignored.
#
# Everything is produced from inputs passed as environment variables (the
# EDF WIC, the busybox .deb, ...) into a build dir OUTSIDE the repo; the
# backing flash files and logs go to OUTDIR.
#
# Usage:
#   EDF_WIC=/opt/build/edf/...wic.xz \
#   BB_DEB=/opt/build/debs/busybox-static_*.arm64.deb \
#   ./test_linux.sh
#
#   (env overrides: BUILD, QEMU, WOLFBOOT_ELF, TRAMP, OUTDIR, BOOT_WAIT,
#    UPD_WAIT)
#
#   The script builds its own trampoline with -DTRAMP_GIC_INIT. A TRAMP
#   you pass in must be built with that flag too, or Linux hangs.
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WBOOT="$(cd "$HERE/../../../../../" && pwd)"
LINUXDIR="$HERE"

BUILD="${BUILD:-/opt/build/wb-linux}"
EDF_WIC_NAME="edf-platform-disk-image-amd-cortexa78-mali-common"
EDF_WIC_NAME="$EDF_WIC_NAME.rootfs-20260609231841.wic.xz"
EDF_WIC="${EDF_WIC:-/opt/build/edf/$EDF_WIC_NAME}"
BB_DEB="${BB_DEB:-/opt/build/debs/busybox-static_1.37.0-6+b9_arm64.deb}"
QEMU="${QEMU:-/opt/build/qemu-11.1.3/build/qemu-system-aarch64}"
WOLFBOOT_ELF="${WOLFBOOT_ELF:-$WBOOT/wolfboot.elf}"
TRAMP="${TRAMP:-}"
OUTDIR="${OUTDIR:-$WBOOT/tools/scripts/versal2/qemu/stage/linux}"
# Time limit in seconds for each boot (the kernel unpacks, then starts)
BOOT_WAIT="${BOOT_WAIT:-240}"
# A wbmtd update (erase 44 MB, write 14.3 MB) takes about 450 s in QEMU
# (measured: erase ~150 s, write ~250 s).
UPD_WAIT="${UPD_WAIT:-600}"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
log()  { echo; echo "### $1"; }

# --- inputs ---------------------------------------------------------------
for t in "$QEMU" "$WOLFBOOT_ELF" "$EDF_WIC" "$BB_DEB" \
         "$WBOOT/tools/keytools/sign" \
         "$WBOOT/wolfboot_signing_private_key.der"; do
    [ -e "$t" ] || { echo "missing input: $t"; exit 2; }
done
command -v mkimage >/dev/null || {
    echo "mkimage (u-boot-tools) not found"; exit 2; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 2; }
mkdir -p "$BUILD" "$OUTDIR"

# Linux needs the trampoline's GIC setup (-DTRAMP_GIC_INIT), or the kernel
# timer never ticks. Build it here unless TRAMP is given.
if [ -z "$TRAMP" ]; then
    TRAMP="$BUILD/tramp_gic.elf"
    aarch64-linux-gnu-gcc -nostdlib -nostartfiles -static -march=armv8-a \
        -DTRAMP_GIC_INIT -T "$HERE/../trampoline/tramp.ld" -o "$TRAMP" \
        "$HERE/../trampoline/trampoline.S" || {
        echo "trampoline build failed"; exit 2; }
fi
[ -e "$TRAMP" ] || { echo "missing input: $TRAMP"; exit 2; }

# --- 0a. cached-build geometry check ---------------------------------------
# A saved ALLOW_DOWNGRADE=1 ELF from an old config would look for v1 at
# the wrong address. Its .meta file (config hash, partition addresses)
# must match the current config, or the ELF is rebuilt.
WB_LINUX_CONFIG="$WBOOT/config/examples/versal2_vek385_linux.config"
wb_cfg_meta() {
    # echo "config_sha256 boot_addr upd_addr swap_addr allow_downgrade"
    python3 - "$WB_LINUX_CONFIG" <<'PY'
import hashlib, sys, re
cfg = sys.argv[1]
data = open(cfg, 'rb').read()
def val(name, default=None):
    m = re.search(r'(?m)^%s(\?|=)\s*(\S+)' % re.escape(name),
                  data.decode())
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
    if [ -f "$WOLFBOOT_DG_ELF_LINUX.meta" ] && \
       [ "$(cat "$WOLFBOOT_DG_ELF_LINUX.meta" 2>/dev/null)" = \
         "$CUR_META" ]; then
        # Pass the text with <<< (cut would read it as a file name)
        ok "L0: cached ALLOW_DOWNGRADE=1 ELF geometry matches current \
config ($(cut -d' ' -f2- <<<"$CUR_META"))"
    elif file "$WOLFBOOT_DG_ELF_LINUX" 2>/dev/null | \
         grep -q "ELF 64-bit.*aarch64"; then
        # The saved ELF is out of date (config changed): rebuild it below
        echo "  cached ALLOW_DOWNGRADE=1 ELF is STALE for the current" \
             "config (will rebuild):"
        echo "    cached: $(cat "$WOLFBOOT_DG_ELF_LINUX.meta" 2>/dev/null \
            || echo '<no meta>')"
        echo "    now:    $CUR_META"
        ok "L0: stale cache detected, rebuild scheduled (addresses must \
match current config)"
    else
        fail "L0: cached ALLOW_DOWNGRADE=1 ELF is not a valid aarch64 ELF \
and its meta mismatches"
        exit 1
    fi
fi

# --- 0a2. wolfboot.elf identity check --------------------------------------
# L1/L2/L3b/L4 need the versal2_vek385_linux.config build. The bare-metal
# build would panic in Linux ("Non-EFI boot detected with MMU..."). If the
# .meta file or the DMA read path is wrong, rebuild from the Linux config.
wb_linux_meta() {
    # echo "config_sha256 boot upd swap allow_downgrade boot_el2
    #       el2_mmu_off ramdisk_addr"
    python3 - "$WB_LINUX_CONFIG" <<'PY'
import hashlib, sys, re
data = open(sys.argv[1], 'rb').read()
def val(name, default='unset'):
    m = re.search(r'(?m)^%s(\?|=)\s*(\S+)' % re.escape(name),
                  data.decode())
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
# probe_linux_elf: 0 = $WOLFBOOT_ELF is the checked Linux-config build.
# Use grep -c, not -q: with pipefail, -q can stop nm early (exit 141)
# and make a good ELF look bad.
probe_linux_elf() {
    [ -f "$WOLFBOOT_ELF" ] || return 1
    aarch64-linux-gnu-nm "$WOLFBOOT_ELF" 2>/dev/null | \
        grep -cE "^[0-9a-f]+ [TtWwVvRrDdBb] versal2_dma$" | \
        grep -q "^[1-9]" || return 1
    [ -f "$WOLFBOOT_ELF.meta" ] && \
        [ "$(cat "$WOLFBOOT_ELF.meta" 2>/dev/null)" = "$LINUX_META" ] || \
        return 1
    return 0
}
if probe_linux_elf; then
    ok "identity: wolfboot.elf is the versal2_vek385_linux.config build \
(BOOT_EL2, WOLFBOOT_VERSAL2_EL2_MMU_OFF, Linux load addresses; \
versal2_dma present, nm; meta match)"
else
    echo "  wolfboot.elf is not the verified Linux-config build" \
         "(expected meta):"
    echo "    now: $LINUX_META"
    if [ -f "$WOLFBOOT_ELF" ]; then
        echo "    elf: $(cat "$WOLFBOOT_ELF.meta" 2>/dev/null || \
            echo '<no meta>')"
        if ! aarch64-linux-gnu-nm "$WOLFBOOT_ELF" 2>/dev/null | \
             grep -cE "^[0-9a-f]+ [TtWwVvRrDdBb] versal2_dma$" | \
             grep -q "^[1-9]"; then
            echo "    versal2_dma: absent (not the DMA default of the" \
                 "Linux config)"
        fi
    fi
    echo "  rebuilding the Linux-config wolfBoot from" \
         "versal2_vek385_linux.config (cp to .config, make clean, make)"
    if ( cd "$WBOOT" \
        && cp config/examples/versal2_vek385_linux.config .config \
        && make clean TARGET=versal2 >/dev/null 2>&1 \
        && make TARGET=versal2 >/dev/null 2>&1 \
        && echo "$LINUX_META" > "$WOLFBOOT_ELF.meta" ) \
       && probe_linux_elf; then
        ok "identity: Linux-config wolfBoot rebuilt from \
versal2_vek385_linux.config, identity re-verified"
    else
        fail "identity: could not build/verify the Linux-config \
wolfboot.elf - the Linux suite would boot an unverified ELF"
        exit 1
    fi
fi

# --- 0. EDF kernel Image from the WIC -------------------------------------
# Partition 1 of the WIC disk image holds the kernel Image. It is the
# same file the board's U-Boot loads, used unchanged.
edf_kernel() {
    local p1dir="$BUILD/edf-bootpart"
    if [ -s "$BUILD/Image" ]; then
        echo "  reusing $BUILD/Image ($(stat -c %s "$BUILD/Image") bytes)"
        return
    fi
    mkdir -p "$p1dir"
    local raw="${EDF_WIC%.xz}"
    [ -e "$raw" ] || { xz -dk -f "$EDF_WIC"; raw="${EDF_WIC%.xz}"; }
    # Partition 1: 1 GB, starting at sector 64
    local p1raw="$BUILD/edf-bootpart.part"
    if [ ! -e "$p1raw" ]; then
        dd if="$raw" of="$p1raw" bs=512 skip=64 count=2097152 status=none
    fi
    if mountpoint -q "$p1dir" 2>/dev/null; then :; else
        local loop
        loop="$(sudo losetup -f --show "$p1raw")"
        sudo mount -o ro "$loop" "$p1dir"
    fi
    [ -s "$p1dir/Image" ] || {
        echo "  no Image in the EDF boot partition"; return 1; }
    cp "$p1dir/Image" "$BUILD/Image"
    echo "  EDF kernel: $p1dir/Image -> $BUILD/Image" \
         "($(stat -c %s "$BUILD/Image") bytes)"
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
    V2FIT="$BUILD/fit_v2_signed.bin" "$LINUXDIR/mk_initramfs.sh" | \
    tail -3 || exit 6
BUILD="$BUILD" FIT_V2=0 "$LINUXDIR/mk_fit.sh" | tail -3 || exit 7
ok "signed FITs built (v1: $(stat -c %s "$BUILD/fit_v1_signed.bin") B, \
v2: $(stat -c %s "$BUILD/fit_v2_signed.bin") B)"

# L5c FITs: fit_v1c is a small signed v1. fit_v2c (v2) carries it as
# /v1c.fit so the v2 guest can write it to UPDATE. The full 29 MB v1 FIT
# would make fit_v2c bigger than the 44 MB partition.
log "L5c FITs (real-update-path D2 variant)"
BUILD="$BUILD" FIT_V1=0 FIT_V2=0 FIT_V1C=1 "$LINUXDIR/mk_fit.sh" | \
    tail -3 || exit 7
BUILD="$BUILD" BB_DEB="$BB_DEB" WBMTD="$BUILD/wbmtd.aarch64" \
    EXTRA_FIT="$BUILD/fit_v1c_signed.bin" EXTRA_FIT_NAME=/v1c.fit \
    "$LINUXDIR/mk_initramfs.sh" | tail -3 || exit 6
BUILD="$BUILD" FIT_V1=0 FIT_V2=0 FIT_V2C=1 "$LINUXDIR/mk_fit.sh" | \
    tail -3 || exit 7
ok "L5c signed FITs built \
(v1c: $(stat -c %s "$BUILD/fit_v1c_signed.bin") B, \
v2c: $(stat -c %s "$BUILD/fit_v2c_signed.bin") B; \
both within the 44 MB partition budget)"

# --- QEMU helpers ----------------------------------------------------------
# start_qemu <flash> <logfile> [wolfboot.elf]: sets QEMU_PID and PTTY.
# The guest console (UART1) goes to a pty, which is copied to <logfile>.
# QEMU's own messages go to <logfile>.qem.
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
    [ -n "$PTTY" ] || {
        echo "QEMU did not create a pty: $(cat "$logf.qem" 2>/dev/null)"
        return 1; }
    stty -F "$PTTY" raw -echo 2>/dev/null || true
    ( cat "$PTTY" >>"$logf" 2>/dev/null ) &
    READER_PID=$!
    return 0
}
stop_qemu() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null && \
        wait "$QEMU_PID" 2>/dev/null
    [ -n "${READER_PID:-}" ] && kill "$READER_PID" 2>/dev/null && \
        wait "$READER_PID" 2>/dev/null
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
# The trampoline has no PSCI, so a "reboot" restarts QEMU with the same
# flash file. The flash contents are kept.
reboot_qemu() {
    local flash="$1" logf="$2" elf="${3:-$WOLFBOOT_ELF}"
    stop_qemu
    start_qemu "$flash" "$logf" "$elf"
}

# build_downgrade_linux_wolfboot <out-elf>: build the Linux config with
# ALLOW_DOWNGRADE=1, save it as <out-elf>, then put the normal build back.
# A saved build is reused only if its .meta matches the current config.
build_downgrade_linux_wolfboot() {
    local out_elf="$1"
    local meta
    meta="$(wb_cfg_meta)"
    if [ -f "$out_elf" ] && [ -f "$out_elf.meta" ] && \
       [ "$(cat "$out_elf.meta")" = "$meta" ]; then
        echo "  reusing ALLOW_DOWNGRADE=1 build (meta matches current" \
             "config): $out_elf"
        return 0
    fi
    if [ -f "$out_elf" ]; then
        echo "  cached ALLOW_DOWNGRADE=1 build is stale (config or" \
             "partition addresses changed) - rebuilding"
        rm -f "$out_elf"
    fi
    echo "  building ALLOW_DOWNGRADE=1 Linux wolfBoot (saving the normal" \
         "build)"
    cp "$WOLFBOOT_ELF" "$OUTDIR/wolfboot_linux_normal.elf.bak"
    if ( cd "$WBOOT" \
        && cp config/examples/versal2_vek385_linux.config .config \
        && make clean TARGET=versal2 >/dev/null 2>&1 \
        && make TARGET=versal2 ALLOW_DOWNGRADE=1 >/dev/null 2>&1 \
        && cp wolfboot.elf "$out_elf" ); then
        : # the downgrade build is saved
    else
        cp "$OUTDIR/wolfboot_linux_normal.elf.bak" "$WBOOT/wolfboot.elf" \
            2>/dev/null || true
        echo "  ERROR: ALLOW_DOWNGRADE=1 Linux wolfBoot build failed"
        return 1
    fi
    # Put the normal build back for the later tests
    cp "$OUTDIR/wolfboot_linux_normal.elf.bak" "$WBOOT/wolfboot.elf"
    # Save the build inputs, so an out-of-date ELF is caught next time
    echo "$meta" > "$out_elf.meta"
    echo "  ALLOW_DOWNGRADE=1 build saved: $out_elf (normal build" \
         "restored, meta written)"
    return 0
}

# make_linux_flash <out> <boot_img> <upd_img|->: BOOT at 0x1DC0000,
# UPDATE at 0x49C0000 (versal2_vek385_linux.config).
make_linux_flash() {
    local out="$1" boot="$2" upd="$3"
    rm -f "$out"
    # Fill with 0xFF, the value of erased flash. Writes can only clear
    # bits, so a 0x00 fill would make every trailer write do nothing.
    python3 -c "open('$out','wb').write(b'\\xff'*0x10000000)"
    # 1 MB blocks for speed; oflag=seek_bytes keeps seek= in bytes.
    dd if="$boot" of="$out" bs=1M seek=$((0x1dc0000)) oflag=seek_bytes \
        conv=notrunc status=none
    [ "$upd" != "-" ] && dd if="$upd" of="$out" bs=1M seek=$((0x49c0000)) \
        oflag=seek_bytes conv=notrunc status=none
}

BANNER="wolfBoot Q5 Linux test shell"

# ============================================================================
log "L1: boot to shell (v1 FIT: EDF kernel + QEMU DTB + initramfs)"
FLASH="$OUTDIR/linux_flash.bin"
make_linux_flash "$FLASH" "$BUILD/fit_v1_signed.bin" "-"
start_qemu "$FLASH" "$OUTDIR/l1.log" || {
    fail "L1: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l1.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L1: kernel booted to the initramfs shell"
else
    fail "L1: no shell banner after ${BOOT_WAIT}s (see $OUTDIR/l1.log)"
fi
grep -q "Linux version 6.18.10-xilinx" "$OUTDIR/l1.log" \
    && ok "L1: EDF kernel 6.18.10-xilinx (unchanged Image from the WIC)" \
    || fail "L1: EDF kernel banner missing"
# The kernel's Cadence QSPI driver must have made the MTD devices
send "cat /proc/mtd"
if wait_pattern "$OUTDIR/l1.log" "mtd0" "$UPD_WAIT"; then
    ok "L1: /proc/mtd present (MTD char devices created)"
else
    fail "L1: /proc/mtd not readable"
fi
sleep 3
# This kernel prints "mtd0: <size> <erase size>" (mtd_proc_show() in
# drivers/mtd/mtdcore.c), so the whole flash is "mtd0: 10000000 00020000".
if grep -qE "mtd0: +10000000 00020000" "$OUTDIR/l1.log" \
    && grep -qE "boot" "$OUTDIR/l1.log" && \
       grep -qE "update" "$OUTDIR/l1.log"; then
    ok "L1: whole flash (0x10000000) + boot/update/swap partitions in \
/proc/mtd"
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
    && ok "L1: CONFIG_SPI_CADENCE_QUADSPI=y in /proc/config.gz \
(shown at boot)" \
    || fail "L1: CONFIG_SPI_CADENCE_QUADSPI line missing"

# ============================================================================
log "L2: update + confirm (v1 -> v2, then wolfBoot_success)"
send "wbmtd update /v2.fit"
if wait_pattern "$OUTDIR/l1.log" "UPDATE partition state set to UPDATING" \
    "$UPD_WAIT"; then
    ok "L2: wbmtd wrote v2 to UPDATE and set the trailer to UPDATING"
else
    fail "L2: wbmtd update failed (see $OUTDIR/l1.log)"
fi
# Reboot: wolfBoot must pick the UPDATE partition (v2)
reboot_qemu "$FLASH" "$OUTDIR/l2.log"
if wait_pattern "$OUTDIR/l2.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L2: v2 booted after the update (TESTING)"
else
    fail "L2: v2 did not boot (see $OUTDIR/l2.log)"
fi
# "Trying Update partition" prints before the log starts, so it is never
# in the log. Check "ver 0x2" (the v2 image loaded) and the guest's
# "UPDATE: state=TESTING" instead.
grep -q "ver 0x2, type 0x601" "$OUTDIR/l2.log" \
    && ok "L2: v2 image loaded (ver 0x2 in the boot log)" \
    || fail "L2: Update partition not selected (no ver 0x2 in \
$OUTDIR/l2.log)"
send "wbmtd state"
if wait_pattern "$OUTDIR/l2.log" "UPDATE: state=TESTING" "$BOOT_WAIT"; then
    ok "L2: guest sees the UPDATE trailer as TESTING (trigger active)"
else
    fail "L2: UPDATE trailer not TESTING in the guest (see $OUTDIR/l2.log)"
fi
grep -q "Firmware Valid" "$OUTDIR/l2.log" \
    && ok "L2: v2 signature verified (Firmware Valid)" \
    || fail "L2: v2 signature not verified"
# Confirm from the v2 guest
send "wbmtd confirm"
if wait_pattern "$OUTDIR/l2.log" "UPDATE partition state set to SUCCESS" \
    "$UPD_WAIT"; then
    ok "L2: wbmtd confirm set the active partition to SUCCESS"
else
    fail "L2: wbmtd confirm failed (see $OUTDIR/l2.log)"
fi
send "wbmtd state"
if wait_pattern "$OUTDIR/l2.log" "UPDATE: state=SUCCESS" "$BOOT_WAIT"; then
    ok "L2: guest sees the UPDATE trailer as SUCCESS after confirm"
else
    fail "L2: UPDATE trailer not SUCCESS after confirm (see $OUTDIR/l2.log)"
fi
# Reboot again: v2 must still boot
reboot_qemu "$FLASH" "$OUTDIR/l2b.log"
if wait_pattern "$OUTDIR/l2b.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L2: v2 boots stably after confirm"
else
    fail "L2: v2 did not boot after confirm (see $OUTDIR/l2b.log)"
fi
# As above, "ver 0x2" in the log shows v2 was picked
grep -q "ver 0x2, type 0x601" "$OUTDIR/l2b.log" \
    && ok "L2: confirmed v2 still selected from Update (v2 > v1)" \
    || fail "L2: v2 not selected on the stable boot (no ver 0x2 in \
$OUTDIR/l2b.log)"
stop_qemu

# ============================================================================
# L3 uses a NON-DEFAULT ALLOW_DOWNGRADE=1 build. Without it, wolfBoot
# refuses to roll back (src/libwolfboot.c, wolfBoot_dualboot_candidate).
# L3b tests the default config.
log "L3: rollback (ALLOW_DOWNGRADE=1 build; unconfirmed v2 in TESTING -> \
back to v1)"
echo "  NOTE: L3 uses an ALLOW_DOWNGRADE=1 Linux wolfBoot (non-default" \
     "option;"
echo "        the config default ALLOW_DOWNGRADE?=0 is used by all other" \
     "scenarios)."
WOLFBOOT_DG_ELF_LINUX="$OUTDIR/wolfboot_linux_downgrade.elf"
build_downgrade_linux_wolfboot "$WOLFBOOT_DG_ELF_LINUX" \
    || { fail "L3: ALLOW_DOWNGRADE=1 build (see above)"; exit 1; }
if [ ! -f "$WOLFBOOT_DG_ELF_LINUX.meta" ] || \
   [ "$(cat "$WOLFBOOT_DG_ELF_LINUX.meta")" != "$(wb_cfg_meta)" ]; then
    fail "L3: cached ALLOW_DOWNGRADE=1 ELF partition addresses do not \
match the current config"
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
if wait_pattern "$OUTDIR/l3a.log" "UPDATE partition state set to UPDATING" \
    "$UPD_WAIT"; then
    ok "L3: v2 written to UPDATE (UPDATING), NOT confirmed"
else
    fail "L3: wbmtd update failed (see $OUTDIR/l3a.log)"
fi
# Reboot: v2 boots (TESTING); it is not confirmed
reboot_qemu "$FLASH3" "$OUTDIR/l3b.log" "$WOLFBOOT_DG_ELF_LINUX"
if wait_pattern "$OUTDIR/l3b.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3: unconfirmed v2 booted once (TESTING)"
else
    fail "L3: v2 did not boot (see $OUTDIR/l3b.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l3b.log" \
    && ok "L3: v2 image loaded on the TESTING boot (ver 0x2 in the boot log)" \
    || fail "L3: v2 not selected on the TESTING boot (see $OUTDIR/l3b.log)"
# Reboot again: this build erases the UPDATE partition and boots v1.
# "ver 0x1" in the log shows v1 was picked.
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
# The failed update must be erased. Check after stop_qemu: QEMU saves
# the flash file only when it stops.
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
# The whole UPDATE partition (0x49C0000-0x75C0000, trailer included)
# must be 0xFF: wolfBoot_erase_partition() erases all of it.
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
# L3b uses the default config (ALLOW_DOWNGRADE=0). An unconfirmed newer
# version is NOT rolled back: wolfBoot prints "Rollback to lower version
# not allowed" and boots v2 again (src/libwolfboot.c; checked with GDB).
log "L3b: default config (ALLOW_DOWNGRADE=0): unconfirmed higher version \
is not rolled back"
echo "  NOTE: L3b uses the NORMAL Linux wolfBoot (ALLOW_DOWNGRADE=0" \
     "default;"
echo "        L3 above is the rollback scenario with an" \
     "ALLOW_DOWNGRADE=1 build)."
FLASH3B="$OUTDIR/linux_flash_l3b.bin"
make_linux_flash "$FLASH3B" "$BUILD/fit_v1_signed.bin" "-"
start_qemu "$FLASH3B" "$OUTDIR/l3ba.log" || {
    fail "L3b: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l3ba.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3b: v1 booted (fresh flash)"
else
    fail "L3b: v1 did not boot (see $OUTDIR/l3ba.log)"
fi
send "wbmtd update /v2.fit"
if wait_pattern "$OUTDIR/l3ba.log" \
    "UPDATE partition state set to UPDATING" "$UPD_WAIT"; then
    ok "L3b: v2 written to UPDATE (UPDATING), NOT confirmed"
else
    fail "L3b: wbmtd update failed (see $OUTDIR/l3ba.log)"
fi
# Reboot: v2 boots (TESTING); it is not confirmed
reboot_qemu "$FLASH3B" "$OUTDIR/l3bb.log"
if wait_pattern "$OUTDIR/l3bb.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3b: unconfirmed v2 booted once (TESTING)"
else
    fail "L3b: v2 did not boot (see $OUTDIR/l3bb.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l3bb.log" \
    && ok "L3b: v2 image loaded on the TESTING boot (ver 0x2 in the boot \
log)" \
    || fail "L3b: v2 not selected on the TESTING boot (see \
$OUTDIR/l3bb.log)"
# Reboot again: the default config still boots the UPDATE image
reboot_qemu "$FLASH3B" "$OUTDIR/l3bc.log"
if wait_pattern "$OUTDIR/l3bc.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L3b: system boots again after the unconfirmed v2"
else
    fail "L3b: no boot after the unconfirmed v2 (see $OUTDIR/l3bc.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l3bc.log" \
    && ok "L3b: unconfirmed v2 boots again (ALLOW_DOWNGRADE=0: no rollback \
to lower v1)" \
    || fail "L3b: unexpected selection on the post-TESTING boot (see \
$OUTDIR/l3bc.log)"
send "wbmtd state"
if wait_pattern "$OUTDIR/l3bc.log" "UPDATE: state=TESTING" "$BOOT_WAIT"; then
    ok "L3b: guest confirms the UPDATE trailer still TESTING (update \
pending, not erased)"
else
    fail "L3b: UPDATE trailer state wrong after the post-TESTING boot (see \
$OUTDIR/l3bc.log)"
fi
stop_qemu
# The UPDATE image must still be there (no rollback ran). Check after
# stop_qemu: QEMU saves the flash file only when it stops.
if python3 - "$FLASH3B" "$BUILD/fit_v2_signed.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
v = open(sys.argv[2], 'rb').read()[:0x1000]
# Compare the first 4 KB of the UPDATE partition
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
start_qemu "$FLASH4" "$OUTDIR/l4a.log" || {
    fail "L4: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l4a.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L4: v1 booted (fresh flash)"
else
    fail "L4: v1 did not boot (see $OUTDIR/l4a.log)"
fi
send "wbmtd update /v2.fit --corrupt-sig"
if wait_pattern "$OUTDIR/l4a.log" "UPDATE partition state set to UPDATING" \
    "$UPD_WAIT"; then
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
grep -qE "Verifying signature\.\.\.FAILED|integrity\.\.\.FAILED" \
    "$OUTDIR/l4b.log" \
    && ok "L4: UPDATE image refused (signature/integrity FAILED)" \
    || fail "L4: corrupted update was not refused"
# "Trying Boot partition" is not in the log (see L2). "ver 0x1" shows
# that v1 was picked.
grep -q "ver 0x1, type 0x601" "$OUTDIR/l4b.log" \
    && ok "L4: fell back to the Boot partition (v1 image loaded)" \
    || fail "L4: Boot partition not selected"
stop_qemu

# ============================================================================
# L5: an older signed v1 is offered in UPDATE, v2 is confirmed in BOOT.
# wolfBoot only picks UPDATE if it is newer (src/libwolfboot.c:2562-2564),
# so v2 boots with both settings. The host writes v1 (see L5c for wbmtd).
log "L5: D2 older update offered (v2 BOOT SUCCESS, v1 UPDATE UPDATING) - \
both settings"
echo "  NOTE: L5a runs the default (ALLOW_DOWNGRADE=0) build; L5b runs the"
echo "        ALLOW_DOWNGRADE=1 build (the same build L3 above built with"
echo "        'make ... ALLOW_DOWNGRADE=1'). v2 (BOOT) must boot in both;" \
     "the"
echo "        older v1 in UPDATE must be ignored."

# L5a uses the default build, L5b the ALLOW_DOWNGRADE=1 build from L3.
# Check both builds again first.
if probe_linux_elf; then
    ok "L5 identity: default (ALLOW_DOWNGRADE=0) build verified (Linux \
config, nm versal2_dma + meta)"
else
    fail "L5 identity: default build is not the verified Linux-config \
build - L5 will NOT run"
    exit 1
fi
if [ -f "$WOLFBOOT_DG_ELF_LINUX" ] && [ -f "$WOLFBOOT_DG_ELF_LINUX.meta" ] \
   && [ "$(cat "$WOLFBOOT_DG_ELF_LINUX.meta" 2>/dev/null)" = \
        "$(wb_cfg_meta)" ]; then
    ok "L5 identity: ALLOW_DOWNGRADE=1 build verified (config + partition \
meta match; built with make ALLOW_DOWNGRADE=1 as in L3)"
else
    fail "L5 identity: the ALLOW_DOWNGRADE=1 build is missing or its meta \
mismatches - L5 will NOT run"
    exit 1
fi

# Flash: v2 in BOOT (SUCCESS), the 29 MB signed v1 in UPDATE (UPDATING)
FLASH5="$OUTDIR/linux_flash_l5.bin"
make_linux_flash "$FLASH5" "$BUILD/fit_v2_signed.bin" \
    "$BUILD/fit_v1_signed.bin"
python3 - "$FLASH5" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read())
MAGIC = bytes([0x42,0x4F,0x4F,0x54])
BOOT_END = 0x1dc0000 + 0x2c00000   # 0x49C0000 (end of the BOOT partition)
UPD_END  = 0x49c0000 + 0x2c00000   # 0x75C0000 (end of the UPDATE partition)
# Trailer: state byte at END-5, magic at END-4 (get_trailer_at).
# SUCCESS=0x00, UPDATING=0x70 (include/wolfboot/wolfboot.h:674,685).
d[BOOT_END-5] = 0x00
d[BOOT_END-4:BOOT_END] = MAGIC
d[UPD_END-5]  = 0x70
d[UPD_END-4:UPD_END]  = MAGIC
open(sys.argv[1],'wb').write(d)
PY

# L5a: the default build (ALLOW_DOWNGRADE=0) must boot v2
start_qemu "$FLASH5" "$OUTDIR/l5a.log" || {
    fail "L5a: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l5a.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5a(=0): v2 booted (the confirmed Boot image)"
else
    fail "L5a(=0): v2 did not boot (see $OUTDIR/l5a.log)"
fi
# "ver 0x2" shows v2 was picked (see L2). The older v1 must not be.
grep -q "ver 0x2, type 0x601" "$OUTDIR/l5a.log" \
    && ok "L5a(=0): the higher v2 (Boot) is selected; the older v1 update \
is ignored" \
    || fail "L5a(=0): v2 not selected (see $OUTDIR/l5a.log)"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l5a.log" \
    && fail "L5a(=0): the older v1 (UPDATE) was selected (unexpected \
downgrade)" \
    || ok "L5a(=0): the older v1 (UPDATE) was not selected"
stop_qemu

# L5b: the ALLOW_DOWNGRADE=1 build must also boot v2
start_qemu "$FLASH5" "$OUTDIR/l5b.log" "$WOLFBOOT_DG_ELF_LINUX" || {
    fail "L5b: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l5b.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5b(=1): v2 booted with the ALLOW_DOWNGRADE=1 build"
else
    fail "L5b(=1): v2 did not boot (see $OUTDIR/l5b.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l5b.log" \
    && ok "L5b(=1): the higher v2 (Boot) is selected even with \
ALLOW_DOWNGRADE=1" \
    || fail "L5b(=1): v2 not selected (see $OUTDIR/l5b.log)"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l5b.log" \
    && fail "L5b(=1): the older v1 (UPDATE) was selected (unexpected \
downgrade)" \
    || ok "L5b(=1): the older v1 (UPDATE) was not selected"
stop_qemu

# ============================================================================
# L5c: same as L5, but the running v2 guest writes the older v1c to
# UPDATE with `wbmtd update /v1c.fit`. v2 must boot with both builds.
# v1c is a small signed v1, so v2c fits in the 44 MB partition.
log "L5c: D2 through the real update path (the v2 guest writes v1c with \
wbmtd update) - both settings"
echo "  NOTE: L5c-a runs the default (ALLOW_DOWNGRADE=0) build; L5c-b runs" \
     "the"
echo "        ALLOW_DOWNGRADE=1 build (the same build L3 above built with"
echo "        make ALLOW_DOWNGRADE=1). The lower v1c is written to UPDATE" \
     "by the"
echo "        RUNNING v2c guest (the real update path); v2 (BOOT) must boot in"
echo "        both; the older v1c in UPDATE must be ignored. (L5 above keeps"
echo "        the host-dd variant as it is.)"

# L5c-a uses the default build, L5c-b the ALLOW_DOWNGRADE=1 build from
# L3. Check both builds again first.
if probe_linux_elf; then
    ok "L5c identity: default (ALLOW_DOWNGRADE=0) build verified (Linux \
config, nm versal2_dma + meta)"
else
    fail "L5c identity: default build is not the verified Linux-config \
build - L5c will NOT run"
    exit 1
fi
if [ -f "$WOLFBOOT_DG_ELF_LINUX" ] && [ -f "$WOLFBOOT_DG_ELF_LINUX.meta" ] \
   && [ "$(cat "$WOLFBOOT_DG_ELF_LINUX.meta" 2>/dev/null)" = \
        "$(wb_cfg_meta)" ]; then
    ok "L5c identity: ALLOW_DOWNGRADE=1 build verified (config + partition \
meta match; built with make ALLOW_DOWNGRADE=1 as in L3)"
else
    fail "L5c identity: the ALLOW_DOWNGRADE=1 build is missing or its meta \
mismatches - L5c will NOT run"
    exit 1
fi

# Flash: v2c in BOOT (SUCCESS), UPDATE empty. The v2c guest has /v1c.fit.
FLASH5C="$OUTDIR/linux_flash_l5c.bin"
make_linux_flash "$FLASH5C" "$BUILD/fit_v2c_signed.bin" "-"
python3 - "$FLASH5C" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read())
MAGIC = bytes([0x42,0x4F,0x4F,0x54])
BOOT_END = 0x1dc0000 + 0x2c00000   # 0x49C0000 (end of the BOOT partition)
# Trailer as in L5 above. SUCCESS=0x00.
d[BOOT_END-5] = 0x00
d[BOOT_END-4:BOOT_END] = MAGIC
open(sys.argv[1],'wb').write(d)
PY

# Initial boot: v2c (ver 0x2) from BOOT
start_qemu "$FLASH5C" "$OUTDIR/l5c0.log" || {
    fail "L5c: QEMU start"; stop_qemu; exit 1; }
if wait_pattern "$OUTDIR/l5c0.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5c: v2c booted from BOOT (the real-update-path D2 start state)"
else
    fail "L5c: v2c did not boot (see $OUTDIR/l5c0.log)"
fi
# The v2c guest writes v1c to UPDATE with its own MTD driver
send "wbmtd update /v1c.fit"
if wait_pattern "$OUTDIR/l5c0.log" \
    "UPDATE partition state set to UPDATING" "$UPD_WAIT"; then
    ok "L5c: the v2 guest wrote v1c to UPDATE via wbmtd (real update path; \
trailer UPDATING)"
else
    fail "L5c: wbmtd update /v1c.fit failed in the v2 guest (see \
$OUTDIR/l5c0.log)"
fi

# L5c-a: reboot with the default build; v2 must boot
reboot_qemu "$FLASH5C" "$OUTDIR/l5ca.log"
if wait_pattern "$OUTDIR/l5ca.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5c(=0): v2 booted after the guest-written v1 update (the \
confirmed Boot image)"
else
    fail "L5c(=0): v2 did not boot (see $OUTDIR/l5ca.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l5ca.log" \
    && ok "L5c(=0): the higher v2 (Boot) is selected; the older v1c \
update is ignored" \
    || fail "L5c(=0): v2 not selected (see $OUTDIR/l5ca.log)"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l5ca.log" \
    && fail "L5c(=0): the older v1c (UPDATE) was selected (unexpected \
downgrade)" \
    || ok "L5c(=0): the older v1c (UPDATE) was not selected"

# L5c-b: reboot with the ALLOW_DOWNGRADE=1 build; v2 must boot
reboot_qemu "$FLASH5C" "$OUTDIR/l5cb.log" "$WOLFBOOT_DG_ELF_LINUX"
if wait_pattern "$OUTDIR/l5cb.log" "$BANNER" "$BOOT_WAIT"; then
    ok "L5c(=1): v2 booted with the ALLOW_DOWNGRADE=1 build"
else
    fail "L5c(=1): v2 did not boot (see $OUTDIR/l5cb.log)"
fi
grep -q "ver 0x2, type 0x601" "$OUTDIR/l5cb.log" \
    && ok "L5c(=1): the higher v2 (Boot) is selected even with \
ALLOW_DOWNGRADE=1" \
    || fail "L5c(=1): v2 not selected (see $OUTDIR/l5cb.log)"
grep -q "ver 0x1, type 0x601" "$OUTDIR/l5cb.log" \
    && fail "L5c(=1): the older v1c (UPDATE) was selected (unexpected \
downgrade)" \
    || ok "L5c(=1): the older v1c (UPDATE) was not selected"
stop_qemu
# UPDATE must hold the v1c the guest wrote (first 4 KB). This proves the
# wbmtd write really happened.
if python3 - "$FLASH5C" "$BUILD/fit_v1c_signed.bin" <<'PY'
import sys
d = open(sys.argv[1],'rb').read()
v = open(sys.argv[2],'rb').read()[:0x1000]
sys.exit(0 if d[0x49C0000:0x49C1000] == v else 1)
PY
then
    ok "L5c: the UPDATE partition contains the v1c image written by the \
guest (real update path, not a host dd)"
else
    fail "L5c: the UPDATE partition does not match the v1c FIT (the wbmtd \
write did not land)"
fi

# --- summary ----------------------------------------------------------------
echo
echo "==========================================="
echo " Local Linux test (QEMU, not CI): PASS=$PASS FAIL=$FAIL"
echo "==========================================="
[ "$FAIL" -eq 0 ] && echo "ALL LINUX TESTS PASSED" || \
    echo "SOME LINUX TESTS FAILED"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
