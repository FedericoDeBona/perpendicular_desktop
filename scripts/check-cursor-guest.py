#!/usr/bin/env python3
"""Require the ARM64 guest with the Desktop Mode pointer compositor fix."""

import argparse
from pathlib import Path
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exe", type=Path)
    args = parser.parse_args()
    try:
        data = args.exe.read_bytes()
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        arm64 = data[:2] == b"MZ" and data[pe:pe + 6] == b"PE\0\0\x64\xaa"
    except (OSError, struct.error) as error:
        parser.exit(1, f"Cannot inspect the Windows guest: {error}\n")
    if not arm64 or b"desktopCursorCompositorRefresh" not in data:
        parser.exit(1, "Rebuild the ARM64 guest with scripts/build-guest.sh for the Desktop Mode pointer fix.\n")
    print("Desktop Mode pointer compositor fix is present in the ARM64 guest.")


if __name__ == "__main__":
    main()
