"""Apply the pinned, single-line upstream EDK2 fix without relaxing verification."""
import argparse
import hashlib
import json
from pathlib import Path

DEFAULT_LOCK = Path(__file__).with_name("firmware-source-patches.json")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def apply_patches(source, lock_path=DEFAULT_LOCK):
    source, lock_path = Path(source).resolve(), Path(lock_path).resolve()
    lock = json.loads(lock_path.read_text())
    if lock.get("format_version") != 1 or len(lock.get("patches", [])) != 1:
        raise ValueError("Unsupported firmware patch lock")
    applications = []
    for entry in lock["patches"]:
        patch = lock_path.parent / entry["patch_file"]
        if patch.is_symlink() or sha256(patch.read_bytes()) != entry["patch_sha256"]:
            raise ValueError("Upstream firmware patch SHA-256 mismatch")
        relative = Path(entry["source_file"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid firmware patch source path")
        path = source / relative
        if any(parent.is_symlink() for parent in [path, *path.parents] if parent != source):
            raise ValueError("Refusing symlinked firmware patch source")
        before = path.read_bytes()
        old, new = entry["old_line"].encode(), entry["new_line"].encode()
        # This deliberately supports only the reviewed one-line patch. Its
        # original upstream mail patch is retained verbatim and hash pinned.
        lines = patch.read_bytes().splitlines()
        if b"-" + old not in lines or b"+" + new not in lines:
            raise ValueError("Firmware patch replacement differs from upstream")
        current = sha256(before)
        if current == entry["postimage_sha256"]:
            action = "already_applied"
        elif current == entry["preimage_sha256"]:
            if before.count(old) != 1:
                raise ValueError("Firmware patch preimage line is not unique")
            after = before.replace(old, new, 1)
            if sha256(after) != entry["postimage_sha256"]:
                raise ValueError("Firmware patch postimage SHA-256 mismatch")
            path.write_bytes(after)
            action = "applied"
        else:
            raise ValueError("Unexpected firmware source preimage; refusing to patch")
        applications.append({"source_file": str(relative), "action": action,
                             "result_sha256": entry["postimage_sha256"]})
    return {"format_version": 1, "base_source": lock["base_source"],
            "patches": lock["patches"], "applications": applications}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    receipt = apply_patches(args.source)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
