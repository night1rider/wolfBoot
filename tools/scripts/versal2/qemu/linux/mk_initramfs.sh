#!/bin/bash
#
# mk_initramfs.sh - Build the small initramfs for the versal2 QEMU local
# Linux test: a busybox shell plus the Linux-side
# update tool (wbmtd) and the EDF mtd-utils, packed as a cpio.gz that the
# FIT (mk_fit.sh) carries as the kernel's initrd.
#
# Everything is produced from inputs passed as arguments (EDF WIC path,
# busybox .deb) into a build dir OUTSIDE the repo - no EDF files or
# anything extracted from the WIC is kept in the tree.
#
# Outputs (in $BUILD):
#   initramfs-plain.cpio.gz - the base initramfs (no embedded update
#                             image); used for the v2 FIT (mk_fit.sh)
#   initramfs.cpio.gz       - the full initramfs: the base plus
#                             $V2FIT as /v2.fit when V2FIT is set (used
#                             for the v1 FIT, so the guest can run
#                             `wbmtd update /v2.fit`)
#   (when V2FIT is unset the full output is a copy of the plain one)
#   initramfs-extra.cpio.gz - (only when EXTRA_FIT is set) the
#                             base initramfs plus $EXTRA_FIT installed at
#                             $EXTRA_FIT_NAME (default /v1c.fit); used for
#                             the L5c variant v2 FIT so the running v2
#                             guest can write the lower v1 with
#                             `wbmtd update /v1c.fit` (the real update
#                             path). Separate from V2FIT: the full 29 MB
#                             v1 FIT would make that v2 FIT ~44.3 MB and
#                             exceed the 44 MB partition budget.
#
# Contents (all aarch64):
#   /init                 - mounts /proc /sys /dev, drops to a shell
#   /bin/busybox +links   - Debian busybox-static (SHA256-verified when a
#                           .deb is given; static, no libc needed)
#   /usr/bin/wbmtd        - the update/confirm tool (static; reuses
#                           libwolfboot's trailer ops over /dev/mtdN)
#   /v2.fit               - the v2 signed FIT, only in the FULL initramfs
#   /sbin/{lsmtd,flash_erase,flash_eraseall,mtdinfo,mtd_debug,nanddump}
#                           - EDF rootfs mtd-utils (dynamic; need the libc)
#   /lib/ld-linux-aarch64.so.1, /usr/lib/libc.so.6
#                           - from the EDF rootfs, for the mtd-utils
#
# Usage:
#   EDF_WIC=/opt/build/edf/...wic.xz \
#   BB_DEB=/opt/build/debs/busybox-static_*.arm64.deb \
#   WBMTD=$BUILD/wbmtd.aarch64 \
#   V2FIT=$BUILD/fit_v2_signed.bin \
#   ./mk_initramfs.sh
#   (or BBOX=<busybox binary> + EDF_ROOT=<already-mounted rootfs>)
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${BUILD:-/opt/build/wb-linux}"
EDF_WIC_NAME="edf-platform-disk-image-amd-cortexa78-mali-common"
EDF_WIC_NAME="$EDF_WIC_NAME.rootfs-20260609231841.wic.xz"
EDF_WIC="${EDF_WIC:-/opt/build/edf/$EDF_WIC_NAME}"
EDF_ROOT="${EDF_ROOT:-/opt/build/edf/mnt/root}"
BBOX="${BBOX:-/opt/build/bb/usr/bin/busybox}"
BB_DEB="${BB_DEB:-/opt/build/debs/busybox-static_1.37.0-6+b9_arm64.deb}"
WBMTD="${WBMTD:-$BUILD/wbmtd.aarch64}"
V2FIT="${V2FIT:-}"
# L5c: an extra file embedded at a guest path (default
# /v1c.fit) in the separate initramfs-extra.cpio.gz output
EXTRA_FIT="${EXTRA_FIT:-}"
EXTRA_FIT_NAME="${EXTRA_FIT_NAME:-/v1c.fit}"
OUT_PLAIN="${OUT_PLAIN:-$BUILD/initramfs-plain.cpio.gz}"
OUT_FULL="${OUT_FULL:-$BUILD/initramfs.cpio.gz}"
OUT_EXTRA="${OUT_EXTRA:-$BUILD/initramfs-extra.cpio.gz}"

mkdir -p "$BUILD"

# --- busybox: take the binary, or extract it from the .deb -------------
if [ ! -f "$BBOX" ] && [ -f "$BB_DEB" ]; then
    EX="$(mktemp -d /tmp/bb.XXXXXX)"
    dpkg-deb -x "$BB_DEB" "$EX"
    BBOX="$EX/usr/bin/busybox"
    trap 'rm -rf "$EX"' EXIT
fi
[ -f "$BBOX" ] || {
    echo "busybox not found at $BBOX (or .deb $BB_DEB)"; exit 2; }
