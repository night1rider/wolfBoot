#!/bin/bash
#
# mk_dtb.sh - Generate the guest kernel DTB for the versal2 QEMU local
# Linux test, in QEMU's amd-versal2-virt.
#
# Start from QEMU's own DTB (dumpdtb) and apply a small overlay
# (ospi-overlay.dts) that adds only:
#   - /chosen/bootargs (console on the UART wolfBoot uses, earlycon,
#     maxcpus=1) and /chosen/stdout-path (UART1);
#   - the OSPI flash controller node (compatible "cdns,qspi-nor",
#     "qemu,xlnx-versal-ospi-nor" - the board's "amd,versal2-ospi"
#     string is dropped for QEMU, see the ospi-overlay.dts header;
#     QEMU's dump has no node because the model has no FDT support)
#     with the fixed-partitions matching the wolfBoot config
#     (BOOT 0x1DC0000 / UPDATE 0x49C0000 / SWAP 0xFA40000, 44 MB each).
# The overlay's flash node references the 125 MHz base clock by phandle;
# QEMU's base clock nodes have no labels (so fdtoverlay cannot resolve a
# &label), hence the final `fdtput` step that patches `clocks` into the
# combined tree in binary form (fdtoverlay keeps the base tree's phandles
# stable, so the base clk125 phandle is valid after the overlay).
#
# The EDF DTB is NOT used (only for comparison); QEMU's DTB is
# authoritative for the QEMU machine.
#
# The output goes to a build dir OUTSIDE the repo by default (the DTB is
# a build artifact).
#
# Usage:
#   QEMU=/opt/build/qemu-11.1.3/build/qemu-system-aarch64 ./mk_dtb.sh
#   (override the output with OUT=/opt/build/wb-linux/kernel.dtb)
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU="${QEMU:-/opt/build/qemu-11.1.3/build/qemu-system-aarch64}"
# Default build dir outside the repo (kept in sync with mk_fit.sh).
BUILD="${BUILD:-/opt/build/wb-linux}"
OUT="${OUT:-$BUILD/kernel.dtb}"

[ -x "$QEMU" ] || { echo "QEMU not found at $QEMU"; exit 2; }
command -v dtc >/dev/null || { echo "dtc not found"; exit 2; }
command -v fdtoverlay >/dev/null || { echo "fdtoverlay not found"; exit 2; }
command -v fdtput >/dev/null || { echo "fdtput not found (libfdt)"; exit 2; }
command -v fdtget >/dev/null || { echo "fdtget not found (libfdt)"; exit 2; }

mkdir -p "$BUILD"
WORK="$(mktemp -d /tmp/dtb.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# 1. Dump QEMU's own DTB for the machine the tests boot. In QEMU 11.1.3,
#    dumpdtb is a machine option, not a top-level option.
"$QEMU" \
    -M amd-versal2-virt,ospi-flash=mt35xu02gbba,dumpdtb="$WORK/base.dtb" \
    -m 4G >/dev/null 2>&1 || true
[ -s "$WORK/base.dtb" ] || { echo "dumpdtb failed"; exit 3; }

# 2. Get the phandle of the 125 MHz clock. It is the OSPI "ref" clock,
#    the same one the PL011 UART uses.
CLK_PH="$(fdtget "$WORK/base.dtb" /clk125 phandle)" \
    || { echo "base DTB has no /clk125 node"; exit 4; }
[ -n "$CLK_PH" ] || { echo "no phandle for /clk125"; exit 4; }

# 3. Compile the overlay, with the symbol info fdtoverlay needs (-@).
dtc -I dts -O dtb -@ -o "$WORK/overlay.dtbo" "$HERE/ospi-overlay.dts" \
    >"$WORK/overlay.dts.decompiled" 2>"$WORK/dtc.err" || {
    echo "overlay compile failed:"; cat "$WORK/dtc.err"; exit 5; }

# 4. Apply the overlay to QEMU's base DTB.
fdtoverlay -i "$WORK/base.dtb" -o "$OUT" "$WORK/overlay.dtbo"
[ -s "$OUT" ] || { echo "fdtoverlay failed"; exit 6; }

# 5. Set the OSPI clocks property here. The base clock node has no label,
#    so the overlay cannot point to it.
fdtput "$OUT" /qspi@f1010000 clocks "$CLK_PH"

# 5b. The Linux driver needs fifo-width and trigger-address, or probe
#     fails. fifo-depth 256 matches the VEK385 DTB and the QEMU model.
#     ospi-clk-freq-hz is the VEK385 value; Linux does not use it.
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000 \
    "cdns,fifo-width" 4
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000 \
    "cdns,trigger-address" 0xc0000000
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000 \
    "cdns,fifo-depth" 256
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000 \
    "xlnx,ospi-clk-freq-hz" 199998001

