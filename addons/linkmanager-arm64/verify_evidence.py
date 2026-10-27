#!/usr/bin/env python3
"""Verify the portable static-analysis inputs without executing target code."""

import hashlib
import json
from pathlib import Path
import sys


def check(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "evidence/manifest.json").read_text(encoding="utf-8"))
    for item in manifest["files"]:
        relative = Path(item["path"])
        check(not relative.is_absolute() and ".." not in relative.parts,
              "Unsafe manifest path: " + item["path"])
        path = root / relative
        data = path.read_bytes()
        check(len(data) == item["size"], "Size mismatch: " + item["path"])
        check(hashlib.sha256(data).hexdigest() == item["sha256"],
              "SHA-256 mismatch: " + item["path"])

    index = json.loads((root / "evidence/evidence-index.json").read_text(encoding="utf-8"))
    check(len(index) == 31, "Expected 31 indexed REA records")
    check(len({item["file"] for item in index}) == 31, "Duplicate record files")
    subjects = {item["sha256"]: item for item in manifest["subjects"]}
    for item in index:
        check(Path(item["file"]).name == item["file"], "Unsafe record filename")
        envelope = json.loads((root / "evidence/rea" / item["file"]).read_text(encoding="utf-8"))
        records = [json.loads(part["text"])
                   for part in envelope["result"]["content"]
                   if part.get("type") == "text"]
        record = next((value for value in records
                       if value.get("evidence_id") == item["evidence_id"]), None)
        check(record is not None, "Missing evidence ID in " + item["file"])
        check(record["operation"] == item["operation"], "Operation mismatch")
        digest = record["subject"]["digest"]["sha256"]
        check(digest in subjects, "No portable input for REA subject " + digest)
        check(record["subject"]["digest"] == item["subject"]["digest"],
              "Subject mismatch in " + item["file"])

    provenance = json.loads((root / "evidence/provenance.json").read_text(encoding="utf-8"))
    for item in provenance["extracted"]:
        path = root / "artifacts/x64" / item["name"]
        check(hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"],
              "Extracted artifact mismatch: " + item["name"])
    inventory = json.loads((root / "evidence/package-inventory.json").read_text(encoding="utf-8"))
    check(inventory["source_sha256"] == provenance["sha256"],
          "Inventory source mismatch")
    check(len(inventory["payloads"]) == 2, "Expected x64 and x86 payloads")
    for payload in inventory["payloads"]:
        check(payload["complete_stream_consumed"], "Partial NSIS inventory")
        check(len(payload["executables"]) == 20, "PE inventory count changed")
        check(len(payload["inf_texts"]) == 9, "INF inventory count changed")
        check(all(pe["machine"] in ("0x14c", "0x8664")
                  for pe in payload["executables"]), "Unexpected PE architecture")
    print("PASS: %d files, 31 REA records, 4 extracted artifacts, 40 PE and 18 INF."
          % len(manifest["files"]))
    print("No Windows program executed; no REA installation required.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, StopIteration) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
