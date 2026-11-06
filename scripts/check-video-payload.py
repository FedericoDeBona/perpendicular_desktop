#!/usr/bin/env python3
"""Reject incomplete or mismatched native/Windows video components."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

REPO = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(app):
    root = app / 'Contents/Resources/Guest/VideoGraphics'
    if not (root / 'release.json').is_file():
        raise ValueError('Paired video payload missing; package the shared compatible video release before building')
    release = json.loads((root / 'release.json').read_text())
    if not isinstance(release.get('version'), str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', release['version']):
        raise ValueError('Invalid video release version')
    required = json.loads((REPO / 'graphics/backend/video-requirements.json').read_text())
    pinned = json.loads((REPO / 'graphics/backend/releases' / ('video-' + release['version'] + '.json')).read_text())
    if release != pinned or release['schema'] != required['schema']:
        raise ValueError('Video release differs from the shared manifest')
    missing = set(required['required_fixes']) - set(release['fixes'])
    if missing:
        raise ValueError('Video ' + release['version'] + ' lacks required fixes: ' + ', '.join(sorted(missing)) +
                         '; rebuild/package a compatible profile using graphics/backend/README.md')
    if release['kernel_abi'] != required['kernel_abi'] or release['architecture'] != 'aarch64':
        raise ValueError('Video architecture/kernel ABI differs')
    for name, expected in release['files'].items():
        file = root / name
        if not file.resolve().is_relative_to(root.resolve()) or digest(file) != expected:
            raise ValueError('Video payload differs: ' + name)
    if digest(REPO / 'graphics/backend/install-video.ps1') != release['files']['install.ps1']:
        raise ValueError('Video installer source differs from the release')
    for name, expected in release['patches'].items():
        if digest(REPO / 'graphics/backend' / name) != expected:
            raise ValueError('Shared video source differs: ' + name)
    data = (root / 'neptune_umd_arm64.dll').read_bytes()
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    if data[offset:offset+4] != b'PE\0\0' or struct.unpack_from('<H', data, offset+4)[0] != 0xaa64:
        raise ValueError('Video UMD is not ARM64 PE')
    native = app / 'Contents/Resources/Native3D'
    runtime = json.loads((native / 'runtime.json').read_text())
    host = release['hosts'][runtime['video_release']['host_profile']]
    if runtime['video_release']['version'] != release['version'] or runtime['guest_wire_version'] != required['guest_wire_version']:
        raise ValueError('Host/video release pairing differs')
    actual = digest(native / 'lib/libdxmt-native.dylib')
    if actual != host['backend_sha256'] or runtime['files']['lib/libdxmt-native.dylib'] != actual:
        raise ValueError('Native video backend differs from its compatible release profile')
    return release


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    release = check(parser.parse_args().app.resolve(strict=True))
    print('Video ' + release['version'] + ': native/ARM64 pairing, shared fixes and payload hashes verified')
