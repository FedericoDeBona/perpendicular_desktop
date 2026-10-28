#!/usr/bin/env python3
"""Reuse the qualified main runtime without replacing it with upstream QEMU.

Only writes the destination build. The installed reference app remains intact.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--from-app', type=Path, default=Path('/Applications/Perpendicular.app'))
    parser.add_argument('--to-app', type=Path, required=True)
    args = parser.parse_args()
    source = args.from_app.resolve(strict=True)
    target = args.to_app.resolve(strict=True)
    if source == target or source.is_relative_to(target) or target.is_relative_to(source):
        raise ValueError('Runtime reference and destination build must be separate app bundles')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    native = source / 'Contents/Resources/Native3D'
    manifest = json.loads((native / 'runtime.json').read_text())
    if manifest.get('hvf_dynamic_memory_version') != 1:
        raise ValueError('The reference app does not contain the main dynamic RAM runtime')
    for name, expected in manifest['files'].items():
        file = native / name
        if not file.resolve().is_relative_to(native) or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            raise ValueError('Reference runtime hash differs: ' + name)
    members = ['Resources/QEMU', 'Frameworks/Runtime', 'Resources/Native3D']
    if (source / 'Contents/Resources/Guest/OpenGL').is_dir():
        members.append('Resources/Guest/OpenGL')
    for name in members:
        root = source / 'Contents' / name
        for file in root.rglob('*'):
            if file.is_symlink() and not file.resolve().is_relative_to(source / 'Contents'):
                raise ValueError('Reference runtime contains an external link: ' + str(file))
    for name in members:
        destination = target / 'Contents' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            shutil.rmtree(destination)
        subprocess.run(['cp', '-cR', str(source / 'Contents' / name), str(destination)], check=True)
    for name in ['ThirdPartyNotices', 'runtime-manifest.json']:
        original = source / 'Contents/Resources' / name
        destination = target / 'Contents/Resources' / name
        if original.is_dir():
            shutil.copytree(original, destination, dirs_exist_ok=True)
        elif original.is_file():
            shutil.copy2(original, destination)
    print('Copied the qualified main runtime; renderer, firmware tools and RAM support preserved.')


if __name__ == '__main__':
    main()
