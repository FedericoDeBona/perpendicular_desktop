#!/usr/bin/env python3
"""Package the pinned macOS virtiofs daemon into a new prepared QEMU app.

Run rebuild-app-monitor.py against the vhost-user enabled local build first.
Never writes to the installed app or a runtime in use.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

SOURCE_PIN = 'fef121023b40ddebdbd8165509088f6f549ddb6e'
DESCRIPTOR_SHA = 'b5da30437ff28c32301b95b0cedac9089ee4048ae10656292f2c27cc103e6520'
DIRECTORY_SHA = 'b93e3f62e564b6a1bf1383bdda929efe71689352637187821230e5e5136174a9'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepared-app', type=Path, required=True)
    parser.add_argument('--daemon-source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    app, source, output = (x.resolve() for x in [args.prepared_app, args.daemon_source, args.output])
    if output.exists() or output == app or app in output.parents or str(output).startswith('/Applications/'):
        raise ValueError('A new private output is required')
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    changed = subprocess.check_output(['git', '-C', str(source), 'diff', '--name-only', 'HEAD'], text=True).splitlines()
    if (revision != SOURCE_PIN or changed != ['src/descriptor_utils.rs', 'src/fuse/passthrough.rs']
            or digest(source / 'src/descriptor_utils.rs') != DESCRIPTOR_SHA
            or digest(source / 'src/fuse/passthrough.rs') != DIRECTORY_SHA):
        raise ValueError('The daemon source differs from the reviewed pin')
    native = app / 'Contents/Resources/Native3D'
    manifest = json.loads((native / 'runtime.json').read_text())
    for name, expected in manifest['files'].items():
        if digest(native / name) != expected:
            raise ValueError('Prepared runtime differs: ' + name)
    help_text = subprocess.check_output([str(native / 'bin/qemu-system-aarch64'), '-device', 'help'], text=True)
    if 'vhost-user-fs-pci' not in help_text:
        raise ValueError('QEMU does not expose vhost-user-fs-pci')
    displays = subprocess.check_output([str(native / 'bin/qemu-system-aarch64'), '-display', 'help'], text=True)
    if 'egl-headless' not in displays.split():
        raise ValueError('QEMU does not register the required egl-headless display')
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['cp', '-cR', str(app), str(output)], check=True)
    target = output / 'Contents/Resources/Native3D'
    daemon = target / 'bin/macosvirtiofsd'
    shutil.copy2(source / 'target/release/macosvirtiofsd', daemon)
    subprocess.run(['codesign', '--force', '--sign', '-', str(daemon)], check=True)
    notices = target / 'Notices/virtiofs'
    notices.mkdir(parents=True, exist_ok=True)
    for name in ['LICENSE-APACHE', 'LICENSE-BSD-3-Clause']:
        shutil.copy2(source / name, notices / name)
        manifest['files']['Notices/virtiofs/' + name] = digest(notices / name)
    patch = Path(__file__).resolve().parent.parent / 'filesystem/macosvirtiofsd-descriptors.patch'
    shutil.copy2(patch, notices / patch.name)
    manifest['files']['Notices/virtiofs/' + patch.name] = digest(patch)
    directory_patch = patch.with_name('macosvirtiofsd-directory-refresh.patch')
    shutil.copy2(directory_patch, notices / directory_patch.name)
    manifest['files']['Notices/virtiofs/' + directory_patch.name] = digest(directory_patch)
    manifest['files']['bin/macosvirtiofsd'] = digest(daemon)
    manifest['virtiofs_version'] = 1
    manifest['virtiofs_source_pin'] = SOURCE_PIN
    manifest['virtiofs_cargo_lock_sha256'] = digest(source / 'Cargo.lock')
    manifest['virtiofs_descriptor_patch_sha256'] = digest(patch)
    manifest['virtiofs_directory_patch_sha256'] = digest(directory_patch)
    (target / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    subprocess.run(['codesign', '--force', '--sign', '-', str(output)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(output)], check=True)
    print(output)


if __name__ == '__main__':
    main()
