#!/usr/bin/env python3
"""Update a pinned guest OpenGL payload in a separate app build.

The existing host runtime and Vulkan libraries must remain byte-identical.
No running VM or installed application is modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--guest', type=Path, required=True)
    parser.add_argument('--release-manifest', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if app == Path('/Applications/Perpendicular.app'):
        raise ValueError('Package a separate build before installing it')
    native = app / 'Contents/Resources/Native3D'
    target = app / 'Contents/Resources/Guest/OpenGL'
    release = json.loads(args.release_manifest.read_text())
    if sha(native / 'runtime.json') != release['guest_update_base_native_manifest_sha256']:
        raise ValueError('The host runtime differs from the qualified update base')
    if sha(target / 'release.json') != release['guest_update_base_release_sha256']:
        raise ValueError('The previous guest release differs from the update base')
    current = json.loads((target / 'release.json').read_text())
    manifest = json.loads((native / 'runtime.json').read_text())
    for name, expected in manifest['files'].items():
        if sha(native / name) != expected:
            raise ValueError('Host member changed: ' + name)
    names = {f'{arch}/{name}.dll' for arch in ('arm64', 'x64')
             for name in ('opengl32', 'libgallium_wgl', 'vulkan_virtio')}
    if set(release['files']) != names or set(current['files']) != names:
        raise ValueError('Expected exactly six guest libraries')
    # Finish validation before replacing any payload member.
    for name in names:
        if sha(target / name) != current['files'][name]:
            raise ValueError('Previous guest member changed: ' + name)
        source = args.guest / name
        if sha(source) != release['files'][name]:
            raise ValueError('Update input changed: ' + name)
        data = source.read_bytes()
        offset = struct.unpack_from('<I', data, 0x3c)[0]
        machine = struct.unpack_from('<H', data, offset + 4)[0]
        if data[offset:offset + 4] != b'PE\0\0' or machine != (0xaa64 if name.startswith('arm64/') else 0x8664):
            raise ValueError('Guest architecture differs: ' + name)
        if name.endswith('vulkan_virtio.dll') and release['files'][name] != current['files'][name]:
            raise ValueError('A guest-only update must preserve Vulkan: ' + name)
    repo = Path(__file__).resolve().parents[1]
    for name, expected in release['patches'].items():
        if sha(repo / 'graphics/opengl' / name) != expected:
            raise ValueError('Source patch changed: ' + name)
    for name in sorted(names):
        shutil.copy2(args.guest / name, target / name)
    shutil.copy2(args.release_manifest, target / 'release.json')
    print('Packaged guest OpenGL update; host runtime and Vulkan unchanged')


if __name__ == '__main__':
    main()
