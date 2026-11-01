#!/usr/bin/env python3
"""Set a property in a DTB, in place (multi-string or 32-bit cells).

Why this exists: the system dtc 1.7.2 (Debian) cannot parse multi-string
property values in DTS source (even `model = "a" "b";` is a syntax error),
cannot parse property names containing commas (quoted or not), and its
fdtput joins string arguments into one string / mangles 32-bit values
above INT32_MAX. The Linux device tree for the Cadence OSPI controller
(AMD VEK385 DTB, /axi/spi@f1010000) requires
    compatible = "amd,versal2-ospi" "cdns,qspi-nor";
    cdns,trigger-address = <0xc0000000>;
so mk_dtb.sh compiles the overlay without those properties and rewrites
them in the combined binary tree here, via libfdt's fdt_setprop().

Usage: fdt_setprop.py <dtb> <node> <property> <value> [<value>...]
       fdt_setprop.py --cells <dtb> <node> <property> <u32> [<u32>...]

Without --cells the values are strings (NUL-terminated sequence);
with --cells they are 32-bit big-endian cells (decimal or 0x hex).
"""
import ctypes
import struct
import sys


def main():
    args = sys.argv[1:]
    cells = False
    if args and args[0] == "--cells":
        cells = True
        args = args[1:]
    if len(args) < 4:
        sys.exit(__doc__)
    path, node, prop = args[0], args[1], args[2]
    values = args[3:]

    fdt = ctypes.CDLL("libfdt.so.1")
    data = bytearray(open(path, "rb").read())
    # fdt_setprop() must be able to grow the tree in place, so the scratch
    # buffer needs slack beyond the current tree size (a tight buffer makes
    # the set fail with FDT_ERR_NOTFOUND).
    slack = 65536
    ptr = ctypes.create_string_buffer(bytes(data), len(data) + slack)
    rc = fdt.fdt_open_into(ptr, ptr, len(data) + slack)
    if rc != 0:
        sys.exit(f"fdt_open_into: {rc}")
    off = fdt.fdt_path_offset(ptr, node.encode())
    if off < 0:
        sys.exit(f"node {node}: libfdt error {off}")
    if cells:
        # A cell property is a sequence of big-endian u32.
        val = b"".join(struct.pack(">I", int(v, 0) & 0xFFFFFFFF) for v in values)
        shown = " ".join(str(int(v, 0) & 0xFFFFFFFF) for v in values)
    else:
        # A string property is a sequence of NUL-terminated strings.
        val = b"".join(s.encode() + b"\x00" for s in values)
        shown = " ".join(values)
    rc = fdt.fdt_setprop(ptr, off, prop.encode(), val, len(val))
    if rc != 0:
        sys.exit(f"fdt_setprop: {rc}")
    # fdt_totalsize() is a macro (header field at offset 4, big-endian);
    # the tree may have grown, so write back the (larger) head of the
    # scratch buffer.
    size = struct.unpack_from(">I", bytes(ptr), 4)[0]
    with open(path, "wb") as f:
        f.write(bytes(ptr[:size]))
    print(f"fdt_setprop: {node} {prop} = {shown}")


if __name__ == "__main__":
    main()
