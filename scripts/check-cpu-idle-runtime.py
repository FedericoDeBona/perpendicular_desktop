#!/usr/bin/env python3
"""Reject a local runtime missing the shared, leased idle waiting feature."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    required = json.loads((ROOT / "cpu/requirements.json").read_text())
    native = args.app.resolve(strict=True) / "Contents/Resources/Native3D"
    manifest = json.loads((native / "runtime.json").read_text())
    value = manifest.get("hvf_idle_wfi", {})
    for key, authority in (("version", "hvfIdleWFIVersion"),
                           ("idleBusyNanoseconds", "idleBusyNanoseconds"),
                           ("interactiveBusyNanoseconds", "interactiveBusyNanoseconds"),
                           ("leaseSeconds", "leaseSeconds")):
        if value.get(key) != required[authority]:
            raise ValueError("Local QEMU lacks leased idle WFI support; build/package the compatible local recipe in cpu/README.md")
    patches = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
               for name in required["requiredPatches"]}
    if value.get("patches") != patches:
        raise ValueError("Local QEMU idle WFI recipe differs from shared requirements")
    name = "bin/qemu-system-aarch64"
    binary = (native / name).read_bytes()
    if hashlib.sha256(binary).hexdigest() != manifest["files"][name]:
        raise ValueError("Packaged idle WFI QEMU hash differs")
    if any(marker not in binary for marker in (b"perp-idle-wfi\0", b"perp-idle-wfi-stats\0")):
        raise ValueError("QEMU lacks idle WFI properties; stale metadata cannot qualify it")
    print("CPU idle: leased WFI recipe, capabilities and QEMU hash verified")


if __name__ == "__main__":
    main()
