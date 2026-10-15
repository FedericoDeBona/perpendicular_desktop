#!/usr/bin/env python3
"""Build a fresh private fork copy; never install or change an existing binary."""
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
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--test-probe", action="store_true", help="QA only: explicit qtest device probes")
    parser.add_argument("--jobs", type=int, default=2)
    options = parser.parse_args()
    private = (REPO / ".tools/input-backpressure").resolve()
    output = options.output.resolve()
    if private not in output.parents or output.exists():
        raise SystemExit("Output must be a fresh directory under .tools/input-backpressure")
    if not 1 <= options.jobs <= 4:
        raise SystemExit("Use 1–4 build jobs")
    original = REPO / ".tools/graphics-experiment/src/qemu"
    reference = REPO / ".tools/graphics-experiment/build/qemu"
    manifest = json.loads((HERE / "source-hashes.json").read_text())
    revision = subprocess.check_output(["git", "-C", str(original), "rev-parse", "HEAD"], text=True).strip()
    if revision != manifest["source_revision"]:
        raise SystemExit("Fork revision mismatch")
    for name, expected in manifest["files"].items():
        if hashlib.sha256((original / name).read_bytes()).hexdigest() != expected:
            raise SystemExit("Pinned source mismatch: " + name)
    lines = (reference / "config.status").read_text().splitlines()
    command = next(shlex.split(line) for line in lines if line.startswith("exec "))
    assert command[0] == "exec" and command[1].endswith("/configure")
    arguments = command[2:]
    if arguments and arguments[-1] == '"$@"':
        arguments.pop()
    if arguments and arguments[-1] == "$@":
        arguments.pop()
    output.mkdir(parents=True)
    source, build = output / "source", output / "build"
    # APFS clones are independent on write; the original source is read only.
    subprocess.run(["cp", "-cR", str(original), str(source)], check=True)
    subprocess.run(["patch", "--batch", "-p1", "-i", str(HERE / "qemu-10.0.12-backpressure.patch")], cwd=source, check=True)
    for name, expected in manifest["patched_files"].items():
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
            raise SystemExit("Patched source mismatch: " + name)
    if options.test_probe:
        subprocess.run(["patch", "--batch", "-p1", "-i", str(HERE / "qemu-qtest-probe.patch")], cwd=source, check=True)
    arguments = ["--prefix=" + str(output / "unused-prefix") if arg.startswith("--prefix=") else arg for arg in arguments]
    environment = os.environ.copy()
    environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    environment["PATH"] = str(REPO / ".tools/build-venv/bin") + os.pathsep + environment.get("PATH", "")
    environment["PKG_CONFIG_PATH"] = str(REPO / ".tools/graphics-experiment/prefix/lib/pkgconfig")
    environment["PYTHONPATH"] = str(REPO / ".tools/graphics-experiment/python-deps")
    build.mkdir()
    with (output / "configure.log").open("wb") as log:
        subprocess.run([str(source / "configure")] + arguments, cwd=build, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    with (output / "build.log").open("wb") as log:
        subprocess.run(["ninja", "-j" + str(options.jobs), "qemu-system-aarch64"], cwd=build, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    binary = build / "qemu-system-aarch64"
    data = binary.read_bytes()
    if not options.test_probe and b"x-input-test-" in data:
        raise SystemExit("QA probe unexpectedly present in production overlay binary")
    result = {"source_revision": revision, "qa_probe": options.test_probe,
              "binary": str(binary), "sha256": hashlib.sha256(data).hexdigest(),
              "production_patch_sha256": hashlib.sha256((HERE / "qemu-10.0.12-backpressure.patch").read_bytes()).hexdigest(),
              "configure_arguments": arguments}
    (output / "build-info.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
