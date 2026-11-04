#!/usr/bin/env python3
"""Reject a stale generated Windows guest before packaging a new Mac build."""
import argparse
import json
from pathlib import Path
import struct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--guest", type=Path, required=True)
options = parser.parse_args()
requirements = json.loads((Path(__file__).resolve().parent.parent / "guest/requirements.json").read_text())
data = options.guest.read_bytes()
try:
    offset = struct.unpack_from("<I", data, 0x3c)[0]
    arm64 = data[:2] == b"MZ" and data[offset:offset + 4] == b"PE\0\0" and struct.unpack_from("<H", data, offset + 4)[0] == 0xaa64
except struct.error:
    arm64 = False
missing = [marker for marker in requirements["requiredMarkers"] if marker.encode("ascii") not in data]
if not arm64 or missing:
    parser.exit(1, "Guest payload lacks the required ARM64 discovery fix; rebuild with scripts/build-guest.sh.\n")
print("Guest ARM64: required scoped window discovery present; verify the installed Windows component separately")