if [ -f "$BB_DEB" ]; then
    # log the .deb SHA256 - the input must be genuine
    want="$(sha256sum "$BB_DEB" | cut -d' ' -f1)"
    echo "  busybox .deb: $BB_DEB sha256=$want"
fi

[ -f "$WBMTD" ] || {
    echo "wbmtd not found at $WBMTD (make -C wbmtd guest OUT=$WBMTD)"
    exit 2; }

# --- EDF rootfs: mount it if needed (from the WIC) ----------------------
# The WIC has 3 GPT parts: 1 = boot (vfat), 2 = empty FAT32, 3 = ext4
# rootfs. Find part 3 and mount it read-only at $EDF_ROOT.
edf_mount() {
    # On any error, return 1. The caller then builds without mtd-utils,
    # which L1-L4 do not need.
    command -v sudo >/dev/null || {
        echo "sudo needed to mount the EDF rootfs"; return 1; }
    local raw="${1:-}"
    [ -e "$raw" ] || raw="${EDF_WIC%.xz}"
    if [ ! -e "$raw" ] && [ -e "$EDF_WIC" ]; then
        xz -dk -f "$EDF_WIC"
        raw="${EDF_WIC%.xz}"
    fi
    [ -e "$raw" ] || { echo "EDF WIC missing: $EDF_WIC"; return 1; }
    local skip count
    read -r skip count < <(python3 - "$raw" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb')
f.seek(512)
h = f.read(92 + 16*128)
if h[:8] != b'EFI PART':
    sys.exit(3)
entries_lba = struct.unpack('<Q', h[72:80])[0]
n = struct.unpack('<I', h[80:84])[0]
f.seek(entries_lba*512)
e = f.read(128*n)
for i in range(n):
    g = e[i*128:(i+1)*128]
    t = struct.unpack('<8I', g[:32])
    s, ssz = struct.unpack('<QQ', g[32:48])
    if all(x == 0 for x in t):
        continue
    # The rootfs is the big (> 1 GB) partition that is not the first one.
    if s > 0 and (ssz - s + 1) * 512 > 1073741824 and s != 64:
        print(s, ssz - s + 1)
        break
else:
    sys.exit(4)
PY
    )
    [ -n "${skip:-}" ] || {
        echo "no rootfs partition found in the WIC"; return 1; }
    local rawpart="$BUILD/edf-rootfs.part"
    if [ ! -e "$rawpart" ] || \
       [ "$(stat -c %s "$rawpart")" != "$(( count * 512 ))" ]; then
        dd if="$raw" of="$rawpart" bs=512 skip="$skip" count="$count" \
            status=none || return 1
    fi
    if mountpoint -q "$EDF_ROOT" 2>/dev/null; then
        echo "  EDF rootfs already mounted at $EDF_ROOT"
        return 0
    fi
    mkdir -p "$EDF_ROOT" || return 1
    local loop
    loop="$(sudo losetup -f --show "$rawpart")" || {
        echo "losetup failed"; return 1; }
    sudo mount -o ro "$loop" "$EDF_ROOT" || {
        sudo losetup -d "$loop" 2>/dev/null; echo "mount failed"; return 1; }
    echo "  mounted EDF rootfs partition" \
         "(sectors $skip..$((skip+count))) at $EDF_ROOT"
}
if [ -d "$EDF_ROOT" ] && [ -n "$(ls -A "$EDF_ROOT" 2>/dev/null)" ]; then
    # already extracted/mounted (e.g. by test_linux.sh)
    :
else
    edf_mount "$EDF_WIC" || true
fi
if [ -z "$(ls -A "$EDF_ROOT" 2>/dev/null)" ]; then
    echo "EDF rootfs empty/missing at $EDF_ROOT; mtd-utils will be skipped"
    EDF_ROOT=""
fi

# --- assemble the initramfs --------------------------------------------
ROOT="$(mktemp -d /tmp/initramfs.XXXXXX)"
add_edf=0
[ -n "${EDF_ROOT:-}" ] && add_edf=1

pack() {
    # pack <cpio-out> [any 2nd arg]: with a 2nd arg, also add /v2.fit
    local out="$1" extra="${2:-}"
    if [ -n "$extra" ]; then
        install -m 755 "$V2FIT" "$ROOT/v2.fit"
    fi
    ( cd "$ROOT" && find . -print0 | \
        cpio --null -o -H newc 2>/dev/null | gzip -9 > "$out" )
    rm -f "$ROOT/v2.fit"
    echo "initramfs: $out ($(du -h "$out" | cut -f1))"
}
pack_extra() {
    # L5c: pack_extra <cpio-out>: the plain files plus $EXTRA_FIT at
    # $EXTRA_FIT_NAME. Used only for initramfs-extra.cpio.gz.
    local out="$1"
    install -m 755 "$EXTRA_FIT" "$ROOT/${EXTRA_FIT_NAME#/}"
    ( cd "$ROOT" && find . -print0 | \
        cpio --null -o -H newc 2>/dev/null | gzip -9 > "$out" )
    rm -f "$ROOT/${EXTRA_FIT_NAME#/}"
    echo "initramfs: $out ($(du -h "$out" | cut -f1))"
}

rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,sbin,usr/bin,usr/lib,lib,proc,sys,dev,etc}

# --- /init ----------------------------------------------------------------
cat > "$ROOT/init" <<'EOF'
#!/bin/sh
# wolfBoot versal2 QEMU local Linux test - initramfs init.
# The initramfs is the root filesystem (no root= on the command line).
mount -t proc     none /proc 2>/dev/null
mount -t sysfs    none /sys  2>/dev/null
mount -t devtmpfs none /dev  2>/dev/null

echo
echo "==================================================="
echo " wolfBoot Q5 Linux test shell (aarch64, single CPU)"
echo "==================================================="
echo " Kernel config (SPI_CADENCE / MTD_SPI_NOR drivers):"
if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz 2>/dev/null | \
        grep -E "CONFIG_SPI_CADENCE_QUADSPI=|CONFIG_MTD_SPI_NOR=\
|CONFIG_SPI_CADENCE_OSPI=|CONFIG_MTD_SPI_NOR_DT=" || \
        echo "  (no CONFIG_SPI_CADENCE_QUADSPI/CONFIG_MTD_SPI_NOR lines)"
else
    echo "  (/proc/config.gz not available)"
fi
echo " MTD devices (the OSPI flash wolfBoot boots from):"
[ -r /proc/mtd ] && cat /proc/mtd
echo " MTD char devices:"
ls /dev/mtd* 2>/dev/null || echo "  (no /dev/mtd*)"
echo
echo " Tools: wbmtd (update/confirm), lsmtd, flash_erase, mtdinfo"
echo "   wbmtd state"
[ -f /v2.fit ] && echo "   wbmtd update /v2.fit"
[ -f /v1c.fit ] && echo "   wbmtd update /v1c.fit"
echo "   wbmtd confirm"
echo "==================================================="
exec /bin/sh
EOF
chmod 755 "$ROOT/init"

# --- busybox + applet symlinks -------------------------------------------
install -m 755 "$BBOX" "$ROOT/bin/busybox"
for a in sh ls cat echo mount umount reboot poweroff ps kill sleep \
         grep sed awk vi cp mv rm mkdir ln chmod sync readlink printf \
         dmesg free hexdump more head tail wc tr cut env id zcat; do
  ln -sf busybox "$ROOT/bin/$a"
done

# --- the update tool ------------------------------------------------------
install -m 755 "$WBMTD" "$ROOT/usr/bin/wbmtd"

# --- EDF mtd-utils + their libc (optional; skipped if the EDF is absent) -
# Where the tools and libc live depends on the EDF release, so look in
# each place. The tools need ld-linux-aarch64.so.1 and libc.so.6 in /lib.
if [ "$add_edf" -eq 1 ]; then
  for t in lsmtd flash_erase flash_eraseall mtdinfo mtd_debug nanddump; do
    for d in sbin usr/sbin usr/bin; do
      if [ -f "$EDF_ROOT/$d/$t" ]; then
        install -m 755 "$EDF_ROOT/$d/$t" "$ROOT/sbin/$t"; break
      fi
    done
  done
  for ld in lib/ld-linux-aarch64.so.1 usr/lib/ld-linux-aarch64.so.1; do
    [ -f "$EDF_ROOT/$ld" ] && \
        install -m 755 "$EDF_ROOT/$ld" "$ROOT/lib/ld-linux-aarch64.so.1" && \
        break
  done
  for lc in lib/libc.so.6 usr/lib/libc.so.6; do
    if [ -f "$EDF_ROOT/$lc" ]; then
      install -m 755 "$EDF_ROOT/$lc" "$ROOT/lib/libc.so.6"; break
    fi
  done
  echo "included EDF mtd-utils + libc from $EDF_ROOT"
else
  echo "EDF rootfs not available; skipping mtd-utils (wbmtd still works)"
fi

# --- pack (cpio newc, gzip): plain, then full (with /v2.fit if given) ----
pack "$OUT_PLAIN"
if [ -n "$V2FIT" ]; then
    [ -f "$V2FIT" ] || { echo "V2FIT missing: $V2FIT"; exit 15; }
    pack "$OUT_FULL" "$ROOT"
else
    cp "$OUT_PLAIN" "$OUT_FULL"
fi
# --- L5c: the extra-file initramfs (plain + $EXTRA_FIT) ------------------
if [ -n "$EXTRA_FIT" ]; then
    [ -f "$EXTRA_FIT" ] || { echo "EXTRA_FIT missing: $EXTRA_FIT"; exit 16; }
    pack_extra "$OUT_EXTRA"
fi
echo "INITRAMFS-OK"
