#!/usr/bin/env python3
"""Prepare a hash-matched graphics runtime without touching an app or VM.

Only the graphics payload is read. No legacy guest tools, machine configuration,
disk, user state or sharing integration is imported from the reference project.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(source, output, replacement_qemu=None):
    source = source.resolve(strict=True)
    output = output.resolve()
    if output.exists():
        raise ValueError('Use a new output directory; existing runtimes are never replaced.')
    manifest_path = source / 'runtime.json'
    if manifest_path.stat().st_size > 65536:
        raise ValueError('Oversized graphics manifest')
    manifest = json.loads(manifest_path.read_text())
    versions = {'schema': 1, 'guest_wire_version': 1,
                'host_transport_version': 3, 'native_descriptor_version': 2}
    if any(manifest.get(key) != value for key, value in versions.items()):
        raise ValueError('Incompatible graphics protocol versions')
    files = manifest.get('files')
    required = {'bin/qemu-system-aarch64', 'bin/virgl_render_server',
                'lib/libvirglrenderer.1.dylib', 'lib/libdxmt-native.dylib'}
    if not isinstance(files, dict) or not required.issubset(files) or len(files) > 64:
        raise ValueError('Incomplete graphics manifest')
    notices = source.parent / 'ThirdPartyNotices/Native3D'
    if not notices.is_dir():
        raise ValueError('Graphics notices/source metadata are missing')
    selected = []
    for name, expected in files.items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or relative.parts[0] not in ('bin', 'lib'):
            raise ValueError('Invalid runtime path')
        candidate = replacement_qemu if name == 'bin/qemu-system-aarch64' and replacement_qemu else source / relative
        candidate = candidate.resolve(strict=True)
        if not candidate.is_file() or digest(candidate) != expected:
            raise ValueError(f'Graphics artifact does not match its manifest: {name}')
        selected.append((relative, candidate))
    # Validate every artifact before creating the new output. A replacement QEMU
    # must match the original manifest exactly; this cannot mix arbitrary builds.
    for relative, candidate in selected:
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(candidate, destination)
    shutil.copytree(notices, output / 'Notices', symlinks=True)
    shutil.copy2(manifest_path, output / 'runtime.json')
    for relative, _ in selected:
        if digest(output / relative) != files[str(relative)]:
            raise ValueError(f'Copied graphics artifact failed verification: {relative}')
    subprocess.run(['codesign', '--verify', '--strict', str(output / 'bin/qemu-system-aarch64')], check=True)
    print(f'Prepared {len(selected)} matching graphics artifacts in {output}. No VM was changed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Reference Native3D directory')
    parser.add_argument('output', type=Path, help='New private runtime directory')
    parser.add_argument('--qemu', type=Path, help='Original QEMU if the reference copy was replaced; its manifest hash must match')
    arguments = parser.parse_args()
    prepare(arguments.source, arguments.output, arguments.qemu)
