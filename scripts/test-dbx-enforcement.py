#!/usr/bin/env python3
"""Explicit isolated firmware tests. Never opens any existing VM disk/store.

Uses one 512 MiB/one-CPU disposable QEMU at a time, with copied variables,
private Unix sockets, a read-only test-only FAT directory and no TPM/network.
The unsigned and signed canary is the project's already built ARM64 UEFI Shell.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time
import uuid

from secure_boot_dbx import (IMAGE_SECURITY_GUID, SHA256_GUID, find_openssl,
                             preserved_variables, signature_entries)

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".tools"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
OWNER = "dbf42d2c-77e0-4a49-9a84-7e93f09806d1"
CANCELLED = False


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*arguments, **kwargs):
    check_cancelled()
    result = subprocess.run([str(value) for value in arguments], capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError("Command failed: " + str(arguments[0]) + "\n"
                           + result.stderr.decode(errors="replace")[-4096:])
    return result.stdout


def check_cancelled():
    if CANCELLED:
        raise RuntimeError("Isolated firmware test cancelled")


def auth2_observation(text):
    """Keep actual firmware rejection visible even when the probe exits early."""
    result = {}
    for operation in ("ORIGINAL", "TAMPER", "REPLAY"):
        match = re.search(r"PERP_AUTH2_" + operation + r"_STATUS=([^\n]*?) CODE=([0-9a-f]+)\b", text, re.I)
        result[operation.lower()] = ({"status": match.group(1), "code": "0x" + match.group(2).lower()}
                                     if match else {"status": "not_executed", "code": None})
    result["tamper_unchanged"] = "PERP_AUTH2_TAMPER_UNCHANGED=1" in text
    result["replay_unchanged"] = "PERP_AUTH2_REPLAY_UNCHANGED=1" in text
    return result


class Monitor:
    def __init__(self, path, identifier, launch_name):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(5)
        self.socket.connect(str(path))
        self.reader = self.socket.makefile("rb")
        self.sequence = 0
        greeting = self.read()
        if "QMP" not in greeting:
            raise RuntimeError("Invalid private QMP greeting")
        self.command("qmp_capabilities")
        if (self.command("query-uuid").get("UUID") != identifier
                or self.command("query-name").get("name") != launch_name):
            raise RuntimeError("Disposable VM QMP identity mismatch")

    def read(self):
        line = self.reader.readline(1024 * 1024 + 1)
        if not line or len(line) > 1024 * 1024:
            raise RuntimeError("Incomplete or oversized private QMP reply")
        return json.loads(line)

    def command(self, operation, arguments=None):
        self.sequence += 1
        request = {"execute": operation, "id": self.sequence}
        if arguments is not None:
            request["arguments"] = arguments
        self.socket.sendall(json.dumps(request).encode() + b"\n")
        while True:
            reply = self.read()
            if "event" in reply:
                continue
            if reply.get("id") != self.sequence or "error" in reply:
                raise RuntimeError("Private QMP request failed: " + str(reply))
            return reply["return"]

    def close(self):
        self.reader.close()
        self.socket.close()


def boot(name, variables, code, qemu, results, media=None, iso=None, marker=None):
    """Own the actual child handle until exit, including assertion failures."""
    directory = results / name
    directory.mkdir(mode=0o700)
    copied_variables = directory / "vars.fd"
    shutil.copyfile(variables, copied_variables)
    serial = directory / "serial.log"
    serial.touch()
    identifier = str(uuid.uuid4())
    launch_name = "perpendicular-dbx-test-" + identifier
    runtime = Path(tempfile.mkdtemp(prefix="perp-dbx-"))
    runtime.chmod(0o700)
    arguments = [str(qemu), "-machine", "virt,gic-version=3", "-accel", "hvf",
                 "-cpu", "host", "-smp", "1", "-m", "512", "-nodefaults",
                 "-S", "-name", launch_name, "-uuid", identifier,
                 "-drive", "if=pflash,unit=0,format=raw,readonly=on,file=" + str(code),
                 "-drive", "if=pflash,unit=1,format=raw,file=" + str(copied_variables),
                 "-device", "qemu-xhci,id=usb", "-device", "ramfb",
                 "-display", "none", "-monitor", "none",
                 "-serial", "file:" + str(serial),
                 "-qmp", "unix:" + str(runtime / "qmp.sock") + ",server=on,wait=off"]
    if media:
        arguments += ["-drive", "if=none,id=testfat,format=raw,readonly=on,file=fat:" + str(media),
                      "-device", "usb-bot,id=testusb,bus=usb.0",
                      "-device", "scsi-hd,drive=testfat,bus=testusb.0,bootindex=2"]
    if iso:
        arguments += ["-drive", "if=none,id=installiso,format=raw,media=cdrom,readonly=on,file=" + str(iso),
                      "-device", "usb-bot,id=installusb,bus=usb.0",
                      "-device", "scsi-cd,drive=installiso,bus=installusb.0,bootindex=1"]
    process, monitor = None, None
    try:
        check_cancelled()
        with (directory / "qemu.log").open("wb") as log:
            process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            check_cancelled()
            if process.poll() is not None:
                raise RuntimeError("Disposable QEMU exited: " + (directory / "qemu.log").read_text())
            if (runtime / "qmp.sock").exists():
                try:
                    monitor = Monitor(runtime / "qmp.sock", identifier, launch_name)
                    break
                except (OSError, RuntimeError):
                    if monitor:
                        monitor.close()
                    monitor = None
            time.sleep(0.05)
        if not monitor:
            raise RuntimeError("Disposable VM QMP did not become available")
        monitor.command("cont")
        started = time.monotonic()
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            check_cancelled()
            text = ANSI.sub("", serial.read_text(errors="replace"))
            if (marker == "PERP_AUTH2_PROBE_DONE"
                    and auth2_observation(text)["original"]["code"] == "0x800000000000001a"):
                return {"name": name, "serial_log": str(serial.relative_to(results)),
                        "observed_marker": "original Auth2 rejected", "pid": process.pid,
                        "serial_text": text}
            if marker == "visual-windows-loader" and time.monotonic() - started > 8:
                screenshot = directory / "display.png"
                monitor.command("screendump", {"filename": str(screenshot), "format": "png"})
                return {"name": name, "serial_log": str(serial.relative_to(results)),
                        "screenshot": str(screenshot.relative_to(results)),
                        "visual_verification_required": True, "pid": process.pid,
                        "serial_text": text}
            if marker in text:
                return {"name": name, "serial_log": str(serial.relative_to(results)),
                        "observed_marker": marker, "pid": process.pid,
                        "serial_text": text}
            if process.poll() is not None:
                break
            time.sleep(0.1)
        raise RuntimeError("Expected firmware marker not observed in " + str(serial))
    finally:
        if monitor:
            try:
                monitor.command("quit")
            except (OSError, RuntimeError, ValueError):
                pass
            try:
                monitor.close()
            except OSError:
                pass
        if process:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            (directory / "process-exit.json").write_text(json.dumps({
                "pid": process.pid, "uuid": identifier, "launch_name": launch_name,
                "exit_code": process.returncode, "owned_child_reaped": True}) + "\n")
        shutil.rmtree(runtime)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", required=True,
                        help="Explicitly authorize isolated firmware execution")
    parser.add_argument("--windows-iso", required=True, type=Path)
    parser.add_argument("--firmware-dir", type=Path, default=WORK / "edk2/enrolled-dbx")
    parser.add_argument("--auth2", action="store_true",
                        help="Also run the separately built, test-only Auth2 EFI probe")
    args = parser.parse_args()
    firmware = args.firmware_dir.resolve()
    qemu = WORK / "qemu/bin/qemu-system-aarch64"
    variables = firmware / "edk2-arm-secure-vars.fd"
    code = firmware / "edk2-aarch64-secure-code.fd"
    shell = WORK / "edk2/source/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/AARCH64/Shell.efi"
    tools = WORK / "firmware-venv/bin"
    signer = shutil.which("osslsigncode")
    if not signer:
        raise SystemExit("Install osslsigncode to sign the isolated EFI canary")
    iso = args.windows_iso.resolve()
    for path in (qemu, variables, code, shell, tools / "virt-fw-vars", iso):
        if not path.is_file():
            raise SystemExit("Missing test input " + str(path))
    manifest = json.loads((firmware / "build-manifest.json").read_text())
    for path in (variables, code):
        if manifest["files_sha256"][path.name] != sha256(path):
            raise SystemExit("Firmware differs from its generated manifest")
    parent = WORK / "dbx-enforcement"
    parent.mkdir(mode=0o700, exist_ok=True)
    results = parent / str(uuid.uuid4())
    results.mkdir(mode=0o700)
    openssl, openssl_version = find_openssl()
    key, cert = results / "test-key.pem", results / "test-cert.pem"
    run(openssl, "req", "-new", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
        "-days", "2", "-subj", "/CN=Perpendicular isolated DBX canary/",
        "-addext", "extendedKeyUsage=codeSigning", "-addext", "keyUsage=digitalSignature",
        "-keyout", key, "-out", cert)
    key.chmod(0o600)
    media = results / "media"
    media.mkdir(mode=0o700)
    canary = media / "canary.efi"
    run(signer, "sign", "-certs", cert, "-key", key, "-n", "Perpendicular isolated DBX canary",
        "-h", "sha256", "-in", shell, "-out", canary)
    (results / "signature-verification.txt").write_bytes(run(signer, "verify", "-CAfile", cert, "-in", canary))
    canary_hash = run(tools / "python", "-c",
        "import pefile,sys;from virt.peutils.pesign import pe_authenticode_hash;"
        "print(pe_authenticode_hash(pefile.PE(sys.argv[1])).hex())", canary).decode().strip()
    allowed, revoked = results / "allow.fd", results / "revoke.fd"
    run(tools / "virt-fw-vars", "--input", variables, "--output", allowed,
        "--add-db", OWNER, cert)
    run(tools / "virt-fw-vars", "--input", allowed, "--output", revoked,
        "--add-dbx-hash", OWNER, canary_hash)
    for name, path in (("allowed-variables.json", allowed), ("revoked-variables.json", revoked)):
        run(tools / "virt-fw-vars", "--input", path, "--output-json", results / name)
    allowed_document = json.loads((results / "allowed-variables.json").read_text())
    revoked_document = json.loads((results / "revoked-variables.json").read_text())
    preserved_variables(allowed_document, revoked_document)
    (media / "startup.nsh").write_bytes(
        b"echo -off\r\ndmpstore SecureBoot\r\ndmpstore SetupMode\r\n"
        b"fs0:\\canary.efi -nostartup fs0:\\canary.nsh\r\necho PERP_DBX_TEST_DONE\r\n")
    (media / "canary.nsh").write_bytes(b"echo -off\r\necho PERP_DBX_CANARY_EXECUTED\r\nexit\r\n")
    report = {"scope": "isolated firmware semantics; no existing VM inputs",
              "memory_mib": 512, "cpus": 1, "network": False, "tpm": False,
              "openssl": openssl_version, "firmware_code_sha256": sha256(code),
              "factory_variables_sha256": sha256(variables), "canary_authenticode_sha256": canary_hash,
              "canary_signed_file_sha256": sha256(canary), "runtime_update_verified": False,
              "canary_controls_other_variables_identical": True, "tests": []}
    try:
        positive = boot("windows-loader", variables, code, qemu, results, iso=iso,
                        marker="visual-windows-loader")
        report["tests"].append(positive)
        allowed_result = boot("canary-allowed", allowed, code, qemu, results,
                              media=media, marker="PERP_DBX_TEST_DONE")
        if "PERP_DBX_CANARY_EXECUTED" not in allowed_result["serial_text"]:
            raise RuntimeError("The signed canary was not accepted in the allow control")
        report["tests"].append(allowed_result)
        revoked_result = boot("canary-revoked", revoked, code, qemu, results,
                              media=media, marker="Script Error Status: Access Denied")
        text = revoked_result["serial_text"]
        if "PERP_DBX_CANARY_EXECUTED" in text or "Access Denied" not in text:
            raise RuntimeError("The revoked canary was not rejected as expected")
        report["tests"].append(revoked_result)
        report["controlled_hash_dbx_enforcement_verified"] = True
        report["real_microsoft_revoked_image_executed"] = False
        report["auth2_runtime_update_verified"] = False
        if args.auth2:
            probe = WORK / "edk2/source/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/AARCH64/DbxAuthProbe.efi"
            if not probe.is_file():
                raise RuntimeError("Run scripts/build-dbx-auth-probe.sh before --auth2")
            signed_probe = media / "authprobe.efi"
            run(signer, "sign", "-certs", cert, "-key", key, "-n", "Perpendicular isolated Auth2 probe",
                "-h", "sha256", "-in", probe, "-out", signed_probe)
            # A test-only dummy DBX permits observing the signed append. All
            # keys, including the test-only db certificate, remain unchanged.
            dummy = (SHA256_GUID.bytes_le + struct.pack("<III", 76, 0, 48)
                     + uuid.UUID(OWNER).bytes_le + hashlib.sha256(b"").digest())
            patch = results / "auth2-baseline-patch.json"
            patch.write_text(json.dumps({"version": 2, "variables": [{
                "name": "dbx", "guid": str(IMAGE_SECURITY_GUID), "attr": 0x27,
                "data": dummy.hex(), "time": "da070101000000000000000000000000"}]}))
            auth2_variables = results / "auth2-baseline.fd"
            run(tools / "virt-fw-vars", "--input", allowed, "--output", auth2_variables,
                "--set-json", patch)
            (media / "startup.nsh").write_bytes(b"echo -off\r\nfs0:\\authprobe.efi\r\n")
            auth2_result = boot("auth2-runtime", auth2_variables, code, qemu, results,
                               media=media, marker="PERP_AUTH2_PROBE_DONE")
            text = auth2_result["serial_text"]
            report["tests"].append(auth2_result)
            report["auth2_observed"] = auth2_observation(text)
            if report["auth2_observed"]["original"]["code"] != "0x0":
                raise RuntimeError("Microsoft original Auth2 update was rejected by firmware: "
                                   + str(report["auth2_observed"]["original"]))
            if (not re.search(r"PERP_AUTH2_ORIGINAL_STATUS=[^\n]*CODE=0\b", text)
                    or not re.search(r"PERP_AUTH2_TAMPER_STATUS=[^\n]*CODE=800000000000001a\b", text, re.I)
                    or "PERP_AUTH2_TAMPER_UNCHANGED=1" not in text
                    or "PERP_AUTH2_REPLAY_UNCHANGED=1" not in text):
                raise RuntimeError("Auth2 firmware results did not satisfy the isolation/authentication checks")
            replay = re.search(r"PERP_AUTH2_REPLAY_STATUS=([^\n]+)", text).group(1)
            report["auth2_runtime_update_verified"] = True
            report["runtime_update_verified"] = True
            report["auth2_replay"] = {"firmware_status": replay, "dbx_unchanged": True,
                                     "scope": "exact signed append repeated; append replay can be idempotent"}
            readback = results / "auth2-readback.json"
            run(tools / "virt-fw-vars", "--input", results / "auth2-runtime/vars.fd",
                "--output-json", readback)
            final_variables = {entry["name"]: entry for entry in json.loads(readback.read_text())["variables"]}
            allowed_variables = {entry["name"]: entry for entry in allowed_document["variables"]}
            for name in ("PK", "KEK", "db"):
                if final_variables[name] != allowed_variables[name]:
                    raise RuntimeError("Auth2 test changed a protected key variable")
            entries = signature_entries(bytes.fromhex(final_variables["dbx"]["data"]))
            report["auth2_final_dbx_entry_count"] = len(entries)
    except Exception as error:
        report["error"] = {"code": "firmware_test_failed", "message": str(error)}
        raise
    finally:
        report["all_owned_qemu_children_reaped"] = True
        report["source_variables_unchanged"] = sha256(variables) == report["factory_variables_sha256"]
        (results / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Isolated DBX results:", results)


if __name__ == "__main__":
    def cancel_owned_test(_signal, _frame):
        global CANCELLED
        # Defer exceptions until the child handle has been assigned. Raising
        # asynchronously between Popen and assignment could orphan a child.
        CANCELLED = True
    signal.signal(signal.SIGINT, cancel_owned_test)
    signal.signal(signal.SIGTERM, cancel_owned_test)
    main()
