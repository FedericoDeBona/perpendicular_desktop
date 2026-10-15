"""Pinned Microsoft ARM64 DBX factory defaults; never a live-variable updater."""
import base64
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import urllib.request
import uuid

IMAGE_SECURITY_GUID = uuid.UUID("d719b2cb-3d3a-4596-a3bc-dad00e67656f")
SHA256_GUID = uuid.UUID("c1c41626-504c-4092-aca9-41f936934328")
X509_GUID = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
PKCS7_GUID = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7")
MICROSOFT_OWNER = uuid.UUID("77fa9abd-0359-4d32-bd60-28f4e78f784b")
APPEND_ATTRIBUTES = 0x67


def digest(data):
    return hashlib.sha256(data).hexdigest()


def signature_entries(data):
    """Decode bounded EFI_SIGNATURE_LIST records without trusting their lengths."""
    entries, position = [], 0
    if not data or len(data) > 1024 * 1024:
        raise ValueError("Signature database is empty or exceeds 1 MiB")
    while position < len(data):
        if len(data) - position < 28:
            raise ValueError("Truncated EFI signature list header")
        kind = uuid.UUID(bytes_le=data[position:position + 16])
        size, header_size, signature_size = struct.unpack_from("<III", data, position + 16)
        if (size <= 28 + header_size or signature_size <= 16
                or position + size > len(data)
                or (size - 28 - header_size) % signature_size):
            raise ValueError("Invalid EFI signature list bounds/alignment")
        for offset in range(position + 28 + header_size, position + size, signature_size):
            owner = uuid.UUID(bytes_le=data[offset:offset + 16])
            entries.append((kind, owner, data[offset + 16:offset + signature_size]))
        position += size
    return entries


def dbx_hashes(data):
    entries = signature_entries(data)
    if any(kind != SHA256_GUID or owner != MICROSOFT_OWNER or len(value) != 32
           for kind, owner, value in entries):
        raise ValueError("ARM64 factory DBX must contain Microsoft-owned SHA-256 hashes only")
    hashes = {value.hex() for _, _, value in entries}
    if len(hashes) != len(entries):
        raise ValueError("Duplicate DBX image hash")
    return hashes


def authenticated_update(data):
    """Separate an EFI_VARIABLE_AUTHENTICATION_2 envelope from its ESL payload."""
    if len(data) < 40:
        raise ValueError("Truncated authenticated DBX update")
    length, revision, kind = struct.unpack_from("<IHH", data, 16)
    if (revision != 0x200 or kind != 0xEF1 or length <= 24
            or 16 + length >= len(data) or uuid.UUID(bytes_le=data[24:40]) != PKCS7_GUID):
        raise ValueError("Invalid authenticated DBX update header")
    year, month, day, hour, minute, second, nanos, zone, daylight = struct.unpack_from(
        "<HBBBBBxIhBx", data)
    if data[7] != 0 or data[15] != 0 or nanos != 0 or zone != 0 or daylight != 0:
        raise ValueError("DBX update timestamp is not canonical UTC")
    timestamp = datetime.datetime(year, month, day, hour, minute, second,
                                  tzinfo=datetime.timezone.utc)
    payload = data[16 + length:]
    dbx_hashes(payload)
    return {
        "timestamp_bytes": data[:16],
        "timestamp": timestamp.isoformat(),
        "signature": data[40:16 + length],
        "payload": payload,
    }


