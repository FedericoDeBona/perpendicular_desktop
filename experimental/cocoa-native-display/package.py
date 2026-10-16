#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Package the exact private capture candidate. Does not start it or any VM."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'experimental/cocoa-neptune/package-cocoa-app.py'
SPEC = importlib.util.spec_from_file_location('cocoa_identity', BASE)
IDENTITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IDENTITY)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args):
    result = subprocess.run(list(map(str, args)), capture_output=True, check=True)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='Fresh private .app under this repository .tools')
    args = parser.parse_args()
    receipt_path = args.receipt.resolve(strict=True)
    build = json.loads(receipt_path.read_text())
    source = Path(build['candidate'])
    assert receipt_path.is_relative_to(ROOT / '.tools/cocoa-native-display-build')
    assert source.parent.parent == receipt_path.parent and source.name == 'qemu-system-aarch64'
    assert source.is_file() and not source.is_symlink() and sha(source) == build['candidate_sha256']
    assert build['strict_signature_verified'] and build['protected_inputs_unchanged']
    assert build['entitlements'] == {'com.apple.security.hypervisor': True}
    app = Path(os.path.abspath(args.output))
    assert app.is_relative_to(ROOT / '.tools') and app.suffix == '.app'
    assert not os.path.lexists(app), 'Fresh app required'
    app.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    assert app.parent.resolve() == app.parent and app.parent.stat().st_uid == os.geteuid()
    executable = app / 'Contents/MacOS/qemu-system-aarch64'
    executable.parent.mkdir(parents=True, mode=0o700)
    shutil.copyfile(source, executable); executable.chmod(0o700)
    info = {'CFBundleExecutable': executable.name,
            'CFBundleIdentifier': 'org.perpendicular.native-display.qemu',
            'CFBundleName': 'Perpendicular Native Display',
            'CFBundleDisplayName': 'Perpendicular Native Display',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '0.1', 'NSPrincipalClass': 'NSApplication',
            'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '27.0'}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    (app / 'Contents/PkgInfo').write_bytes(b'APPL????')
    keymaps = app / 'Contents/share/qemu/keymaps'
    keymaps.mkdir(parents=True, mode=0o700)
    hashes = {}
    for path in sorted((ROOT / '.tools/graphics-experiment/prefix/share/qemu/keymaps').iterdir()):
        assert path.is_file() and not path.is_symlink()
        shutil.copyfile(path, keymaps / path.name); hashes[path.name] = sha(path)
    entitlement = app.parent / 'native-hypervisor.plist'
    assert not os.path.lexists(entitlement), 'Fresh entitlement output required'
    entitlement.write_bytes(plistlib.dumps({'com.apple.security.hypervisor': True})); entitlement.chmod(0o600)
    before = IDENTITY.code_identity(source)
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
         '--identifier', info['CFBundleIdentifier'], '--entitlements', entitlement, app])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    actual = run(['/usr/bin/codesign', '-d', '--entitlements', ':-', '--xml', executable])
    assert plistlib.loads(actual[actual.find(b'<?xml'):]) == {'com.apple.security.hypervisor': True}
    assert IDENTITY.code_identity(executable) == before and sha(source) == build['candidate_sha256']
    run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', app])
    result = {'app': str(app), 'binary': str(executable), 'binary_sha256': sha(executable),
              'source': str(source), 'source_sha256': sha(source), 'build_receipt_sha256': sha(receipt_path),
              'identity_parser_sha256': sha(BASE), 'code_identity_unchanged': True,
              'strict_signature_verified': True, 'entitlements': {'com.apple.security.hypervisor': True},
              'keymap_sha256': hashes, 'started': False, 'vm_modified': False}
    output = app.parent / 'package.json'
    assert not os.path.lexists(output), 'Fresh package receipt required'
    output.write_text(json.dumps(result, indent=2) + '\n'); output.chmod(0o600)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
