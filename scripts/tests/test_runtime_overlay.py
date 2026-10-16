import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("bundle_runtime", Path(__file__).parents[1] / "bundle-runtime.py")
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)


class RuntimeOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="perp-overlay-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.binary = self.root / "private/qemu-system-aarch64"
        self.binary.parent.mkdir()
        self.binary.write_bytes(bytes.fromhex("cffaedfe0c000001") + b"synthetic test payload")
        self.binary.chmod(0o700)
        self.archive = self.root / "qemu.tar.xz"
        self.archive.write_bytes(b"synthetic archive")
        self.patch_file = self.root / "source/display.patch"
        self.patch_file.parent.mkdir()
        self.patch_file.write_text("synthetic source patch\n")
        self.notice = self.root / "source/README.md"
        self.notice.write_text("synthetic GPL attribution\n")
        self.report = {
            "schema": 1, "qemu_version": "11.1.2",
            "upstream_archive": {"path": "qemu.tar.xz", "sha256": bundle.digest(self.archive)},
            "candidate": {"path": "private/qemu-system-aarch64", "sha256": bundle.digest(self.binary),
                          "qa_probe_present": False},
            "production_patches": [{"path": "source/display.patch", "sha256": bundle.digest(self.patch_file)}],
            "notices": [{"path": "source/README.md", "license": "GPL-2.0-or-later"}]}
        self.manifest = self.root / "provenance.json"
        patcher = patch.object(bundle, "QEMU_SOURCE_SHA256", bundle.digest(self.archive))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.verified = []

    def select(self, report=None, verify=None):
        self.manifest.write_text(json.dumps(self.report if report is None else report))
        return bundle.display_runtime(self.manifest, self.root, self.verified.append if verify is None else verify)

    def test_selection_checks_actual_candidate_and_retains_patch_notice_manifest(self):
        selected = self.select()
        self.assertEqual(self.verified, [self.binary])
        destination = self.root / "notices"
        bundle.copy_display_notices(selected, destination)
        folder = destination / "PerpendicularRuntime"
        self.assertEqual((folder / "source/display.patch").read_bytes(), self.patch_file.read_bytes())
        self.assertEqual((folder / "source/README.md").read_bytes(), self.notice.read_bytes())
        self.assertEqual(bundle.digest(folder / "provenance.json"), selected["manifest_sha256"])

    def test_source_and_binary_changes_cannot_reuse_the_report(self):
        for path in (self.archive, self.binary, self.patch_file):
            with self.subTest(path=path):
                original = path.read_bytes()
                path.write_bytes(original + b"changed")
                with self.assertRaises(RuntimeError):
                    self.select()
                path.write_bytes(original)

    def test_wrong_version_schema_probe_declaration_and_paths_fail(self):
        mutations = [
            lambda r: r.update(schema=True),
            lambda r: r.update(qemu_version="10.0.12"),
            lambda r: r["candidate"].update(qa_probe_present=True),
            lambda r: r["candidate"].update(qa_probe_present="false"),
            lambda r: r["candidate"].update(path="../qemu-system-aarch64"),
            lambda r: r["candidate"].update(path=str(self.binary)),
            lambda r: r.update(production_patches=[]),
            lambda r: r.update(notices=[]),
            lambda r: r["notices"][0].update(license="")]
        for mutate in mutations:
            report = copy.deepcopy(self.report)
            mutate(report)
            with self.subTest(report=report), self.assertRaises(RuntimeError):
                self.select(report)

    def test_wrong_architecture_and_probe_across_chunk_boundary_fail(self):
        for data in (bytes.fromhex("cffaedfe07000001") + b"x64",
                     bytes.fromhex("cffaedfe0c000001") + bytes(1024 * 1024 - 15) + b"x-input-test-poll"):
            self.binary.write_bytes(data)
            report = copy.deepcopy(self.report)
            report["candidate"]["sha256"] = bundle.digest(self.binary)
            with self.subTest(size=len(data)), self.assertRaises(RuntimeError):
                self.select(report)
        self.assertEqual(self.verified, [])

    def test_signature_failure_is_not_overridden_by_report_booleans(self):
        report = copy.deepcopy(self.report)
        report["candidate"].update(code_signature_verified=True, hypervisor_entitlement=True)
        def reject(_):
            raise RuntimeError("synthetic signature failure")
        with self.assertRaisesRegex(RuntimeError, "signature failure"):
            self.select(report, verify=reject)

    def test_private_dependency_bytes_are_bound_to_the_report(self):
        library = self.binary.parent / "libslirp.0.dylib"
        library.write_bytes(b"synthetic private dependency")
        self.report["build"] = {"private_dependencies": [
            {"path": "private/libslirp.0.dylib", "sha256": bundle.digest(library)}]}
        selected = self.select()
        self.assertEqual(selected["private_dependencies"], {library: bundle.digest(library)})
        library.write_bytes(b"changed dependency")
        with self.assertRaisesRegex(RuntimeError, "dependency identity"):
            self.select()
        self.report["build"]["private_dependencies"][0]["path"] = "../outside.dylib"
        with self.assertRaises(RuntimeError):
            self.select()

    def test_entitlement_output_requires_real_boolean_and_no_extra_privilege(self):
        for values in ({"com.apple.security.hypervisor": 1},
                       {"com.apple.security.hypervisor": False},
                       {"com.apple.security.hypervisor": True, "com.apple.security.get-task-allow": True}, {}):
            outputs = [subprocess.CompletedProcess([], 0, b""),
                       subprocess.CompletedProcess([], 0, plistlib.dumps(values))]
            with self.subTest(values=values), patch.object(bundle.subprocess, "run", side_effect=outputs), self.assertRaises(RuntimeError):
                bundle.verify_candidate(self.binary)

    def test_invalid_selection_refuses_before_creating_an_app(self):
        self.manifest.write_text('{"schema":1,"qemu_version":"10.0.12"}')
        app = self.root / "Untouched.app"
        arguments = ["bundle-runtime.py", str(app), str(self.root / "prefix"),
                     "--display-runtime-manifest", str(self.manifest)]
        with patch.object(bundle.sys, "argv", arguments), self.assertRaises(RuntimeError):
            bundle.main()
        self.assertFalse(app.exists())

    def test_bounded_duplicate_report_and_repository_escape_fail(self):
        self.manifest.write_text('{"schema":1,"schema":1}')
        with self.assertRaisesRegex(RuntimeError, "Duplicate"):
            bundle.display_runtime(self.manifest, self.root, self.verified.append)
        self.manifest.write_bytes(bytes(4 * 1024 * 1024 + 1))
        with self.assertRaisesRegex(RuntimeError, "bound"):
            bundle.display_runtime(self.manifest, self.root, self.verified.append)
        link = self.root / "source/outside"
        link.symlink_to(self.root.parent)
        with self.assertRaises(RuntimeError):
            bundle.repo_file("outside/" + self.root.name + "/provenance.json", self.root / "source")

    def test_notice_and_manifest_changes_during_packaging_are_detected(self):
        for target in (self.patch_file, self.notice, self.manifest):
            with self.subTest(target=target):
                selected = self.select()
                original = target.read_bytes()
                target.write_bytes(original + b"changed")
                with self.assertRaises(RuntimeError):
                    bundle.copy_display_notices(selected, self.root / "notices")
                target.write_bytes(original)


if __name__ == "__main__":
    unittest.main()
