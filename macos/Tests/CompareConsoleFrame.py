"""Compare exact console RGB bytes with an independent QEMU QMP screendump.

Example (read-only; no guest input or VM lifecycle command):
    python3 macos/Tests/CompareConsoleFrame.py /tmp/console.framebuffer.ppm \
        --qmp /tmp/.../qmp.sock --reference /tmp/qemu-reference.ppm

Use a static screen, since captures taken at different times can legitimately differ.
"""

import argparse
import json
from pathlib import Path
import socket


def read_ppm(path):
    data = path.read_bytes()
    offset = 0
    tokens = []
    whitespace = b" \r\n\t"
    while len(tokens) < 4:
        while offset < len(data) and data[offset] in whitespace:
            offset += 1
        if data[offset : offset + 1] == b"#":
            offset = data.index(b"\n", offset) + 1
            continue
        start = offset
        while offset < len(data) and data[offset] not in whitespace:
            offset += 1
        assert offset > start, "Incomplete PPM header"
        tokens.append(data[start:offset])
    magic, width, height, maximum = tokens
    assert magic == b"P6" and maximum == b"255", "Expected RGB888 binary PPM"
    width, height = int(width), int(height)
    # Consume exactly the header delimiter, not leading whitespace-valued pixels.
    offset += 2 if data[offset : offset + 2] == b"\r\n" else 1
    pixels = data[offset:]
    assert len(pixels) == width * height * 3, "Unexpected PPM payload length"
    return width, height, pixels


def qmp_screendump(qmp_path, reference):
    assert qmp_path.is_absolute() and reference.is_absolute(), "Use absolute socket/output paths"
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(qmp_path))
        with connection.makefile("rwb", buffering=0) as stream:
            json.loads(stream.readline())
            requests = [
                {"execute": "qmp_capabilities", "id": "console-capture-capabilities"},
                {"execute": "screendump", "arguments": {"filename": str(reference)},
                 "id": "console-capture-framebuffer"},
            ]
            for request in requests:
                stream.write((json.dumps(request) + "\n").encode())
                while True:
                    response = json.loads(stream.readline())
                    if response.get("id") == request["id"]:
                        assert "return" in response, response
                        break


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("console", type=Path, help="Exact .framebuffer.ppm from capture-console.sh")
parser.add_argument("--reference", type=Path, required=True, help="QEMU PPM reference path")
parser.add_argument("--qmp", type=Path, help="Optionally generate the reference with read-only screendump")
args = parser.parse_args()
if args.qmp:
    qmp_screendump(args.qmp, args.reference)
width, height, actual = read_ppm(args.console)
reference_width, reference_height, expected = read_ppm(args.reference)
assert (width, height) == (reference_width, reference_height), "Framebuffer dimensions differ"
different = sum(left != right for left, right in zip(actual, expected))
print(json.dumps({
    "width": width, "height": height, "rgb_bytes": len(actual),
    "different_rgb_bytes": different, "identical_fraction": 1 - different / len(actual),
    "guest_input_sent": False, "vm_lifecycle_commands_sent": False,
    "console_ppm": str(args.console), "reference_ppm": str(args.reference),
}, indent=2))
raise SystemExit(1 if different else 0)