# 5c. Flash timing values the Linux driver needs. Without read-delay the
#     probe fails ("couldn't determine read-delay"). Values are copied
#     from the VEK385 DTB.
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000/flash@0 \
    "cdns,read-delay" 0
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000/flash@0 \
    "cdns,tshsl-ns" 0
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000/flash@0 \
    "cdns,tsd2d-ns" 0
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000/flash@0 \
    "cdns,tchsh-ns" 1
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000/flash@0 \
    "cdns,tslch-ns" 1

# 6. Set compatible to the generic "cdns,qspi-nor". The board string
#    "amd,versal2-ospi" needs firmware calls and DQS tuning QEMU can't do
#    (ospi-overlay.dts header). The second string matches no driver.
python3 "$HERE/fdt_setprop.py" "$OUT" /qspi@f1010000 compatible \
    "cdns,qspi-nor" "qemu,xlnx-versal-ospi-nor"

# 7. Check the final DTB has everything added above.
dtc -I dtb -O dts "$OUT" 2>/dev/null > "$WORK/final.dts"
COMPT="$(fdtget -t s "$OUT" /qspi@f1010000 compatible 2>/dev/null)" \
    || { echo "compatible property missing"; exit 7; }
[ "$COMPT" = "cdns,qspi-nor qemu,xlnx-versal-ospi-nor" ] \
    || { echo "compatible wrong: $COMPT"; exit 7; }
grep -q "jedec,spi-nor" "$WORK/final.dts" \
    || { echo "overlay did not add the flash child"; exit 7; }
grep -q "fixed-partitions" "$WORK/final.dts" \
    || { echo "overlay did not add the fixed-partitions node"; exit 7; }
grep -q "bootargs" "$WORK/final.dts" \
    || { echo "overlay did not set /chosen/bootargs"; exit 8; }
C="$(fdtget "$OUT" /qspi@f1010000 clocks 2>/dev/null)" \
    || { echo "clocks patch missing"; exit 9; }
[ "$C" = "$CLK_PH" ] || { echo "clocks phandle wrong: $C"; exit 9; }
FW="$(fdtget -t x "$OUT" /qspi@f1010000 "cdns,fifo-width" 2>/dev/null)" \
    || { echo "cdns,fifo-width missing"; exit 9; }
TA="$(fdtget -t x "$OUT" /qspi@f1010000 "cdns,trigger-address" \
    2>/dev/null)" || { echo "cdns,trigger-address missing"; exit 9; }
FD="$(fdtget -t x "$OUT" /qspi@f1010000 "cdns,fifo-depth" 2>/dev/null)" \
    || { echo "cdns,fifo-depth missing"; exit 9; }
RD="$(fdtget -t x "$OUT" /qspi@f1010000/flash@0 "cdns,read-delay" \
    2>/dev/null)" || { echo "cdns,read-delay missing"; exit 9; }
CMPT="$(fdtget -t s "$OUT" /firmware compatible 2>/dev/null)" \
    || { echo "/firmware node missing"; exit 9; }
CMETH="$(fdtget -t s "$OUT" /firmware method 2>/dev/null)" \
    || { echo "/firmware method missing"; exit 9; }
# (fdtget -t x prints bare hex, no 0x prefix)
[ "$FW" = "4" ] || { echo "cdns,fifo-width wrong: $FW"; exit 9; }
[ "$TA" = "c0000000" ] \
    || { echo "cdns,trigger-address wrong: $TA"; exit 9; }
[ "$FD" = "100" ] || { echo "cdns,fifo-depth wrong: $FD"; exit 9; }
[ "$RD" = "0" ] || { echo "cdns,read-delay wrong: $RD"; exit 9; }
[ "$CMPT" = "xlnx,versal2-firmware" ] \
    || { echo "/firmware compatible wrong: $CMPT"; exit 9; }
[ "$CMETH" = "smc" ] || { echo "/firmware method wrong: $CMETH"; exit 9; }

echo "guest DTB: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  (qemu base + ospi controller (cdns,qspi-nor)"
echo "   + jedec,spi-nor flash + fixed-partitions + clocks=clk125"
echo "   + cdns,fifo-width/trigger-address/fifo-depth(256)"
echo "   + flash cdns,read-delay/tshsl/tsd2d/tchsh/tslch (VEK385)"
echo "   + /firmware xlnx,versal2-firmware (smc) + bootargs)"
echo "DTB-OK"
