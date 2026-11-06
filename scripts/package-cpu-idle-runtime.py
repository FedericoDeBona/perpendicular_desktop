#!/usr/bin/env python3
"""Package an isolated local CPU candidate without modifying its inputs.

Validates the local rebuild receipt and shared patch. Packaging is provenance;
the product's runtime/normal-use qualification is recorded in VERIFICATION.md.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-app", "receipt", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    source = args.source_app.resolve(strict=True)
    out = args.output.resolve()
    if out.exists() or out.is_relative_to(ROOT):
        raise ValueError("Use a new private bundle outside the repository")
    native = source / "Contents/Resources/Native3D"
    manifest = json.loads((native / "runtime.json").read_text())
    if any(sha(native / name) != expected for name, expected in manifest["files"].items()):
        raise ValueError("Source native payload differs")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)
    receipt = json.loads(args.receipt.read_text())
    required = json.loads((ROOT / "cpu/requirements.json").read_text())
    patch = ROOT / "cpu/hvf-wfi-sleep.patch"
    if (receipt.get("qemu") != sha(native / "bin/qemu-system-aarch64")
            or receipt.get("patchSHA256") != sha(patch)
            or len(receipt.get("linkInputs", {})) < 1000
            or "__TEXT,__text" not in receipt.get("baselineSections", {})):
        raise ValueError("Receipt does not prove the packaged local CPU recipe")
    candidate = manifest.get("hvf_idle_wfi_candidate", {})
    for key, authority in (("version", "hvfIdleWFIVersion"),
                           ("idleBusyNanoseconds", "idleBusyNanoseconds"),
                           ("interactiveBusyNanoseconds", "interactiveBusyNanoseconds"),
                           ("leaseSeconds", "leaseSeconds")):
        if candidate.get(key) != required[authority]:
            raise ValueError("Candidate capability differs: " + key)
    if candidate.get("patchSHA256") != sha(patch):
        raise ValueError("Candidate patch pin differs")
    shutil.copytree(source, out, symlinks=True)
    manifest["hvf_idle_wfi"] = {key: candidate[key] for key in
                               ("version", "idleBusyNanoseconds", "interactiveBusyNanoseconds", "leaseSeconds")}
    manifest["hvf_idle_wfi"]["patches"] = {name: sha(ROOT / name) for name in required["requiredPatches"]}
    manifest["hvf_idle_wfi"]["sourceReceiptSHA256"] = sha(args.receipt)
    del manifest["hvf_idle_wfi_candidate"]
    (out / "Contents/Resources/Native3D/runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")
    subprocess.run(["python3", str(ROOT / "scripts/check-cpu-idle-runtime.py"), "--app", str(out)], check=True)
    subprocess.run(["python3", str(ROOT / "scripts/sign-macos.py"), "--app", str(out)], check=True)
    print(out)


if __name__ == "__main__":
    main()
