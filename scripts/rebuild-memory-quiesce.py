#!/usr/bin/env python3
"""Rebuild just the qualified local QEMU with nonblocking memory callbacks.

Uses the installed reference's unsigned QEMU pin, backs up touched files, and
restores the cache bytes even on failure. No VM or installed bundle is changed.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ["scripts/patch-qemu-memory-quiesce.py", "memory/qemu/perp-hvf-quiesce.h"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--reference-app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ninja", default="ninja")
    args = parser.parse_args()
    ninja = shutil.which(args.ninja)
    if not ninja:
        raise ValueError("Select the existing qualified Ninja executable with --ninja")
    source, build, app = (p.resolve(strict=True) for p in
                          (args.source, args.build, args.reference_app))
    out = args.output.resolve()
    if any(p.is_relative_to(ROOT) for p in (source, build, out)) or out.exists():
        raise ValueError("Use external source/build and a new private output directory")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    native = app / "Contents/Resources/Native3D"
    manifest = json.loads((native / "runtime.json").read_text())
    for name, expected in manifest["files"].items():
        member = native / name
        if not member.resolve().is_relative_to(native) or sha(member) != expected:
            raise ValueError("Reference native runtime differs: " + name)
    receipt = json.loads((native / "memory-runtime.json").read_text())
    pins = [f["sourceSHA256"] for f in receipt["files"]
            if f["file"] == "Contents/Resources/Native3D/bin/qemu-system-aarch64"]
    binary = build / "qemu-system-aarch64-unsigned"
    if len(pins) != 1 or binary.is_symlink() or sha(binary) != pins[0]:
        raise ValueError("Build output does not match the qualified local QEMU pin")
    for name in ("perp-balloon-reclaim.h", "perp-virtio-mem-hvf.h"):
        if sha(source / "hw/virtio" / name) != sha(ROOT / "memory/qemu" / name):
            raise ValueError("The qualified memory base differs: " + name)
    helper = source / "hw/virtio/perp-hvf-quiesce.h"
    if helper.exists():
        raise ValueError("Source already has a quiesce helper; preserve it")
    lock = open(build / ".perpendicular-memory-build.lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    out.mkdir(parents=True)
    names = ["hw/virtio/virtio-balloon.c", "hw/virtio/virtio-mem.c",
             "include/hw/virtio/virtio-balloon.h", "include/hw/virtio/virtio-mem.h"]
    originals = {name: (source / name).read_bytes() for name in names}
    shutil.copy2(binary, out / "qualified-before-unsigned")
    for name in names:
        backup = out / "source-before" / name
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_bytes(originals[name])
    try:
        subprocess.run(["python3", str(ROOT / PATCHES[0]), str(source)], check=True)
        with (out / "build.log").open("w") as log:
            subprocess.run([ninja, "-C", str(build), "-j2", binary.name],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        target = out / binary.name
        shutil.copy2(binary, target)
        result = {"schema": 1, "version": 1,
                  "baseUnsignedSHA256": pins[0], "outputSHA256": sha(target),
                  "patches": {name: sha(ROOT / name) for name in PATCHES},
                  "sourceBefore": {name: hashlib.sha256(data).hexdigest()
                                   for name, data in originals.items()},
                  "sourceAfter": {name: sha(source / name) for name in names},
                  "runtimeQualified": False}
        (out / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
    finally:
        for name, data in originals.items():
            (source / name).write_bytes(data)
            # Restored source must be newer than candidate objects so a later
            # ordinary Ninja invocation rebuilds the original implementation.
            os.utime(source / name, None)
        if helper.exists():
            helper.unlink()
        shutil.copy2(out / "qualified-before-unsigned", binary)
        if sha(binary) != pins[0] or any((source / n).read_bytes() != d
                                       for n, d in originals.items()):
            raise RuntimeError("Qualified cache restoration failed")
        lock.close()
    print("Built isolated QEMU; qualified cache restored; runtime verification pending.")


if __name__ == "__main__":
    main()
