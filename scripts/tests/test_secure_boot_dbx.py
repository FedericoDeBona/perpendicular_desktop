"""DBX parser, provenance and preservation tests; no QEMU or live stores."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import uuid

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import secure_boot_dbx as dbx


def signature_list(values, kind=dbx.SHA256_GUID, owner=dbx.MICROSOFT_OWNER):
    size = 16 + len(values[0])
    body = b"".join(owner.bytes_le + value for value in values)
    return kind.bytes_le + struct.pack("<III", 28 + len(body), 0, size) + body


def auth_update(payload, signature=bytes.fromhex("3003020101")):
    timestamp = struct.pack("<HBBBBBxIhBx", 2010, 3, 6, 19, 17, 21, 0, 0, 0)
    return (timestamp + struct.pack("<IHH", 24 + len(signature), 0x200, 0xEF1)
            + dbx.PKCS7_GUID.bytes_le + signature + payload)


class ParserTests(unittest.TestCase):
    def test_signature_bounds_and_non_hash_payloads_are_rejected(self):
        payload = signature_list([b"a" * 32, b"b" * 32])
        self.assertEqual(dbx.dbx_hashes(payload), {(b"a" * 32).hex(), (b"b" * 32).hex()})
        malformed = [b"", payload[:27], payload[:-1], payload + b"tail",
                     signature_list([b"a" * 32, b"a" * 32]),
                     signature_list([b"a" * 32], kind=dbx.X509_GUID),
                     signature_list([b"a" * 32], owner=uuid.UUID(int=0)),
                     signature_list([b"a" * 31])]
        for offset, value in [(16, 0xFFFFFFFF), (20, 0xFFFFFFFF), (24, 0), (24, 17)]:
            altered = bytearray(payload)
            struct.pack_into("<I", altered, offset, value)
            malformed.append(bytes(altered))
        for value in malformed:
            with self.subTest(value=value[:32].hex()), self.assertRaises(ValueError):
                dbx.dbx_hashes(value)

    def test_authentication_framing_rejects_invalid_lengths_guids_and_time(self):
        valid = auth_update(signature_list([b"a" * 32]))
        parsed = dbx.authenticated_update(valid)
        self.assertEqual(parsed["timestamp"], "2010-03-06T19:17:21+00:00")
        malformed = [valid[:39], valid[:45]]
        for offset, value in [(16, b"\xff\xff\xff\xff"), (20, b"\0\0"),
                              (24, b"\0" * 16), (7, b"\1"), (2, b"\r")]:
            altered = bytearray(valid)
            altered[offset:offset + len(value)] = value
            malformed.append(bytes(altered))
        for value in malformed:
            with self.subTest(value=value[:40].hex()), self.assertRaises(ValueError):
                dbx.authenticated_update(value)
        with self.assertRaises(ValueError):
            dbx.pkcs7_content_info(b"\x30\x82\xff\xff\x02\x01\x01")

    def test_non_dbx_variables_are_preserved_byte_for_byte(self):
        before = {"variables": [{"name": name, "guid": str(uuid.UUID(int=i)),
                                 "attr": 39, "data": "1234"}
                                for i, name in enumerate(("PK", "KEK", "db", "dbx"))]}
        after = copy.deepcopy(before)
        after["variables"][-1]["data"] = "abcd"
        dbx.preserved_variables(before, after)
        for name in ("PK", "KEK", "db"):
            altered = copy.deepcopy(after)
            next(value for value in altered["variables"] if value["name"] == name)["data"] = "ffff"
            with self.assertRaises(ValueError):
                dbx.preserved_variables(before, altered)
        after["variables"].append(dict(before["variables"][0]))
        with self.assertRaises(ValueError):
            dbx.preserved_variables(before, after)

    def test_source_cache_hashes_bounds_symlinks_and_atomic_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            content = b"verified Microsoft fixture"
            source = {"filename": "source.bin", "sha256": dbx.digest(content),
                      "maximum_bytes": len(content), "url": "https://example.invalid/source"}
            with mock.patch("urllib.request.urlopen", return_value=io.BytesIO(content)):
                self.assertEqual(dbx._load_source(source, cache, False), content)
            self.assertEqual((cache / "source.bin").read_bytes(), content)
            (cache / "source.bin").write_bytes(b"tampered cache")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                dbx._load_source(source, cache, True)
            self.assertEqual((cache / "source.bin").read_bytes(), b"tampered cache")
            (cache / "source.bin").unlink()
            with self.assertRaisesRegex(ValueError, "Offline"):
                dbx._load_source(source, cache, True)
            (cache / "source.bin").symlink_to(cache / "missing")
            with self.assertRaisesRegex(ValueError, "symlink"):
                dbx._load_source(source, cache, True)

    def test_complete_factory_and_signed_subset_coverage_is_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            first, optional = b"a" * 32, b"b" * 32
            payload = signature_list([first, optional])
            receipt = {"fileHash": dbx.digest(payload), "signatureDatabase": [
                {"authenticodeHash": value.hex(), "signatureOwner": str(dbx.MICROSOFT_OWNER)}
                for value in (first, optional)]}
            archive_data = io.BytesIO()
            with tarfile.open(fileobj=archive_data, mode="w:gz") as archive:
                for name, value in (("default.bin", payload), ("default.json", json.dumps(receipt).encode())):
                    item = tarfile.TarInfo(name)
                    item.size = len(value)
                    archive.addfile(item, io.BytesIO(value))
            sources = {
                "firmware_archive": archive_data.getvalue(),
                "signed_dbx": auth_update(signature_list([first])),
                "source_receipt": json.dumps({"images": {"aarch64": [
                    {"authenticodeHash": first.hex(), "hashType": "SHA256"},
                    {"authenticodeHash": optional.hex(), "hashType": "SHA256", "isOptional": "true"}]}}).encode(),
                "license": b"test license",
            }
            lock = {"format_version": 1, "architecture": "aarch64", "repository": "test",
                    "release": "test", "signed_release": "test-signed", "commit": "test",
                    "checked_at": "2026-10-15", "license": "BSD-2-Clause-Patent",
                    "default_dbx_member": "default.bin", "default_dbx_receipt_member": "default.json",
                    "default_dbx_sha256": dbx.digest(payload), "default_dbx_hash_count": 2,
                    "signed_dbx_hash_count": 1, "optional_image_hash_count": 1,
                    "kek_2023_certificate_sha256": "test", "sources": {}}
            for name, value in sources.items():
                (directory / name).write_bytes(value)
                lock["sources"][name] = {"filename": name, "url": "https://example.invalid/" + name,
                                         "sha256": dbx.digest(value), "maximum_bytes": 65536}
            lock_path = directory / "lock.json"
            lock_path.write_text(json.dumps(lock))
            with mock.patch.object(dbx, "find_openssl", return_value=("openssl", "OpenSSL 3.test")), \
                    mock.patch.object(dbx, "verify_signed_update"):
                actual, _, report = dbx.load_factory_dbx(lock_path, directory, b"", offline=True)
                self.assertEqual(actual, payload)
                self.assertEqual(report["image_hash_count"], 2)
                self.assertFalse(report["authentication"]["full_factory_payload_is_signed_update"])
                lock["signed_dbx_hash_count"] = 2
                lock_path.write_text(json.dumps(lock))
                with self.assertRaisesRegex(ValueError, "coverage"):
                    dbx.load_factory_dbx(lock_path, directory, b"", offline=True)

    def test_notices_require_license_and_clear_stale_template_metadata(self):
        spec = importlib.util.spec_from_file_location("bundle_runtime", SCRIPTS / "bundle-runtime.py")
        bundle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bundle)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            share, notices, packaged = root / "share", root / "notices", root / "packaged"
            for directory in (share, notices, packaged):
                directory.mkdir()
            (share / "microsoft-dbx-provenance.json").write_text('{"release":"fixture"}')
            with self.assertRaisesRegex(RuntimeError, "license"):
                bundle.copy_dbx_notices(share, notices, packaged)
            (share / "microsoft-secureboot-objects-licenses.txt").write_text("fixture license")
            bundle.copy_dbx_notices(share, notices, packaged)
            self.assertEqual((notices / "microsoft-secureboot-objects-licenses.txt").read_text(), "fixture license")
            (share / "microsoft-dbx-provenance.json").unlink()
            (packaged / "microsoft-arm64-dbx.esl").write_bytes(b"old template")
            bundle.copy_dbx_notices(share, notices, packaged)
            self.assertFalse((notices / "microsoft-dbx-provenance.json").exists())
            self.assertFalse((packaged / "microsoft-arm64-dbx.esl").exists())

    def test_firmware_auth2_rejection_is_not_reported_as_verified_or_replayed(self):
        spec = importlib.util.spec_from_file_location("dbx_enforcement", SCRIPTS / "test-dbx-enforcement.py")
        enforcement = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(enforcement)
        observed = enforcement.auth2_observation(
            "PERP_SECURE_BOOT=1 STATUS=Success\n"
            "PERP_AUTH2_ORIGINAL_STATUS=Security Violation CODE=800000000000001A\n")
        self.assertEqual(observed["original"], {"status": "Security Violation", "code": "0x800000000000001a"})
        self.assertEqual(observed["tamper"]["status"], "not_executed")
        self.assertEqual(observed["replay"]["status"], "not_executed")
        self.assertFalse(observed["tamper_unchanged"])
        self.assertFalse(observed["replay_unchanged"])

    def test_provisioning_keeps_dbx_license_and_provenance_together_in_an_isolated_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            script = root / "scripts/provision-secure-firmware.sh"
            script.write_bytes((SCRIPTS / script.name).read_bytes())
            source = root / "firmware"
            source.mkdir()
            for name in ("edk2-aarch64-secure-code.fd", "edk2-arm-secure-vars.fd", "edk2-licenses.txt"):
                (source / name).write_bytes(name.encode())
            report = source / "microsoft-dbx-provenance.json"
            report.write_text('{"release":"fixture"}')
            failed = subprocess.run(["/bin/bash", str(script), str(source)], capture_output=True)
            self.assertNotEqual(failed.returncode, 0)
            target = root / ".tools/qemu/share/qemu"
            self.assertFalse(target.exists(), "fail before provisioning incomplete DBX artifacts")
            for name in ("microsoft-secureboot-objects-LICENSE", "microsoft-arm64-dbx.esl",
                         "microsoft-arm64-dbx-signed-subset.efiauth2"):
                (source / name).write_bytes(name.encode())
            subprocess.run(["/bin/bash", str(script), str(source)], check=True, capture_output=True)
            self.assertEqual((target / report.name).read_bytes(), report.read_bytes())
            self.assertTrue((target / "microsoft-secureboot-objects-licenses.txt").is_file())
            report.unlink()
            subprocess.run(["/bin/bash", str(script), str(source)], check=True, capture_output=True)
            self.assertFalse((target / "microsoft-dbx-provenance.json").exists())


@unittest.skipUnless(os.environ.get("PERPENDICULAR_TEST_DBX") == "1",
                     "requires cached official Microsoft sources and firmware tooling")
class RealMicrosoftTests(unittest.TestCase):
    def test_official_release_authenticates_and_tampering_or_wrong_key_is_rejected(self):
        root = SCRIPTS.parent
        cache = root / ".tools/downloads/microsoft-dbx"
        baseline = json.loads((root / ".tools/edk2/enrolled/variables.json").read_text())
        kek = bytes.fromhex(next(value for value in baseline["variables"] if value["name"] == "KEK")["data"])
        payload, sources, report = dbx.load_factory_dbx(
            SCRIPTS / "secure-boot-dbx-sources.json", cache, kek, offline=True)
        self.assertEqual(len(dbx.dbx_hashes(payload)), 26)
        self.assertEqual(report["authentication"]["signed_image_hash_count"], 22)
        self.assertFalse(report["guest_revocation_enforcement_verified"])
        openssl, _ = dbx.find_openssl()
        update = dbx.authenticated_update(sources["signed_dbx"])
        anchor = report["authentication"]["authority_certificate_sha256"]
        for field in ("payload", "signature", "timestamp_bytes"):
            altered = dict(update)
            value = bytearray(update[field])
            value[-1] ^= 1
            altered[field] = bytes(value)
            with self.subTest(field=field), self.assertRaises(ValueError):
                dbx.verify_signed_update(altered, kek, anchor, openssl)
        with self.assertRaisesRegex(ValueError, "not enrolled"):
            dbx.verify_signed_update(update, kek, "0" * 64, openssl)


if __name__ == "__main__":
    unittest.main()
