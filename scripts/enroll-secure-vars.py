#!/usr/bin/env python3
"""Enroll an empty ArmVirt store using an independent local PK and public MS CAs.

Build tooling only. It never edits a VM's variable store or installed app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".tools"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_tools():
    python = os.environ.get("PERPENDICULAR_ENROLL_PYTHON") or shutil.which("python3.14")
    if not python:
        raise SystemExit("Python 3.14 is required for the pinned macOS ARM64 build tools.")
    version = subprocess.check_output(
        [python, "-c", "import platform,sys; print(platform.machine(), *sys.version_info[:2])"],
        text=True).strip()
    if version != "arm64 3 14":
        raise SystemExit("The firmware tooling lock currently targets macOS ARM64 / Python 3.14.")
    environment = WORK / "firmware-venv"
    if not (environment / "bin/python").exists():
        subprocess.run([python, "-m", "venv", str(environment)], check=True)
    subprocess.run([
        str(environment / "bin/python"), "-m", "pip", "install", "--no-deps",
        "--only-binary=:all:", "--require-hashes", "--find-links",
        str(WORK / "downloads/firmware-python"), "-r",
        str(ROOT / "scripts/firmware-requirements.txt")], check=True)
    return environment / "bin/virt-fw-vars"


def platform_certificate():
    directory = WORK / "secure-boot"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink():
        raise SystemExit("Refusing a symlink for the private firmware key directory.")
    directory.chmod(0o700)
    key, cert = directory / "platform-key.pem", directory / "platform-cert.pem"
    if key.is_symlink() or cert.is_symlink():
        raise SystemExit("Refusing symlinked firmware key files.")
    if key.exists() != cert.exists():
        raise SystemExit("Incomplete firmware key pair; preserve and inspect .tools/secure-boot first.")
    if not key.exists():
        with tempfile.TemporaryDirectory(prefix="generate-", dir=directory) as temporary:
            staging = Path(temporary)
            subprocess.run([
                "/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072",
                "-sha256", "-nodes", "-days", "3650", "-subj",
                "/CN=Perpendicular Desktop local platform key/",
                "-keyout", str(staging / "key.pem"), "-out", str(staging / "cert.pem")],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            (staging / "key.pem").chmod(0o600)
            (staging / "cert.pem").chmod(0o644)
            (staging / "key.pem").replace(key)
            (staging / "cert.pem").replace(cert)
    key.chmod(0o600)
    public_key = subprocess.check_output(["/usr/bin/openssl", "pkey", "-in", str(key), "-pubout"])
    public_cert = subprocess.check_output(["/usr/bin/openssl", "x509", "-in", str(cert), "-pubkey", "-noout"])
    if public_key != public_cert:
        raise SystemExit("Firmware platform key and certificate do not match.")
    return cert


def validate_variables(path, certificate):
    document = json.loads(path.read_text())
    entries = document.get("variables", [])
    variables = {entry["name"]: entry for entry in entries}
    if len(variables) != len(entries):
        raise SystemExit("Duplicate variable names in the enrolled store.")
    for name in ("PK", "KEK", "db", "dbx"):
        entry = variables.get(name, {})
        if entry.get("attr") != 39 or not entry.get("data"):
            raise SystemExit("Missing authenticated variable " + name)
    if variables.get("SecureBootEnable", {}).get("data") != "01":
        raise SystemExit("SecureBootEnable was not enabled.")
    if variables.get("CustomMode", {}).get("data") != "00":
        raise SystemExit("CustomMode was not disabled.")
    expected_pk = subprocess.check_output([
        "/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "DER"])
    certificates = {}
    for name in ("PK", "KEK", "db"):
        payload = bytes.fromhex(variables[name]["data"])
        position, values = 0, []
        while position < len(payload):
            if len(payload) - position < 28:
                raise SystemExit("Truncated signature list in " + name)
            size, header, signature = struct.unpack_from("<III", payload, position + 16)
            if size < 28 + header or signature < 16 or position + size > len(payload):
                raise SystemExit("Invalid signature list bounds in " + name)
            if (size - 28 - header) % signature:
                raise SystemExit("Invalid signature list alignment in " + name)
            for offset in range(position + 28 + header, position + size, signature):
                der = payload[offset + 16:offset + signature]
                subject = subprocess.check_output([
                    "/usr/bin/openssl", "x509", "-inform", "DER", "-noout", "-subject"],
                    input=der).decode().strip()
                values.append((der, subject))
            position += size
        certificates[name] = values
    if [der for der, _ in certificates["PK"]] != [expected_pk]:
        raise SystemExit("Enrolled platform certificate differs from the local PK.")
    if len(certificates["db"]) != 2 or not all("Microsoft" in name for _, name in certificates["db"]):
        raise SystemExit("Expected exactly the two Microsoft Windows trust certificates.")
    return {name: [subject for _, subject in values] for name, values in certificates.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware-dir", type=Path, default=WORK / "edk2/output")
    parser.add_argument("--output-dir", type=Path, default=WORK / "edk2/enrolled")
    args = parser.parse_args()
    source, destination = args.firmware_dir.resolve(), args.output_dir.resolve()
    if source == destination:
        raise SystemExit("Use a separate output directory; the input build is preserved.")
    empty = source / "edk2-arm-empty-vars.fd"
    for name in (empty.name, "edk2-aarch64-secure-code.fd", "edk2-licenses.txt", "build-manifest.json"):
        if not (source / name).is_file():
            raise SystemExit("Build the secure firmware first; missing " + name)
    tool = prepare_tools()
    cert = platform_certificate()
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="enroll-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        enrolled = staging / "edk2-arm-secure-vars.fd"
        subprocess.run([
            str(tool), "--input", str(empty), "--output", str(enrolled),
            "--enroll-cert", str(cert), "--microsoft-db", "win11",
            "--microsoft-kek", "all", "--secure-boot"], check=True)
        if enrolled.stat().st_size != 64 * 1024 * 1024:
            raise SystemExit("Enrolled ARM variable bank is not 64 MiB.")
        result = subprocess.check_output([
            str(tool), "--input", str(enrolled), "--output-json", str(staging / "variables.json"),
            "--print"], text=True)
        certificates = validate_variables(staging / "variables.json", cert)
        # The tool parses the generated store again; preserve its public summary.
        (staging / "enrolled-variable-summary.txt").write_text(result)
        (staging / "enrolled-variable-summary.json").write_text(json.dumps({
            "SecureBootEnable": "01", "CustomMode": "00",
            "x509_certificates": certificates,
            "dbx": "Placeholder only; current revocations require a separate verified update.",
        }, indent=2) + "\n")
        manifest = json.loads((source / "build-manifest.json").read_text())
        manifest["enrolled_variables_provenance"] = {
            "method": "Empty source-built ArmVirt store, independently enrolled with virt-fw-vars",
            "tool": "virt-firmware 26.10",
            "tool_source": "https://gitlab.com/kraxel/virt-firmware",
            "tool_lock": "scripts/firmware-requirements.txt",
            "input_empty_sha256": sha256(empty),
            "platform_certificate_sha256": sha256(cert),
            "platform_private_key_bundled": False,
            "db_profile": "Microsoft Windows Production PCA 2011 and Windows UEFI CA 2023",
            "kek_profile": "Local platform certificate and Microsoft KEK 2011/2023",
            "dbx": "virt-firmware placeholder only; current Microsoft revocations are not provisioned",
            "guest_secure_boot_verified": False,
        }
        for name in ("edk2-aarch64-secure-code.fd", "edk2-licenses.txt"):
            shutil.copy2(source / name, staging / name)
        manifest["files_sha256"] = {
            path.name: sha256(path) for path in staging.glob("*.fd")}
        (staging / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        package = WORK / "firmware-venv/lib/python3.14/site-packages/virt_firmware-26.10.dist-info/licenses/LICENSE"
        if package.is_file():
            shutil.copy2(package, staging / "virt-firmware-LICENSE")
        # No private key or local path is published in output metadata.
        for path in staging.iterdir():
            path.replace(destination / path.name)
    print("Enrolled firmware prepared at", destination)
    print("No existing VM or installed runtime was changed. Guest verification is still required.")


if __name__ == "__main__":
    main()
