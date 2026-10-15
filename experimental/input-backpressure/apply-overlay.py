#!/usr/bin/env python3
"""Verify pinned files and create pinned patched source copies, never a binary."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=REPO / ".tools/graphics-experiment/src/qemu")
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    source, output = options.source.resolve(), options.output.resolve()
    # Allow only a fresh source overlay under this dedicated private area.
    private = (REPO / ".tools/input-backpressure").resolve()
    if private not in output.parents or source in output.parents or output == source:
        raise SystemExit("Output must be a fresh directory under .tools/input-backpressure")
    if output.exists():
        raise SystemExit("Refusing to overwrite an existing overlay")
    manifest = json.loads((HERE / "source-hashes.json").read_text())
    for name, expected in manifest["files"].items():
        if digest(source / name) != expected:
            raise SystemExit("Pinned source mismatch: " + name)
    output.mkdir(parents=True)
    try:
        for name in manifest["files"]:
            destination = output / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, destination)
        subprocess.run(["patch", "--batch", "-p1", "-i", str(HERE / "qemu-10.0.12-backpressure.patch")], cwd=output, check=True)
        for name, expected in manifest["patched_files"].items():
            if digest(output / name) != expected:
                raise RuntimeError("Patched source mismatch: " + name)
    except BaseException:
        shutil.rmtree(output)
        raise
    print("Verified source overlay created; no runtime, VM, build tree or application was changed.")


if __name__ == "__main__":
    main()
