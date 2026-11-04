#!/usr/bin/env python3
"""Reject a local memory runtime missing the shared reset/reclaim fix."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    requirements = json.loads((ROOT / "memory/requirements.json").read_text())
    native = args.app.resolve(strict=True) / "Contents/Resources/Native3D"
    manifest = json.loads((native / "runtime.json").read_text())
    if (manifest.get("hvf_dynamic_memory_version") != requirements["hvfDynamicMemoryVersion"]
            or manifest.get("hvf_memory_quiesce_version") != requirements["hvfMemoryQuiesceVersion"]):
        raise ValueError("Local QEMU lacks the shared memory/reset fix; rebuild and package the compatible memory runtime")
    expected = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                for name in requirements["requiredPatches"]}
    if manifest.get("memory_quiesce_patches") != expected:
        raise ValueError("Local QEMU memory recipe differs from the shared requirements")
    name = "bin/qemu-system-aarch64"
    binary = (native / name).read_bytes()
    if hashlib.sha256(binary).hexdigest() != manifest["files"][name]:
        raise ValueError("Packaged memory QEMU hash differs")
    if b"perp-quiesce-stats\0" not in binary:
        raise ValueError("QEMU lacks the live quiesce capability; stale manifest metadata cannot qualify it")
    print("Memory: nonblocking quiesce recipe, capability and QEMU hash verified")


if __name__ == "__main__":
    main()
