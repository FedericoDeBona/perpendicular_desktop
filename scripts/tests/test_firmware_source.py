"""Strict source patch validation; no downloads, firmware or VM execution."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import firmware_source


class FirmwareSourceTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        source = root / "source"
        source.mkdir()
        old = b"prefix\r\n#define MIN_REQUIRED_BLOCKS  600\r\nsuffix\r\n"
        new = old.replace(b"600", b"1100")
        (source / "runtime.c").write_bytes(old)
        patch = b"-#define MIN_REQUIRED_BLOCKS  600\r\n+#define MIN_REQUIRED_BLOCKS  1100\r\n"
        (root / "fix.patch").write_bytes(patch)
        lock = {"format_version": 1, "base_source": {"url": "fixture", "sha256": "fixture"},
                "patches": [{"source_file": "runtime.c", "patch_file": "fix.patch",
                             "old_line": "#define MIN_REQUIRED_BLOCKS  600",
                             "new_line": "#define MIN_REQUIRED_BLOCKS  1100",
                             "patch_sha256": hashlib.sha256(patch).hexdigest(),
                             "preimage_sha256": hashlib.sha256(old).hexdigest(),
                             "postimage_sha256": hashlib.sha256(new).hexdigest()}]}
        path = root / "lock.json"
        path.write_text(json.dumps(lock))
        return source, path, lock, old, new

    def test_application_preserves_bytes_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, lock, _, _, expected = self.fixture(temporary)
            receipt = firmware_source.apply_patches(source, lock)
            self.assertEqual(receipt["applications"][0]["action"], "applied")
            self.assertEqual((source / "runtime.c").read_bytes(), expected)
            second = firmware_source.apply_patches(source, lock)
            self.assertEqual(second["applications"][0]["action"], "already_applied")
            self.assertEqual(receipt["patches"], second["patches"])

    def test_unexpected_preimage_and_altered_patch_leave_source_intact(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, lock, _, original, _ = self.fixture(temporary)
            path = source / "runtime.c"
            path.write_bytes(original + b"unexpected edit")
            with self.assertRaisesRegex(ValueError, "preimage"):
                firmware_source.apply_patches(source, lock)
            self.assertEqual(path.read_bytes(), original + b"unexpected edit")
            path.write_bytes(original)
            (Path(temporary) / "fix.patch").write_bytes(b"changed upstream patch")
            with self.assertRaisesRegex(ValueError, "patch SHA-256"):
                firmware_source.apply_patches(source, lock)
            self.assertEqual(path.read_bytes(), original)

    def test_bad_postimage_and_symlinked_or_escaping_source_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, path, lock, original, _ = self.fixture(temporary)
            lock["patches"][0]["postimage_sha256"] = "0" * 64
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, "postimage"):
                firmware_source.apply_patches(source, path)
            self.assertEqual((source / "runtime.c").read_bytes(), original)
            outside = Path(temporary) / "outside.c"
            outside.write_bytes(original)
            (source / "runtime.c").unlink()
            (source / "runtime.c").symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "symlink"):
                firmware_source.apply_patches(source, path)
            lock["patches"][0]["source_file"] = "../outside.c"
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, "source path"):
                firmware_source.apply_patches(source, path)
            self.assertEqual(outside.read_bytes(), original)

    def test_published_patch_is_pinned_and_has_only_the_reviewed_replacement(self):
        path = Path(firmware_source.DEFAULT_LOCK)
        lock = json.loads(path.read_text())
        self.assertEqual(len(lock["patches"]), 1)
        entry = lock["patches"][0]
        patch = (path.parent / entry["patch_file"]).read_bytes()
        self.assertEqual(hashlib.sha256(patch).hexdigest(), entry["patch_sha256"])
        changed = [line for line in patch.splitlines()
                   if line[:1] in [b"+", b"-"] and not line.startswith((b"+++", b"---"))]
        self.assertEqual(changed, [b"-" + entry["old_line"].encode(), b"+" + entry["new_line"].encode()])
        self.assertIn(entry["upstream_commit"].encode(), patch)


if __name__ == "__main__":
    unittest.main()
