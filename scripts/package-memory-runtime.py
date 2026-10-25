#!/usr/bin/env python3
"""Put a built memory QEMU and its library closure in a new private app bundle.

Preserves renderer/server/backend, firmware, guest disks and configuration.
With --native, replaces the native QEMU and updates its pinned manifest hash.
Use only on a new, stopped development app, never a running runtime store.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--library-dir", type=Path, action="append", default=[])
    parser.add_argument("--native", action="store_true", help="Package a QEMU preserving the current native desktop hooks")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    source = args.qemu.resolve(strict=True)
    if app.suffix != ".app" or "Runtimes" in app.parts or source.is_relative_to(app):
        raise ValueError("A fresh development app and an external built QEMU are required")
    resource = "Native3D" if args.native else "QEMU"
    executable = (app / ("Contents/Resources/" + resource + "/bin/qemu-system-aarch64")).resolve(strict=True)
    if not executable.is_relative_to(app):
        raise ValueError("The app executable points outside its bundle")
    libraries = app / "Contents/Frameworks/Runtime/lib"
    libraries.mkdir(parents=True, exist_ok=True)
    search = [p.resolve(strict=True) for p in args.library_dir]
    copied, targets, receipt = {}, {}, []

    def resolve(dependency, owner):
        if dependency.startswith("@loader_path/"):
            return (owner.parent / dependency[len("@loader_path/"):]).resolve(strict=True)
        if dependency.startswith("@rpath/"):
            name = dependency[len("@rpath/"):]
            candidates = [p / name for p in [owner.parent, owner.parent.parent / "lib", *search]]
            for candidate in candidates:
                if candidate.is_file():
                    return candidate.resolve(strict=True)
            raise ValueError("Unresolved dependency: " + dependency)
        if not dependency.startswith("/"):
            raise ValueError("Unsupported dependency: " + dependency)
        return Path(dependency).resolve(strict=True)

    def copy(binary, target):
        binary = binary.resolve(strict=True)
        if binary in copied:
            return copied[binary]
        if target in targets and targets[target] != binary:
            raise ValueError("Library name collision: " + str(target))
        copied[binary], targets[target] = target, binary
        shutil.copy2(binary, target)
        target.chmod(0o755)
        subprocess.run(["codesign", "--remove-signature", str(target)], capture_output=True)
        dependencies = [line.strip().split(" (")[0] for line in output("otool", "-L", str(binary)).splitlines()[1:]]
        for name in dependencies:
            if name.startswith(("/usr/lib/", "/System/")):
                continue
            dependency = resolve(name, binary)
            if dependency == binary:
                continue
            packaged = copy(dependency, libraries / dependency.name)
            output("install_name_tool", "-change", name,
                   "@loader_path/" + os.path.relpath(packaged, target.parent), str(target))
        if target.suffix == ".dylib":
            output("install_name_tool", "-id", "@loader_path/" + target.name, str(target))
        command = ["codesign", "--force", "--sign", "-"]
        if target == executable:
            command += ["--entitlements", str(Path(__file__).resolve().parents[1] / "macos/Hypervisor.entitlements")]
        output(*command, str(target))
        receipt.append({"source": str(binary), "sourceSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                        "file": str(target.relative_to(app)), "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
        return target

    copy(source, executable)
    console = app / "Contents/Resources/QEMU/Windows Console.app"
    if not args.native and console.exists():
        output("codesign", "--force", "--sign", "-", "--entitlements",
               str(Path(__file__).resolve().parents[1] / "macos/Hypervisor.entitlements"), str(console))
    if args.native:
        manifest_path = app / "Contents/Resources/Native3D/runtime.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["files"]["bin/qemu-system-aarch64"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        manifest["hvf_dynamic_memory_version"] = 1
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    (app / ("Contents/Resources/" + resource + "/memory-runtime.json")).write_text(json.dumps({
        "schema": 1, "hvfMemoryVersion": 1, "graphicsQualified": False, "files": receipt,
    }, indent=2) + "\n")
    output("codesign", "--force", "--sign", "-", str(app))
    print("Packaged private memory QEMU and", len(copied)-1, "libraries; guest verification still required.")


if __name__ == "__main__":
    main()
