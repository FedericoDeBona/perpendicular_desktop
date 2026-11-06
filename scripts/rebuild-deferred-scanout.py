#!/usr/bin/env python3
"""Build a private deferred scanout candidate from a matching local QEMU recipe.

No cache/source/VM mutation. All baseline code/data sections and dependencies
must match the installed reference before compiling one isolated scanout unit.
An output receipt is provenance, not evidence of runtime qualification.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import runpy
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATCHES = [ROOT / "graphics/monitor" / name for name in
           ("consumer-demand.patch", "deferred-scanout-selection.patch")]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "build", "link-command", "reference-app", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--machine-directory", type=Path, required=True)
    parser.add_argument("--identifier", default="com.perpendicular.deferred-scanout-qa")
    parser.add_argument("--test-late-selection", action="store_true", help="QA only: defer one replacement admission for 120ms after 20 native frames")
    args = parser.parse_args()
    if not re.fullmatch(r"com\.perpendicular\.[a-z0-9.-]+", args.identifier):
        raise ValueError("A private QA bundle identifier is required")
    pins = json.loads((ROOT / "graphics/monitor/deferred-selection-inputs.json").read_text())
    if any(sha(patch) != pins["patches"][str(patch.relative_to(ROOT))] for patch in PATCHES):
        raise ValueError("A scanout patch differs from its shared input pin")
    patches = list(PATCHES)
    if args.test_late_selection:
        qa_patch = ROOT / pins["qaOnlyPatch"]["path"]
        if sha(qa_patch) != pins["qaOnlyPatch"]["sha256"]:
            raise ValueError("The QA-only injection differs from its shared pin")
        patches.append(qa_patch)
    source, build, reference = [p.resolve(strict=True) for p in
                                (args.source, args.build, args.reference_app)]
    out = args.output.resolve()
    if out.exists() or any(p.is_relative_to(ROOT) for p in (source, build, out)):
        raise ValueError("Use retained external inputs and a new private output")
    native = reference / "Contents/Resources/Native3D"
    manifest = json.loads((native / "runtime.json").read_text())
    if any(sha(native / name) != expected for name, expected in manifest["files"].items()):
        raise ValueError("Reference runtime differs from its manifest")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(reference)], check=True)
    link = json.loads(args.link_command.read_text())
    installed = native / "bin/qemu-system-aarch64"
    expected_dependencies = subprocess.check_output(["otool", "-L", str(installed)], text=True).splitlines()[1:]
    reference_names = [line.strip().split(" (", 1)[0] for line in expected_dependencies]
    inputs = {name: sha(Path(name) if Path(name).is_absolute() else build / name)
              for name in link if name.endswith((".o", ".a")) and not name.startswith("-")}
    if len(inputs) < 500:
        raise ValueError("Incomplete local link command")
    out.mkdir(parents=True, mode=0o700)

    def run(command, label):
        command = list(map(str, command))
        (out / (label + ".command.json")).write_text(json.dumps(command, indent=2) + "\n")
        result = subprocess.run(command, cwd=build, capture_output=True, text=True)
        (out / (label + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError("Failed " + label + "; see private log")
        return result.stdout

    def package(command, target):
        command = list(command)
        command[command.index("-o") + 1] = str(target)
        run(command, target.parent.name + "-link")
        for line in run(["otool", "-L", target], target.parent.name + "-deps").splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/System/", "/usr/lib/", "@executable_path/")):
                continue
            # The ordinary packager consolidates aliases into versioned names.
            # Reuse the reference's exact closure, not the original cache alias.
            key = lambda name: re.sub(r"(?:\.\d+)+(?=\.dylib$)", "", Path(name).name)
            matches = [name for name in reference_names if key(name) == key(dependency)]
            if len(matches) != 1 or not matches[0].startswith("@loader_path/"):
                raise ValueError("Ambiguous/unpackaged dependency: " + dependency)
            replacement = matches[0]
            file = (installed.parent / replacement[len("@loader_path/"):]).resolve(strict=True)
            if not file.is_relative_to(reference):
                raise ValueError("Reference dependency escapes bundle")
            run(["install_name_tool", "-change", dependency, replacement, target], "relocate-" + Path(dependency).name)

    original = source / "ui/perpendicular-display/qemu-native-sync.m"
    if sha(original) != pins["sourceBefore"]:
        raise ValueError("Scanout source differs from the retained qualified baseline")
    row = next(r for r in json.loads((build / "compile_commands.json").read_text())
               if r["file"].endswith("ui/perpendicular-display/qemu-native-sync.m"))
    old = "libcommon.a.p/ui_perpendicular-display_qemu-native-sync.m.o"
    if link.count(old) != 1:
        raise ValueError("Scanout unit is not a unique link input")

    def compile_unit(file, obj, label):
        command = shlex.split(row["command"])
        command[command.index(row["file"])] = str(file)
        command[1:1] = ["-I" + str(original.parent)]
        for flag, value in (("-o", obj), ("-MF", str(obj) + ".d"), ("-MQ", obj)):
            if flag in command:
                command[command.index(flag) + 1] = str(value)
        run(command, label)

    # A retained object alone does not prove the current source/header bytes
    # still reproduce it. Freshly compile the original unit and require the
    # full reference code/data and dependency closure before applying a patch.
    baseline_object = out / "baseline-scanout.o"
    compile_unit(row["file"], baseline_object, "compile-baseline-scanout")
    baseline_link = list(link)
    baseline_link[baseline_link.index(old)] = str(baseline_object)
    baseline = out / "qemu-system-aarch64-baseline"
    package(baseline_link, baseline)
    sections = runpy.run_path(str(ROOT / "scripts/rebuild-hvf-erridr.py"))["sections"]
    if sections(baseline) != sections(installed):
        raise ValueError("Baseline code/data differs; no candidate compiled")
    actual = subprocess.check_output(["otool", "-L", str(baseline)], text=True).splitlines()[1:]
    if actual != expected_dependencies:
        raise ValueError("Baseline dependency closure differs")
    patched = out / "qemu-native-sync.m"
    shutil.copy2(original, patched)
    for index, patch in enumerate(patches):
        run(["patch", "--batch", "--forward", str(patched), str(patch)], "patch-" + str(index))
        if index == len(PATCHES)-1:
            run(["python3", ROOT / "scripts/check-deferred-scanout.py", "--source", patched, "--output", out / "checks"], "checks")
    obj = out / "scanout.o"
    compile_unit(patched, obj, "compile-scanout")
    candidate_link = list(link)
    candidate_link[candidate_link.index(old)] = str(obj)
    app = out / "Perpendicular.app"
    shutil.copytree(reference, app, symlinks=True)
    target = app / "Contents/Resources/Native3D/bin/qemu-system-aarch64"
    target.unlink()
    package(candidate_link, target)
    run(["codesign", "--force", "--sign", "-", "--entitlements",
         ROOT / "macos/Hypervisor.entitlements", target], "sign-qemu")
    manifest["files"]["bin/qemu-system-aarch64"] = sha(target)
    manifest["deferred_scanout_selection_candidate"] = {
        "version": 1, "waitMilliseconds": 3000,
        "patches": {str(p.relative_to(ROOT)): sha(p) for p in patches},
        "qaFaultInjection": args.test_late_selection, "qualified": False}
    (target.parent.parent / "runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["PerpendicularMachineDirectory"] = str(args.machine_directory.resolve(strict=True))
    info["CFBundleIdentifier"] = args.identifier
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
    # Reuse the persistent identity with an explicit private QA identifier.
    # Secret-bearing security arguments must never enter command receipts.
    signer = runpy.run_path(str(ROOT / "scripts/sign-macos.py"))
    fingerprint, _ = signer["requirement"]()
    signer["run"](["security", "unlock-keychain", "-p", signer["PASSWORD"].read_text(), signer["KEYCHAIN"]])
    expected = f'identifier "{args.identifier}" and certificate leaf = H"{fingerprint}"'
    run(["codesign", "--force", "--sign", fingerprint, "--keychain", signer["KEYCHAIN"],
         "--timestamp=none", "--identifier", args.identifier, "--requirements", "=designated => " + expected, app], "sign")
    run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + expected, app], "verify")
    # Signing changes the executable hash and the signer updates the manifest.
    if any(sha(Path(n) if Path(n).is_absolute() else build / n) != value for n, value in inputs.items()):
        raise ValueError("Retained link inputs changed during compilation")
    (out / "receipt.json").write_text(json.dumps({"schema": 1, "sourceBefore": sha(original),
        "sourceAfter": sha(patched), "patches": {str(p.relative_to(ROOT)): sha(p) for p in patches}, "linkInputs": inputs,
        "qaFaultInjection": args.test_late_selection,
        "baselineSections": sections(baseline), "baseQEMU": sha(installed),
        "qemu": sha(target), "link": candidate_link, "runtimeQualified": False}, indent=2) + "\n")
    print(app)


if __name__ == "__main__":
    main()
