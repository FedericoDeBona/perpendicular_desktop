#!/usr/bin/env python3
"""Package/register existing exact QEMU bytes; never launches the application."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess

REPO = Path(__file__).resolve().parents[2]
PREFIX = REPO / '.tools/graphics-experiment/prefix'
SOURCE = PREFIX / 'bin/qemu-system-aarch64'
SHA = '8d4d5ec3f94f7f8117568a2fbf426499e71636c2b0af3f5854adf19a33e94981'
APP = REPO / '.tools/cocoa-neptune-app/Perpendicular 3D Trial.app'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def code_identity(path):
    data = bytearray(path.read_bytes())
    assert struct.unpack_from('<I', data)[0] == 0xfeedfacf
    count = struct.unpack_from('<I', data, 16)[0]
    offset = 32; signature = None; sections = {}
    for _ in range(count):
        kind, size = struct.unpack_from('<II', data, offset)
        assert size >= 8 and offset + size <= len(data)
        if kind == 0x1d:  # LC_CODE_SIGNATURE: only this payload is excluded.
            assert signature is None
            signature, length = struct.unpack_from('<II', data, offset + 8)
            assert signature + length == len(data)
            data[offset + 8:offset + 16] = b'\0' * 8
        if kind == 0x19:  # LC_SEGMENT_64
            segment = bytes(data[offset + 8:offset + 24]).rstrip(b'\0').decode()
            if segment == '__LINKEDIT':
                # Only signature growth may change these segment sizes.
                data[offset + 32:offset + 40] = b'\0' * 8
                data[offset + 48:offset + 56] = b'\0' * 8
            number = struct.unpack_from('<I', data, offset + 64)[0]
            for index in range(number):
                section = offset + 72 + index * 80
                name = bytes(data[section:section + 16]).rstrip(b'\0').decode()
                length, location = struct.unpack_from('<QI', data, section + 40)
                flags = struct.unpack_from('<I', data, section + 64)[0]
                if flags & 0xff in (1, 0xc, 0x12):  # Zero-fill sections have no file bytes.
                    continue
                assert location + length <= len(data)
                sections[segment + ',' + name] = hashlib.sha256(data[location:location + length]).hexdigest()
        offset += size
    assert signature is not None and signature >= offset
    return {'normalized_image_sha256': hashlib.sha256(data[:signature]).hexdigest(), 'sections': sections}


def main():
    assert SOURCE.is_file() and not SOURCE.is_symlink() and sha(SOURCE) == SHA
    assert not os.path.lexists(APP), 'Fresh private app required'
    APP.parent.mkdir(mode=0o700, exist_ok=True)
    APP.mkdir(mode=0o700)
    contents = APP / 'Contents'
    contents.mkdir(mode=0o700)
    (contents / 'MacOS').mkdir(mode=0o700)
    binary = contents / 'MacOS/qemu-system-aarch64'
    # copyfile intentionally avoids FinderInfo/ResourceFork extended attributes.
    shutil.copyfile(SOURCE, binary)
    binary.chmod(0o700)
    assert sha(binary) == SHA
    info = {'CFBundleExecutable': 'qemu-system-aarch64',
        'CFBundleIdentifier': 'org.perpendicular.cocoa3dtrial',
        'CFBundleName': 'Perpendicular 3D Trial',
        'CFBundleDisplayName': 'Perpendicular 3D Trial',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '0.1', 'NSPrincipalClass': 'NSApplication',
        'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0',
        'LSUIElement': False, 'LSBackgroundOnly': False}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    # QEMU relocates its keymap lookup relative to the executable. Copy only
    # ordinary keymap data; no firmware is copied or changed. External symlinks
    # are deliberately absent because strict bundle signatures reject them.
    resources = contents / 'share/qemu/keymaps'
    resources.mkdir(parents=True, mode=0o700)
    keymaps = {}
    for source in sorted((PREFIX / 'share/qemu/keymaps').iterdir()):
        assert source.is_file() and not source.is_symlink()
        shutil.copyfile(source, resources / source.name)
        keymaps[source.name] = sha(source)
    (contents / 'PkgInfo').write_bytes(b'APPL????')
    original_code = code_identity(SOURCE)
    entitlements_path = APP.parent / 'hypervisor.plist'
    entitlements_path.write_bytes(plistlib.dumps({'com.apple.security.hypervisor': True}));entitlements_path.chmod(0o600)
    sign = subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', info['CFBundleIdentifier'], '--entitlements', str(entitlements_path), str(APP)], capture_output=True, text=True)
    assert sign.returncode == 0, sign.stderr
    verify = subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)], capture_output=True, text=True)
    assert verify.returncode == 0, verify.stderr
    ent = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', '--xml', str(binary)], capture_output=True)
    assert ent.returncode == 0
    data = ent.stdout; start = data.find(b'<?xml')
    assert start >= 0
    entitlements = plistlib.loads(data[start:])
    assert entitlements == {'com.apple.security.hypervisor': True}
    registration = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(APP)], capture_output=True, text=True)
    assert registration.returncode == 0, registration.stderr
    signed_sha = sha(binary)
    signed_code = code_identity(binary)
    assert original_code == signed_code, 'Code/sections changed beyond signature and allowed linkedit sizes'
    assert sha(SOURCE) == SHA
    receipt = {'format_version': 1, 'app': str(APP), 'bundle_id': info['CFBundleIdentifier'],
        'binary': str(binary), 'binary_sha256': signed_sha, 'original_binary': str(SOURCE), 'original_sha256': SHA,
        'info_sha256': sha(contents / 'Info.plist'), 'entitlements': entitlements,
        'bundle_strict_signature_verified': True, 're_signed': True,
        'code_identity': original_code, 'code_identity_unchanged': True,
        'launch_services_registered': True, 'started': False,
        'keymap_sha256': keymaps, 'external_symlinks': False, 'firmware_copied': False}
    target = APP.parent / 'package.json'
    target.write_text(json.dumps(receipt, indent=2) + '\n');target.chmod(0o600)
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
