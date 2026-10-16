#!/usr/bin/env python3
"""Bundle independently built QEMU and its local dylibs into the macOS app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
QEMU_SOURCE_SHA256 = "731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def repo_file(value, repo=REPO):
    if not isinstance(value, str) or not value or Path(value).is_absolute() or ".." in Path(value).parts:
        raise RuntimeError("Runtime provenance requires repository-relative file paths")
    path = (repo / value).resolve(strict=True)
    if repo.resolve() not in path.parents or not path.is_file():
        raise RuntimeError("Runtime provenance escaped the repository or selected a non-file")
    return path


def verify_candidate(path):
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True, capture_output=True)
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(path)],
                            check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout)
    if not isinstance(entitlements, dict) or set(entitlements) != {"com.apple.security.hypervisor"} or entitlements["com.apple.security.hypervisor"] is not True:
        raise RuntimeError("Display runtime must carry only the reviewed Hypervisor entitlement")


def display_runtime(path, repo=REPO, verify=verify_candidate):
    """Validate the explicit build selection before touching an application.

    A provenance report records inputs; its claims do not replace checking the
    actual bytes and signature. Firmware always comes from the normal prefix.
    """
    with path.open("rb") as stream:
        raw = stream.read(4 * 1024 * 1024 + 1)
    if len(raw) > 4 * 1024 * 1024:
        raise RuntimeError("Runtime provenance exceeds its bound")
    def unique(items):
        result = {}
        for key, value in items:
            if key in result:
                raise RuntimeError("Duplicate runtime provenance field")
            result[key] = value
        return result
    report = json.loads(raw, object_pairs_hook=unique)
    if type(report.get("schema")) is not int or report["schema"] != 1 or report.get("qemu_version") != "11.1.2":
        raise RuntimeError("Unsupported display runtime provenance")
    archive = report["upstream_archive"]
    if archive["sha256"] != QEMU_SOURCE_SHA256 or digest(repo_file(archive["path"], repo)) != QEMU_SOURCE_SHA256:
        raise RuntimeError("Display runtime has a different upstream QEMU archive")
    candidate = report["candidate"]
    binary = repo_file(candidate["path"], repo)
    if binary.name != "qemu-system-aarch64" or not os.access(binary, os.X_OK):
        raise RuntimeError("Display runtime must select the executable qemu-system-aarch64")
    if candidate.get("qa_probe_present") is not False or digest(binary) != candidate["sha256"]:
        raise RuntimeError("Display runtime binary identity/probe declaration mismatch")
    with binary.open("rb") as stream:
        if stream.read(8) != bytes.fromhex("cffaedfe0c000001"):
            raise RuntimeError("Display runtime must be a native thin ARM64 Mach-O")
        stream.seek(0)
        tail = b""
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            if b"x-input-test-" in tail + chunk or b"x-runtime-test-" in tail + chunk:
                raise RuntimeError("QA probe unexpectedly present in display runtime")
            tail = chunk[-32:]
    verify(binary)
    private_dependencies = {}
    dependencies_report = report.get("build", {}).get("private_dependencies", [])
    if not isinstance(dependencies_report, list) or len(dependencies_report) > 32:
        raise RuntimeError("Display runtime private dependency inventory exceeded its bound")
    for entry in dependencies_report:
        source = repo_file(entry["path"], repo)
        if source in private_dependencies or digest(source) != entry["sha256"]:
            raise RuntimeError("Display runtime private dependency identity mismatch")
        private_dependencies[source] = entry["sha256"]
    files = {}
    patches = report["production_patches"]
    if not isinstance(patches, list) or not 1 <= len(patches) <= 8:
        raise RuntimeError("Display runtime must identify its bounded production patches")
    for patch in patches:
        source = repo_file(patch["path"], repo)
        if source.suffix != ".patch" or digest(source) != patch["sha256"]:
            raise RuntimeError("Display runtime patch identity mismatch")
        files[patch["path"]] = {"path": source, "sha256": patch["sha256"]}
    notices = report["notices"]
    if not isinstance(notices, list) or not 1 <= len(notices) <= 32:
        raise RuntimeError("Display runtime must retain its source/license notices")
    for entry in notices:
        source = repo_file(entry["path"], repo)
        if not isinstance(entry.get("license"), str) or not entry["license"]:
            raise RuntimeError("Display runtime notice has no license attribution")
        files[entry["path"]] = {"path": source, "sha256": digest(source)}
    return {"binary": binary, "binary_sha256": candidate["sha256"], "files": files,
            "private_dependencies": private_dependencies,
            "manifest": path, "manifest_sha256": hashlib.sha256(raw).hexdigest()}


def copy_display_notices(selection, notice):
    destination = notice / "PerpendicularRuntime"
    destination.mkdir(parents=True, exist_ok=True)
    for name, entry in selection["files"].items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(entry["path"], target)
        if digest(target) != entry["sha256"]:
            raise RuntimeError("Runtime source/notice changed during packaging")
    target = destination / "provenance.json"
    shutil.copyfile(selection["manifest"], target)
    if digest(target) != selection["manifest_sha256"]:
        raise RuntimeError("Runtime provenance changed during packaging")


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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("prefix", type=Path)
    parser.add_argument("--display-runtime-manifest", type=Path,
                        default=os.environ.get("PERPENDICULAR_DISPLAY_RUNTIME_MANIFEST"))
    args = parser.parse_args()
    app, prefix = args.app.resolve(), args.prefix.resolve()
    selection = display_runtime(args.display_runtime_manifest.resolve(strict=True)) if args.display_runtime_manifest else None
    resources = app / "Contents/Resources"
    runtime = resources / "QEMU"
    libraries = app / "Contents/Frameworks/Runtime/lib"
    binaries = runtime / "bin"
    binaries.mkdir(parents=True, exist_ok=True)
    libraries.mkdir(parents=True, exist_ok=True)
    source_binaries = [selection["binary"] if selection else prefix / "bin/qemu-system-aarch64", prefix / "bin/qemu-img"]
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
        if selection and source == selection["binary"] and digest(target) != selection["binary_sha256"]:
            raise RuntimeError("Display runtime changed during packaging")
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
                if selection and original in selection["private_dependencies"] and digest(destination) != selection["private_dependencies"][original]:
                    raise RuntimeError("Display runtime private dependency changed during packaging")
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
    if selection:
        copy_display_notices(selection, notice)
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
                "qemu_source_sha256": QEMU_SOURCE_SHA256,
                "has_swtpm": bool(swtpm), "relocated_libraries": sorted(copied),
                "homebrew_packages": packages,
                "has_arm64_drivers": (resources / "perpendicular-drivers.iso").is_file(),
                "qemu_modified": selection is not None}
    if selection:
        manifest["qemu_overlay"] = {
            "provenance": "ThirdPartyNotices/PerpendicularRuntime/provenance.json",
            "provenance_sha256": selection["manifest_sha256"],
            "unrelocated_binary_sha256": selection["binary_sha256"],
            "bundled_binary_sha256": digest(binaries / "qemu-system-aarch64"),
            "firmware_source": "unchanged normal runtime prefix"}
    (resources / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Bundled {len(files)} executables/libraries and QEMU firmware")


if __name__ == "__main__":
    main()
