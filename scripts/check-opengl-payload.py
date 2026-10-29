#!/usr/bin/env python3
"""Reject a bundled OpenGL payload missing the project's shared fixes.

Release numbers may differ between compatible host profiles. Check source patch
identities and the actual DLL bytes, rather than comparing frontend versions.
This does not certify the libraries installed inside a running Windows VM.
"""
import argparse
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(app):
    payload = app / 'Contents/Resources/Guest/OpenGL'
    release_path = payload / 'release.json'
    if not release_path.is_file():
        raise ValueError('OpenGL payload is missing; package the shared graphics fixes before building')
    release = json.loads(release_path.read_text())
    requirements = json.loads((REPO / 'graphics/opengl/requirements.json').read_text())
    if release.get('schema') != 1 or requirements.get('schema') != 1:
        raise ValueError('Unsupported OpenGL release or requirements schema')
    missing = [name for name in requirements['required_patches']
               if release.get('patches', {}).get(name) != sha(REPO / 'graphics/opengl' / name)]
    if missing:
        raise ValueError('OpenGL ' + str(release.get('version')) + ' lacks shared fixes: '
                         + ', '.join(missing)
                         + '. Reuse the existing build/package recipe for this host; do not preserve the stale payload')
    expected = {f'{arch}/{name}.dll' for arch in ('arm64', 'x64')
                for name in ('opengl32', 'libgallium_wgl', 'vulkan_virtio')}
    if set(release.get('files', {})) != expected:
        raise ValueError('OpenGL release must pin exactly six ARM64/x64 libraries')
    for name in sorted(expected):
        file = payload / name
        if not file.resolve().is_relative_to(payload.resolve()) or not file.is_file() or sha(file) != release['files'][name]:
            raise ValueError('OpenGL payload bytes differ from the pinned release: ' + name)
    return release['version']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    args = parser.parse_args()
    try:
        version = check(args.app.resolve(strict=True))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, 'Graphics alignment required: ' + str(error) + '\n')
    print('OpenGL ' + version + ': shared fixes and six payload hashes verified')


if __name__ == '__main__':
    main()
