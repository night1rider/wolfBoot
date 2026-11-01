#!/bin/bash
#
# mk_dtb.sh - Generate the guest kernel DTB for the wolfBoot PR 1 "Local
# Linux test" (plan item Q5), in QEMU's amd-versal2-virt.
#
# Per the plan: prefer QEMU's own DTB (dumpdtb) and apply a small overlay
# (ospi-overlay.dts) that adds only:
#   - /chosen/bootargs (console on the UART wolfBoot uses, earlycon,
#     maxcpus=1) and /chosen/stdout-path (UART1);
#   - the OSPI flash controller node (Run 11: compatible
#     "cdns,qspi-nor", "qemu,xlnx-versal-ospi-nor" - the board's
#     "amd,versal2-ospi" string is dropped for QEMU, see the
#     ospi-overlay.dts header; QEMU's dump has no node because the
#     model has no FDT support)
#     with the fixed-partitions matching the wolfBoot config
#     (run-13 layout: BOOT 0x1DC0000 / UPDATE 0x49C0000 / SWAP 0xFA40000,
#     44 MB each; old run 3-12: BOOT 0x19C0000 / UPDATE 0x4600000).
# The overlay's flash node references the 125 MHz base clock by phandle;
# QEMU's base clock nodes have no labels (so fdtoverlay cannot resolve a
# &label), hence the final `fdtput` step that patches `clocks` into the
# combined tree in binary form (fdtoverlay keeps the base tree's phandles
# stable, so the base clk125 phandle is valid after the overlay).
#
# The EDF DTB is NOT used (only for comparison, per the plan); QEMU's
# DTB is authoritative for the QEMU machine.
#
# The output goes to a build dir OUTSIDE the repo by default (the DTB is
# a build artifact; see BUILD.md, Run 5/6).
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

# 1. QEMU's own DTB for the machine (the same machine the tests boot).
#    dumpdtb is a MACHINE property of amd-versal2-virt (not a top-level
#    option in QEMU 11.1.3).
"$QEMU" -M amd-versal2-virt,ospi-flash=mt35xu02gbba,dumpdtb="$WORK/base.dtb" \
    -m 4G >/dev/null 2>&1 || true
[ -s "$WORK/base.dtb" ] || { echo "dumpdtb failed"; exit 3; }

# 2. The 125 MHz fixed clock phandle in the base tree (the OSPI "ref"
#    clock; the same one the PL011 uses).
CLK_PH="$(fdtget "$WORK/base.dtb" /clk125 phandle)" \
    || { echo "base DTB has no /clk125 node"; exit 4; }
[ -n "$CLK_PH" ] || { echo "no phandle for /clk125"; exit 4; }

# 3. Compile the overlay (with phandle/plugin info for fdtoverlay).
dtc -I dts -O dtb -@ -o "$WORK/overlay.dtbo" "$HERE/ospi-overlay.dts" \
    >"$WORK/overlay.dts.decompiled" 2>"$WORK/dtc.err" || {
    echo "overlay compile failed:"; cat "$WORK/dtc.err"; exit 5; }

# 4. Apply the overlay to QEMU's base DTB.
fdtoverlay -i "$WORK/base.dtb" -o "$OUT" "$WORK/overlay.dtbo"
[ -s "$OUT" ] || { echo "fdtoverlay failed"; exit 6; }

# 5. Patch the OSPI controller's clocks property in place (the base clock
#    node has no label, so the overlay cannot carry a phandle reference).
fdtput "$OUT" /qspi@f1010000 clocks "$CLK_PH"

# 5b. Patch the controller properties the stock driver REQUIRES in
#     cqspi_of_get_pdata() (drivers/spi/spi-cadence-quadspi.c):
#       cdns,fifo-width       (no default: probe fails without it)
#       cdns,trigger-address  (no default: probe fails without it)
#     plus cdns,fifo-depth: set to 256, the VEK385 DTB value AND the value
#     the driver runtime-detects from the model's 8-bit SRAMPARTITION
#     register (hw/ssi/xlnx-versal-ospi.c SRAMPARTITION = 0x100). The
#     run-9 "FIFO depth (256) different from config (4)" warning came
#     from depth=4 here: the driver warns when cdns,fifo-depth disagrees
#     with the detected depth, and its indirect-read chunk math
#     (threshold + fifo_width) is sized from the configured depth.
#     xlnx,ospi-clk-freq-hz carries the VEK385 controller reference
#     frequency (199998001) for fidelity; the stock driver reads its
#     actual ref clock from the "ref" clock (clk125) and does not use
#     this property. The system dtc 1.7.2 cannot parse comma-containing
#     property names, so fdt_setprop.py writes them as 32-bit cells.
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000 \
    "cdns,fifo-width" 4
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000 \
    "cdns,trigger-address" 0xc0000000
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000 \
    "cdns,fifo-depth" 256
python3 "$HERE/fdt_setprop.py" --cells "$OUT" /qspi@f1010000 \
    "xlnx,ospi-clk-freq-hz" 199998001

