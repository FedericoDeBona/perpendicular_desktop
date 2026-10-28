#!/usr/bin/env python3
"""Package the pinned OpenGL user-mode pair into a prepared application build.

No VM, installed app, kernel driver or machine configuration is modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def require_host_capabilities(name, data, manifest):
    if name not in ('bin/virgl_render_server', 'lib/libvirglrenderer.1.dylib'):
        return
    if (manifest.get('experimental_wgc_gpu_export') == 1
            and b'PERP_WGC_EXPORT_SOCKET\0' not in data):
        raise ValueError('Host input omits the existing Seamless export hook: ' + name)
    # The broker lives in the library; the matching worker is pinned separately
    # in the same release. A copied manifest alone cannot preserve this feature.
    if (name == 'lib/libvirglrenderer.1.dylib'
            and manifest.get('initial_capture_decline') == 1
            and b'selected_capture_unsupported' not in data):
        raise ValueError('Host input omits the existing unsupported-capture handling: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--guest', type=Path, required=True)
    parser.add_argument('--moltenvk-license', type=Path, required=True)
    parser.add_argument('--mesa-license', type=Path, required=True)
    parser.add_argument('--release-manifest', type=Path,
                        default=REPO / 'graphics/opengl/release.json',
                        help='Pinned release for this qualified base runtime')
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if app == Path('/Applications/Perpendicular.app'):
        raise ValueError('Package a separate build before installing it.')
    release_path = args.release_manifest.resolve(strict=True)
    release = json.loads(release_path.read_text())
    native = app / 'Contents/Resources/Native3D'
    manifest_path = native / 'runtime.json'
    if sha(manifest_path) != release['base_native_manifest_sha256']:
        raise ValueError('The prepared base runtime differs from the qualified input.')
    manifest = json.loads(manifest_path.read_text())
    for name, expected in manifest['files'].items():
        if sha(native / name) != expected:
            raise ValueError('Base runtime member changed: ' + name)
    for name, expected in release['host_inputs'].items():
        if sha(args.host / name) != expected:
            raise ValueError('Host input changed: ' + name)
        required = dict(manifest)
        if release.get('host_revision', 1) >= 2:
            required['initial_capture_decline'] = 1
        require_host_capabilities(name, (args.host / name).read_bytes(), required)
    for name, expected in release['files'].items():
        file = args.guest / name
        if sha(file) != expected:
            raise ValueError('Guest input changed: ' + name)
        data = file.read_bytes()
        pe = struct.unpack_from('<I', data, 0x3c)[0]
        machine = struct.unpack_from('<H', data, pe + 4)[0]
        if data[pe:pe + 4] != b'PE\0\0' or machine != (0xaa64 if name.startswith('arm64/') else 0x8664):
            raise ValueError('Guest architecture differs: ' + name)
    for name, expected in release['patches'].items():
        if sha(REPO / 'graphics/opengl' / name) != expected:
            raise ValueError('Source patch changed: ' + name)
    for name, expected in release['renderer_inputs'].items():
        if sha(REPO / 'graphics/renderer' / name) != expected:
            raise ValueError('Existing renderer input changed: ' + name)
    # Preserve QEMU, DXMT and the existing graphics lifecycle protocol. Replace
    # only the matched renderer/server pair and add its private Vulkan backend.
    for name in release['host_inputs']:
        destination = native / name
        shutil.copy2(args.host / name, destination)
        if name == 'lib/libvirglrenderer.1.dylib':
            run('install_name_tool', '-change', '@rpath/libepoxy.0.dylib',
                '@loader_path/libepoxy.0.dylib', destination)
        run('codesign', '--force', '--sign', '-', destination)
        run('codesign', '--verify', '--strict', destination)
        manifest['files'][name] = sha(destination)
    notice = native / 'Notices/OpenGL'
    notice.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.moltenvk_license, notice / 'MoltenVK-LICENSE')
    shutil.copy2(args.mesa_license, notice / 'Mesa-LICENSE.rst')
    shutil.copy2(release_path, notice / 'release.json')
    manifest['files']['Notices/OpenGL/release.json'] = sha(notice / 'release.json')
    manifest['venus_version'] = 1
    manifest['opengl_release'] = release['version']
    manifest['opengl_host_revision'] = release.get('host_revision', 1)
    if release.get('host_revision', 1) >= 2:
        manifest['initial_capture_decline'] = 1
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    guest = app / 'Contents/Resources/Guest/OpenGL'
    if guest.exists():
        raise ValueError('OpenGL guest output already exists; use a fresh build.')
    guest.mkdir(parents=True)
    for name in release['files']:
        destination = guest / name
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(args.guest / name, destination)
    shutil.copy2(release_path, guest / 'release.json')
    shutil.copy2(REPO / 'graphics/opengl/install.ps1', guest / 'install.ps1')
    print('Packaged pinned Venus host and ARM64/x64 OpenGL libraries; no VM changed.')


if __name__ == '__main__':
    main()
