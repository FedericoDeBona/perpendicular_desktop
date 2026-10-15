#!/usr/bin/env python3
"""Compile only isolated overlay objects with the real fork's recorded flags."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=REPO / ".tools/input-backpressure/objects")
    parser.add_argument("--build", type=Path, default=REPO / ".tools/graphics-experiment/build/qemu")
    parser.add_argument("--original", type=Path, default=REPO / ".tools/graphics-experiment/src/qemu")
    options = parser.parse_args()
    overlay, output = options.overlay.resolve(), options.output.resolve()
    private = (REPO / ".tools/input-backpressure").resolve()
    if private not in output.parents or private not in overlay.parents:
        raise SystemExit("Only isolated input-backpressure source/object directories are allowed")
    manifest = json.loads((HERE / "source-hashes.json").read_text())
    for name, expected in manifest["patched_files"].items():
        if hashlib.sha256((overlay / name).read_bytes()).hexdigest() != expected:
            raise SystemExit("Unverified overlay file: " + name)
    entries = json.loads((options.build / "compile_commands.json").read_text())
    output.mkdir(parents=True, exist_ok=True)
    report = []
    for target in (name for name in manifest["patched_files"] if name.endswith(".c")):
        matches = [item for item in entries if item["file"].endswith("/" + target)]
        if not matches:
            report.append({"unit": target, "skipped": "Not enabled in this configured build"})
            print(target + ": not enabled in configured build (not claimed compiled)", flush=True)
            continue
        entry = matches[0]
        args = shlex.split(entry["command"])
        args[1:1] = ["-iquote", str(overlay / "include"), "-iquote", str(overlay / "ui"),
                     "-iquote", str((options.original.resolve() / target).parent)]
        obj = output / (target.replace("/", "_") + ".o")
        for index, arg in enumerate(args):
            if arg.endswith("/" + target):
                args[index] = str(overlay / target)
            if arg in ["-o", "-MQ"]:
                args[index + 1] = str(obj)
            if arg == "-MF":
                args[index + 1] = str(obj) + ".d"
        environment = os.environ.copy()
        environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        result = subprocess.run(args, cwd=options.build, env=environment, capture_output=True, text=True)
        report.append({"unit": target, "source_sha256": manifest["patched_files"][target],
                       "exit_code": result.returncode, "stderr": result.stderr})
        if result.returncode:
            raise SystemExit(result.stderr)
        print(target + ": complete source object compiled", flush=True)
    (output / "compile-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Configured changed translation units verified; no executable was linked or replaced.")


if __name__ == "__main__":
    main()