# 5c. Patch the flash-node timing properties the stock driver REQUIRES in
#     cqspi_of_get_flash_pdata(): the run-9 "couldn't determine read-delay"
#     (+ "failed to setup flash parameters -6") came from the missing
#     cdns,read-delay; tshsl-ns / tsd2d-ns / tchsh-ns / tslch-ns are read
#     the same way and are used by the Versal delay-line/PHY tuning writes
#     (cqspi_delay()/cqspi_readdata_capture()) - register-only in QEMU.
#     Values are the exact VEK385 DTB ones (read-delay 0, tshsl-ns 0,
#     tsd2d-ns 0, tchsh-ns 1, tslch-ns 1).
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

# 6. Patch the controller's compatible. Run 11: the board string
#    "amd,versal2-ospi" is dropped for QEMU (see the ospi-overlay.dts
#    header, point 2): the stock driver would bind the versal2_ospi
#    platdata (EXTERNAL_DMA -> zynqmp firmware mux-select SMC, and
#    OCTAL hwcaps -> 8D-8D-8D periodic DQS tuning), both of which QEMU
#    cannot serve. "cdns,qspi-nor" (the generic Cadence platdata) is the
#    QEMU-compatible binding. The trailing "qemu,xlnx-versal-ospi-nor"
#    string is inert now that the QEMU-only kdrv module was removed in
#    Run 11 (kdrv/ + mk_kernel.sh deleted - the stock driver works in
#    QEMU, so the custom module is no longer needed); it is kept so the
#    DTB layout stays stable (the system dtc 1.7.2 cannot parse
#    multi-string properties in DTS source, so the overlay carries only
#    the first string and this fdt_setprop writes the full list).
#    Old (run 5-10) value, kept for reference:
#      python3 "$HERE/fdt_setprop.py" "$OUT" /qspi@f1010000 compatible \
#          "amd,versal2-ospi" "cdns,qspi-nor" "qemu,xlnx-versal-ospi-nor"
python3 "$HERE/fdt_setprop.py" "$OUT" /qspi@f1010000 compatible \
    "cdns,qspi-nor" "qemu,xlnx-versal-ospi-nor"

# 7. Sanity: the resulting DTB must contain the controller + flash +
#    partitions + bootargs + the clock reference + the compatible
#    list (generic Cadence string first, the inert legacy QEMU string
#    last; the old run-5-10 expectation is kept above in step 6).
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
C="$(fdtget "$OUT" /qspi@f1010000 clocks 2>/dev/null)" || { echo "clocks patch missing"; exit 9; }
[ "$C" = "$CLK_PH" ] || { echo "clocks phandle wrong: $C"; exit 9; }
FW="$(fdtget -t x "$OUT" /qspi@f1010000 "cdns,fifo-width" 2>/dev/null)" || { echo "cdns,fifo-width missing"; exit 9; }
TA="$(fdtget -t x "$OUT" /qspi@f1010000 "cdns,trigger-address" 2>/dev/null)" || { echo "cdns,trigger-address missing"; exit 9; }
FD="$(fdtget -t x "$OUT" /qspi@f1010000 "cdns,fifo-depth" 2>/dev/null)" || { echo "cdns,fifo-depth missing"; exit 9; }
RD="$(fdtget -t x "$OUT" /qspi@f1010000/flash@0 "cdns,read-delay" 2>/dev/null)" || { echo "cdns,read-delay missing"; exit 9; }
CMPT="$(fdtget -t s "$OUT" /firmware compatible 2>/dev/null)" || { echo "/firmware node missing"; exit 9; }
CMETH="$(fdtget -t s "$OUT" /firmware method 2>/dev/null)" || { echo "/firmware method missing"; exit 9; }
# (fdtget -t x prints bare hex, no 0x prefix)
[ "$FW" = "4" ] || { echo "cdns,fifo-width wrong: $FW"; exit 9; }
[ "$TA" = "c0000000" ] || { echo "cdns,trigger-address wrong: $TA"; exit 9; }
[ "$FD" = "100" ] || { echo "cdns,fifo-depth wrong: $FD"; exit 9; }
[ "$RD" = "0" ] || { echo "cdns,read-delay wrong: $RD"; exit 9; }
[ "$CMPT" = "xlnx,versal2-firmware" ] || { echo "/firmware compatible wrong: $CMPT"; exit 9; }
[ "$CMETH" = "smc" ] || { echo "/firmware method wrong: $CMETH"; exit 9; }

echo "guest DTB: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  (qemu base + ospi controller (cdns,qspi-nor - Run 11)"
echo "   + jedec,spi-nor flash + fixed-partitions + clocks=clk125"
echo "   + cdns,fifo-width/trigger-address/fifo-depth(256)"
echo "   + flash cdns,read-delay/tshsl/tsd2d/tchsh/tslch (VEK385)"
echo "   + /firmware xlnx,versal2-firmware (smc) + bootargs)"
echo "DTB-OK"