def _der_length(length):
    encoded = length.to_bytes(max(1, (length.bit_length() + 7) // 8), "big")
    return bytes([length]) if length < 128 else bytes([0x80 + len(encoded)]) + encoded


def pkcs7_content_info(signature):
    # Microsoft Auth2 envelopes store bare SignedData, while `openssl cms`
    # expects ContentInfo. EDK2's Pkcs7Verify performs the same wrapper step.
    if len(signature) < 4 or signature[0] != 0x30:
        raise ValueError("Invalid PKCS7 SignedData")
    length_byte = signature[1]
    length_size = 1 if length_byte < 128 else 1 + (length_byte & 0x7F)
    if length_size > 5 or len(signature) <= 1 + length_size:
        raise ValueError("Invalid DER length")
    declared = length_byte if length_byte < 128 else int.from_bytes(signature[2:1 + length_size], "big")
    if declared != len(signature) - 1 - length_size:
        raise ValueError("Truncated or trailing DER SignedData")
    if signature[1 + length_size] == 0x06:
        return signature
    if signature[1 + length_size] != 0x02:
        raise ValueError("Expected bare PKCS7 SignedData")
    content = (bytes.fromhex("06092a864886f70d010702") + b"\xa0"
               + _der_length(len(signature)) + signature)
    return b"\x30" + _der_length(len(content)) + content


def find_openssl(explicit=None):
    selected = explicit or "/opt/homebrew/opt/openssl@3/bin/openssl"
    if not Path(selected).is_file():
        if explicit:
            raise ValueError("Explicit OpenSSL executable does not exist")
        selected = shutil.which("openssl")
    if not selected:
        raise ValueError("OpenSSL 3 is required for authenticated DBX verification")
    version = subprocess.check_output([selected, "version"], text=True).strip()
    if not version.startswith("OpenSSL 3."):
        raise ValueError("Use OpenSSL 3 for DBX verification; the macOS LibreSSL CLI lacks required validation flags")
    return str(selected), version


def verify_signed_update(update, kek_payload, anchor_sha256, openssl):
    """Verify CMS and signer chain against the exact enrolled Microsoft 2023 KEK.

    No OS CA store, downloaded substitute root, or -noverify is accepted. UEFI
    checks key authority rather than certificate wall-clock validity; the flags
    match the project's EDK2 Pkcs7Verify policy (partial chain/no check time).
    """
    anchors = [value for kind, _, value in signature_entries(kek_payload)
               if kind == X509_GUID and digest(value) == anchor_sha256]
    if len(anchors) != 1:
        raise ValueError("The expected Microsoft KEK 2023 certificate is not enrolled exactly once")
    signable = ("dbx".encode("utf-16le") + IMAGE_SECURITY_GUID.bytes_le
                + struct.pack("<I", APPEND_ATTRIBUTES)
                + update["timestamp_bytes"] + update["payload"])
    with tempfile.TemporaryDirectory(prefix="perpendicular-dbx-verify-") as temporary:
        directory = Path(temporary)
        (directory / "signature.der").write_bytes(pkcs7_content_info(update["signature"]))
        (directory / "signable.bin").write_bytes(signable)
        (directory / "anchor.pem").write_bytes(
            b"-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(anchors[0])
            + b"-----END CERTIFICATE-----\n")
        result = subprocess.run([
            openssl, "cms", "-verify", "-binary", "-inform", "DER",
            "-in", str(directory / "signature.der"),
            "-content", str(directory / "signable.bin"),
            "-CAfile", str(directory / "anchor.pem"), "-no-CApath", "-no-CAstore",
            "-purpose", "any", "-partial_chain", "-no_check_time", "-out", "/dev/null"],
            capture_output=True, timeout=30)
        if result.returncode:
            raise ValueError("Microsoft DBX signature/KEK authority verification failed: "
                             + result.stderr.decode(errors="replace")[:2048])


def _load_source(source, cache, offline):
    path = cache / source["filename"]
    maximum = source["maximum_bytes"]
    if path.is_symlink():
        raise ValueError("Refusing symlinked Microsoft DBX cache file")
    if path.exists():
        if not path.is_file() or path.stat().st_size > maximum:
            raise ValueError("Invalid Microsoft DBX cached source")
        data = path.read_bytes()
    else:
        if offline:
            raise ValueError("Offline DBX source is missing: " + path.name)
        with urllib.request.urlopen(source["url"], timeout=45) as response:
            data = response.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError("Microsoft DBX source exceeds its download bound")
        if digest(data) != source["sha256"]:
            raise ValueError("Microsoft DBX source SHA-256 mismatch: " + path.name)
        with tempfile.NamedTemporaryFile(prefix="download-", dir=cache, delete=False) as temporary:
            temporary.write(data)
            downloaded = Path(temporary.name)
        try:
            # Hard-link publication refuses any existing entry, including a
            # symlink that appeared while this source was downloading.
            try:
                os.link(downloaded, path)
            except FileExistsError:
                pass
        finally:
            downloaded.unlink()
        if not path.is_file() or path.is_symlink() or digest(path.read_bytes()) != source["sha256"]:
            raise ValueError("Microsoft DBX cache changed during download")
    if digest(data) != source["sha256"]:
        raise ValueError("Microsoft DBX source SHA-256 mismatch: " + path.name)
    return data


def load_factory_dbx(lock_path, cache, kek_payload, offline=False, openssl=None):
    lock = json.loads(Path(lock_path).read_text())
    if lock.get("format_version") != 1 or lock.get("architecture") != "aarch64":
        raise ValueError("Unsupported DBX source lock or architecture")
    cache = Path(cache)
    if cache.is_symlink():
        raise ValueError("Refusing symlinked DBX cache directory")
    cache.mkdir(parents=True, exist_ok=True)
    sources = {name: _load_source(source, cache, offline)
               for name, source in lock["sources"].items()}
    with tarfile.open(fileobj=io.BytesIO(sources["firmware_archive"]), mode="r:gz") as archive:
        def member(name):
            matches = [item for item in archive.getmembers() if item.name == name]
            if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 65536:
                raise ValueError("Missing, duplicate or oversized DBX release archive member")
            return archive.extractfile(matches[0]).read(65537)
        payload = member(lock["default_dbx_member"])
        receipt = json.loads(member(lock["default_dbx_receipt_member"]))
    hashes = dbx_hashes(payload)
    receipt_hashes = {entry["authenticodeHash"].lower() for entry in receipt["signatureDatabase"]}
    receipt_owners = {entry["signatureOwner"].lower() for entry in receipt["signatureDatabase"]}
    if (digest(payload) != lock["default_dbx_sha256"]
            or receipt.get("fileHash", "").lower() != digest(payload)
            or hashes != receipt_hashes or len(receipt["signatureDatabase"]) != len(hashes)
            or receipt_owners != {str(MICROSOFT_OWNER)}
            or len(hashes) != lock["default_dbx_hash_count"]):
        raise ValueError("ARM64 factory DBX differs from its pinned release or receipt")
    source = json.loads(sources["source_receipt"])
    arm = source["images"]["aarch64"]
    if any(entry.get("hashType") != "SHA256" for entry in arm):
        raise ValueError("Unsupported ARM64 DBX source hash type")
    expected = {entry["authenticodeHash"].lower() for entry in arm}
    optional = {entry["authenticodeHash"].lower() for entry in arm
                if entry.get("isOptional") in (True, "true")}
    update = authenticated_update(sources["signed_dbx"])
    signed_hashes = dbx_hashes(update["payload"])
    if (hashes != expected or len(optional) != lock["optional_image_hash_count"]
            or signed_hashes != hashes - optional
            or len(signed_hashes) != lock["signed_dbx_hash_count"]):
        raise ValueError("Firmware/default and signed ARM64 DBX coverage differs from Microsoft receipts")
    openssl, openssl_version = find_openssl(openssl)
    verify_signed_update(update, kek_payload, lock["kek_2023_certificate_sha256"], openssl)
    report = {
        "source_repository": lock["repository"], "release": lock["release"],
        "signed_release": lock["signed_release"], "commit": lock["commit"],
        "checked_at": lock["checked_at"], "architecture": lock["architecture"],
        "profile": "Microsoft ARM64 factory SHA-256 revocations",
        "payload_sha256": digest(payload), "payload_bytes": len(payload),
        "image_hash_count": len(hashes), "optional_legacy_image_hash_count": len(optional),
        "certificate_revocation_count": 0, "svn_revocation_count": 0,
        "authentication": {
            "signed_subset_verified": True, "signed_image_hash_count": len(signed_hashes),
            "full_factory_payload_is_signed_update": False,
            "authority": "already enrolled Microsoft Corporation KEK 2K CA 2023",
            "authority_certificate_sha256": lock["kek_2023_certificate_sha256"],
            "attributes": APPEND_ATTRIBUTES, "timestamp": update["timestamp"],
            "openssl_version": openssl_version,
            "certificate_time_policy": "EDK2 Pkcs7Verify partial-chain/no-check-time",
        },
        "sources": lock["sources"], "license": lock["license"],
        "scope": "offline factory template for new VMs only",
        "guest_revocation_enforcement_verified": False,
        "live_update_or_migration_verified": False,
    }
    return payload, sources, report


def preserved_variables(before, after):
    """DBX replacement must not change even one other variable's public bytes."""
    def indexed(document):
        result = {(entry["name"], entry["guid"]): entry for entry in document["variables"]}
        if len(result) != len(document["variables"]):
            raise ValueError("Duplicate firmware variable identity")
        return {key: value for key, value in result.items() if key[0] != "dbx"}
    if indexed(before) != indexed(after):
        raise ValueError("Offline DBX provisioning unexpectedly changed another firmware variable")
