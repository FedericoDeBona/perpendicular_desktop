#!/usr/bin/env python3
"""Reject a Win32 graphics payload missing the project's shared wire fix."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

REPO = Path(__file__).resolve().parent.parent


def check(app):
    root = app / 'Contents/Resources/Guest/X86Graphics'
    if not (root / 'release.json').is_file():
        raise ValueError('Win32 graphics fix missing; rebuild/package the shared x86 payload before building')
    release = json.loads((root / 'release.json').read_text())
    version = release.get('version', '')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Invalid Win32 payload release')
    pinned = json.loads((REPO / 'graphics/driver/releases' / ('x86-' + version + '.json')).read_text())
    required = json.loads((REPO / 'graphics/driver/x86-requirements.json').read_text())
    if release != pinned or release.get('schema') != required['schema']:
        raise ValueError('Win32 payload metadata differs from the shared release')
    if not set(required['required_fixes']).issubset(release.get('fixes', [])):
        raise ValueError('Win32 payload lacks the shared SIZE_T wire fix')
    if release.get('architecture') != required['architecture'] or release.get('kernel_abi') != required['kernel_abi']:
        raise ValueError('Win32 payload architecture or kernel ABI differs')
    for name, expected in release['files'].items():
        file = root / name
        if not file.resolve().is_relative_to(root.resolve()) or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            raise ValueError('Win32 payload bytes differ: ' + name)
    installer = REPO / 'graphics/driver/install-x86-candidate.ps1'
    if hashlib.sha256(installer.read_bytes()).hexdigest() != release['files']['install.ps1']:
        raise ValueError('Win32 installer source and release differ')
    data = (root / 'neptune_umd_x86.dll').read_bytes()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe+4] != b'PE\0\0' or struct.unpack_from('<H', data, pe+4)[0] != 0x14c:
        raise ValueError('Win32 payload is not an i386 PE image')
    runtime = json.loads((app / 'Contents/Resources/Native3D/runtime.json').read_text())
    if runtime.get('guest_wire_version') != required['guest_wire_version']:
        raise ValueError('Host/Win32 wire versions differ')
    return release


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    release = check(p.parse_args().app.resolve(strict=True))
    print('Win32 graphics ' + release['version'] + ': shared wire fix and payload hashes verified')
