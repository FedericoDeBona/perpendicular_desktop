#!/usr/bin/env python3
"""Bundle independently built QEMU and its local dylibs into the macOS app."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True)


def dependencies(path):
    return [line.strip().split(" (", 1)[0]
            for line in run("otool", "-L", str(path)).splitlines()[1:]]


def clear_finder_metadata(path):
    # Finder decoration on generated files is incompatible with code signing.
    # Preserve quarantine and every other security attribute.
    attributes = run("/usr/bin/xattr", "-s", str(path)).splitlines()
    for name in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
        if name in attributes:
            subprocess.run(["/usr/bin/xattr", "-s", "-d", name, str(path)], check=True)


def copy_code(source, target):
    # Homebrew executables may be read-only. Only our generated copy is made
    # writable, so relocation and a later rebuild do not modify the source keg.
    if target.exists():
        target.chmod(target.stat().st_mode | 0o200)
    shutil.copy2(source, target)
    target.chmod(target.stat().st_mode | 0o200)


def collect_notices(originals, notice):
    packages = {}
    for original in originals:
        parts = original.parts
        if "Cellar" not in parts:
            continue
        index = parts.index("Cellar")
        if len(parts) <= index + 2:
            continue
        keg = Path(*parts[:index + 3])
        name, version = parts[index + 1:index + 3]
        key = name + "-" + version
        if key in packages:
            continue
        destination = notice / "Homebrew" / key
        candidates = [p for p in keg.iterdir() if p.is_file() and
                      p.name.lower().startswith(("copying", "license", "licence", "copyright", "lgpl-", "gpl-", "apache-", "bsd-", "mit."))]
        for folder in (keg / "share/licenses", keg / "share/doc"):
            if folder.exists():
                candidates += [p for p in folder.rglob("*") if p.is_file() and
                               p.name.lower().startswith(("copying", "license", "licence", "copyright"))]
        for path in candidates + list((keg / ".brew").glob("*.rb")):
            relative = path.relative_to(keg)
            (destination / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination / relative)
        packages[key] = {"formula": name, "version": version,
                         "notices": [str(p.relative_to(keg)) for p in candidates],
                         "source_recipe": "Homebrew/" + key + "/.brew/" + name + ".rb"}
    return packages


def copy_dbx_notices(share, notice, bundled_share=None):
    """Retain factory DBX provenance with its required redistributable notice."""
    report = share / "microsoft-dbx-provenance.json"
    license_file = share / "microsoft-secureboot-objects-licenses.txt"
    if not report.is_file():
        # Rebuilt bundles must not display metadata from a different template.
        for name in (report.name, license_file.name):
            target = notice / name
            if target.is_file():
                target.unlink()
        if bundled_share is not None:
            for name in (report.name, license_file.name, "microsoft-arm64-dbx.esl",
                         "microsoft-arm64-dbx-signed-subset.efiauth2"):
                target = bundled_share / name
                if target.is_file():
                    target.unlink()
        return
    if not license_file.is_file():
        raise RuntimeError("Microsoft DBX firmware requires its corresponding license notice")
    for source in (report, license_file):
        shutil.copy2(source, notice / source.name)


def main():
    app, prefix = map(lambda x: Path(x).resolve(), sys.argv[1:3])
    resources = app / "Contents/Resources"
    runtime = resources / "QEMU"
    libraries = app / "Contents/Frameworks/Runtime/lib"
    binaries = runtime / "bin"
    binaries.mkdir(parents=True, exist_ok=True)
    libraries.mkdir(parents=True, exist_ok=True)
    source_binaries = [prefix / "bin/qemu-system-aarch64", prefix / "bin/qemu-img"]
    swtpm = os.environ.get("PERPENDICULAR_SWTPM") or shutil.which("swtpm")
    if swtpm:
        source_binaries.append(Path(swtpm))
    for source in source_binaries:
        if not source.is_file():
            raise RuntimeError(f"Missing runtime executable: {source}. Run scripts/bootstrap.sh.")
    files = []
    queue = []
    copied = {}
    for source in source_binaries:
        target = binaries / source.name
        copy_code(source.resolve(), target)
        queue.append((source.resolve(), target, True))
        files.append(target)
    while queue:
        source, target, executable = queue.pop(0)
        replacements = []
        for dependency in dependencies(source):
            if dependency.startswith(("/System/", "/usr/lib/")):
                continue
            if dependency.startswith("@"):
                raise RuntimeError(f"Unresolved runtime dependency {dependency} in {source}")
            original = Path(dependency).resolve()
            if not original.is_file():
                raise RuntimeError(f"Missing dependency: {dependency}")
            name = original.name
            destination = libraries / name
            if name not in copied:
                copy_code(original, destination)
                copied[name] = original
                queue.append((original, destination, False))
                files.append(destination)
            elif copied[name] != original:
                if hashlib.sha256(original.read_bytes()).digest() != hashlib.sha256(copied[name].read_bytes()).digest():
                    raise RuntimeError(f"Runtime library name collision: {name}")
            relative = ("@executable_path/../../../Frameworks/Runtime/lib/" if executable
                        else "@loader_path/") + name
            replacements.extend(["-change", dependency, relative])
        if not executable:
            replacements.extend(["-id", "@rpath/" + target.name])
        if replacements:
            subprocess.run(["install_name_tool", *replacements, str(target)], check=True)
    share = prefix / "share/qemu"
    if not share.is_dir():
        raise RuntimeError(f"Missing QEMU firmware directory: {share}")
    shutil.copytree(share, runtime / "share/qemu", dirs_exist_ok=True)
    notice = resources / "ThirdPartyNotices"
    notice.mkdir(exist_ok=True)
    qemu_source = prefix.parent / "src/qemu-11.1.2"
    for name in ("COPYING", "COPYING.LIB", "LICENSE"):
        if (qemu_source / name).is_file():
            shutil.copy2(qemu_source / name, notice / ("QEMU-" + name))
    for license_file in share.glob("*licenses*.txt"):
        shutil.copy2(license_file, notice / license_file.name)
    copy_dbx_notices(share, notice, runtime / "share/qemu")
    packages = collect_notices([p.resolve() for p in source_binaries] + list(copied.values()), notice)
    downloads = prefix.parent / "downloads"
    if (downloads / "perpendicular-drivers.iso").is_file():
        shutil.copy2(downloads / "perpendicular-drivers.iso", resources / "perpendicular-drivers.iso")
        for name in ("driver-manifest.json", "virtio-win_license.txt"):
            if not (downloads / name).is_file():
                raise RuntimeError("Rebuild the driver disc with scripts/provision-guest-drivers.py to retain provenance and license")
            shutil.copy2(downloads / name, notice / name)
    for source in files:
        clear_finder_metadata(source)
        command = ["codesign", "--force", "--sign", "-"]
        if source.name == "qemu-system-aarch64":
            command += ["--entitlements", str(Path(__file__).resolve().parent.parent / "macos/Hypervisor.entitlements")]
        subprocess.run([*command, str(source)], check=True, capture_output=True)
    manifest = {"qemu_version": "11.1.2", "qemu_source": "https://download.qemu.org/qemu-11.1.2.tar.xz",
                "qemu_source_sha256": "731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016",
                "has_swtpm": bool(swtpm), "relocated_libraries": sorted(copied),
                "homebrew_packages": packages,
                "has_arm64_drivers": (resources / "perpendicular-drivers.iso").is_file()}
    (resources / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Bundled {len(files)} executables/libraries and QEMU firmware")


if __name__ == "__main__":
    main()
