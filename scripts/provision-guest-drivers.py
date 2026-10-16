#!/usr/bin/env python3
"""Build an ARM64 driver disc with the independently written guest agent."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
DOWNLOADS = ROOT / ".tools/downloads"
SOURCE_URL = "https://getutm.app/downloads/utm-guest-tools-latest.iso"
# Pin the inspected artifact; a changed upstream 'latest' fails closed.
SOURCE_SHA256 = "65b6a69b392ee01dd314c10f3dad9ebbf9c4160be43f5f0dd6bb715944d9095b"


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def extract_driver_content(source, content, extractor):
    if extractor:
        subprocess.run([extractor, "x", "-y", "-o" + str(content), str(source),
                        "Drivers/*", "virtio-win_license.txt"], check=True, stdout=subprocess.DEVNULL)
        return
    # macOS can read this pinned ISO without an additional package manager.
    # Keep it read-only and out of Finder; always release our own mount.
    mount = content.parent / "mounted-source"
    mount.mkdir()
    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint",
                    str(mount), str(source)], check=True, stdout=subprocess.DEVNULL)
    try:
        drivers = mount / "Drivers"
        license_file = mount / "virtio-win_license.txt"
        if not drivers.is_dir() or not license_file.is_file():
            raise SystemExit("Expected drivers and license are missing from the mounted source")
        content.mkdir()
        shutil.copytree(drivers, content / "Drivers")
        shutil.copy2(license_file, content / license_file.name)
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True,
                       stdout=subprocess.DEVNULL)


def main():
    extractor = shutil.which("7z") or shutil.which("7zz")
    if not extractor and not shutil.which("hdiutil"):
        raise SystemExit("Install an ISO extractor first: brew install sevenzip")
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    source = DOWNLOADS / "utm-guest-tools.iso"
    if not source.exists():
        request = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "PerpendicularDesktop/0.1"})
        # Do not leave a truncated cache entry after a failed download.
        with tempfile.TemporaryDirectory(prefix="driver-download-", dir=DOWNLOADS) as temporary:
            download = Path(temporary) / "source.iso"
            with urllib.request.urlopen(request, timeout=60) as response, download.open("wb") as output:
                shutil.copyfileobj(response, output)
            if digest(download) != SOURCE_SHA256:
                raise SystemExit("Guest driver source checksum mismatch; inspect an updated artifact before changing the pin")
            download.replace(source)
    if digest(source) != SOURCE_SHA256:
        raise SystemExit("Guest driver source checksum mismatch; inspect an updated artifact before changing the pin")
    with tempfile.TemporaryDirectory(prefix="drivers-", dir=DOWNLOADS) as temporary:
        staging = Path(temporary)
        content = staging / "content"
        extract_driver_content(source, content, extractor)
        for path in content.rglob("*"):
            if path.is_file() and path.name != "virtio-win_license.txt":
                if "arm64" not in [part.lower() for part in path.relative_to(content).parts]:
                    path.unlink()
        for path in sorted(content.rglob("*"), key=lambda p: len(p.parts), reverse=True):
            if path.is_dir() and not any(path.iterdir()):
                path.rmdir()
        drivers = sorted(path for path in (content / "Drivers").rglob("*") if path.is_file())
        if not drivers or not (content / "virtio-win_license.txt").is_file():
            raise SystemExit("Expected ARM64 drivers and license are missing")
        agent_source = ROOT / "guest-tools/windows"
        required_agent_files = (
            "PerpendicularAgent.ps1", "PerpendicularAgent.Core.ps1",
            "PerpendicularAgent.Display.ps1",
            "Install-PerpendicularAgent.ps1", "Uninstall-PerpendicularAgent.ps1",
            "Install-PerpendicularGuestTools.ps1", "Install-PerpendicularGuestTools.cmd",
            "Get-PerpendicularGuestToolsDiagnostics.ps1", "Get-PerpendicularGuestToolsDiagnostics.cmd",
            "Set-PerpendicularGuestChannelAccess.ps1", "PerpendicularChannelAccess.Native.cs")
        for name in required_agent_files:
            if not (agent_source / name).is_file():
                raise SystemExit("The independent Guest Tools package is incomplete: " + name)
        agent_destination = content / "GuestTools"
        agent_destination.mkdir()
        for name in required_agent_files:
            shutil.copy2(agent_source / name, agent_destination / name)
        shutil.copytree(agent_source / "tests", agent_destination / "tests")
        shutil.copy2(ROOT / "guest-tools/README.md", agent_destination / "README.md")
        shutil.copy2(ROOT / "LICENSE", agent_destination / "LICENSE.txt")
        (content / "README.txt").write_text(
            "Perpendicular Desktop: optional ARM64 VirtIO drivers.\n"
            "Source: " + SOURCE_URL + "\n"
            "Includes signed drivers and independent Perpendicular Guest Tools. No automatic setup.\n"
            "In Windows, use Device Manager or pnputil to install the required signed driver.\n"
            "From a logged-in Windows desktop, open GuestTools and double-click\n"
            "Install-PerpendicularGuestTools.cmd. Only the signed-driver step requests administrator permission.\n"
            "The guest agent runs as your desktop user. System execution policies are unchanged.\n")
        manifest = {"source_url": SOURCE_URL, "source_sha256": SOURCE_SHA256,
                    "files": {str(p.relative_to(content)): digest(p) for p in drivers},
                    "independent_guest_tools": {
                        "source": "guest-tools/windows", "license": "Apache-2.0",
                        "files": {str(p.relative_to(content)): digest(p)
                                  for p in sorted(agent_destination.rglob("*")) if p.is_file()}}}
        (content / "driver-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        image = staging / "perpendicular-drivers.iso"
        subprocess.run(["hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name",
                        "PERPDRIVERS", "-o", str(image), str(content)], check=True)
        # Atomic publication does not mutate an image already open by a VM.
        image.replace(DOWNLOADS / "perpendicular-drivers.iso")
        for name in ("driver-manifest.json", "virtio-win_license.txt"):
            shutil.copy2(content / name, DOWNLOADS / name)
        print(f"Prepared {len(drivers)} ARM64 driver files; no unattended setup files included")


if __name__ == "__main__":
    main()
