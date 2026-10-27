#!/usr/bin/env python3
"""Complete the app's host runtime and pinned Windows shared-folder payload.

Artifacts stay in the user's build cache. A successful normal build must carry
both halves; copying an older installed runtime is no longer sufficient.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile

REPO = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get('PERPENDICULAR_DEPENDENCY_CACHE', Path.home() / '.local/share/perpendicular-dependencies'))
PATCHES = ['memory/qemu/vhost-user-darwin.patch', 'memory/qemu/native-display-registration.patch',
           'memory/qemu/native-scanout-required.patch', 'graphics/monitor/app-monitor-mode.patch',
           'graphics/monitor/mixed-display-identity.patch', 'memory/qemu/hvf-gicv3.patch']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, cwd=None, env=None):
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def download(url, target):
    if not target.is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + '.part')
        urllib.request.urlretrieve(url, temporary)
        temporary.replace(target)


def guest_payload(app):
    manifest = json.loads((REPO / 'guest/virtiofs-drivers.json').read_text())
    cache = CACHE / ('windows-' + sha(REPO / 'guest/virtiofs-drivers.json')[:16])
    cache.mkdir(parents=True, exist_ok=True)
    download(manifest['virtioSource'], cache / 'virtio.zip')
    download(manifest['winfspSource'], cache / 'winfsp-2.1.25156.msi')
    with zipfile.ZipFile(cache / 'virtio.zip') as archive:
        for member, expected in manifest['members'].items():
            target = cache / member
            if member.startswith('viofs/') and (not target.is_file() or sha(target) != expected):
                matches = [name for name in archive.namelist() if name.lower().endswith('/' + target.name.lower())
                           and 'arm64' in name.lower() and hashlib.sha256(archive.read(name)).hexdigest() == expected]
                if not matches:
                    raise ValueError('Pinned ARM64 package member is missing: ' + member)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(matches[0]))
            if sha(target) != expected:
                raise ValueError('Windows dependency hash differs: ' + member)
    output = app / 'Contents/Resources/Guest/SharedFiles'
    output.mkdir(parents=True, exist_ok=True)
    for name in manifest['members']:
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(cache / name, target)
    for name in ['virtiofs-drivers.json', 'install-shared-downloads.ps1',
                 'configure-shared-folders.ps1', 'apply-shared-folders.ps1']:
        shutil.copy2(REPO / 'guest' / name, output / name)


def complete(app):
    root = app / 'Contents/Resources/Native3D'
    try:
        manifest = json.loads((root / 'runtime.json').read_text())
        if manifest.get('virtiofs_version') != 1 or manifest.get('app_monitor_mode_version') != 1:
            return False
        required_patches = {
            'app_monitor_mode_patch_sha256': 'graphics/monitor/app-monitor-mode.patch',
            'virtiofs_descriptor_patch_sha256': 'filesystem/macosvirtiofsd-descriptors.patch',
            'virtiofs_directory_patch_sha256': 'filesystem/macosvirtiofsd-directory-refresh.patch',
        }
        if any(manifest.get(field) != sha(REPO / patch) for field, patch in required_patches.items()):
            return False
        for member, expected in manifest['files'].items():
            path = (root / member).resolve()
            if not path.is_relative_to(root.resolve()) or sha(path) != expected:
                raise ValueError('Runtime member differs: ' + member)
        display_help = subprocess.check_output([str(root / 'bin/qemu-system-aarch64'), '-display', 'help'], text=True)
        if 'egl-headless' not in display_help.split():
            return False
        # A paused VM with no disks catches missing interrupt-controller
        # objects that --device/help and a successful link cannot detect.
        probe = subprocess.run([str(root / 'bin/qemu-system-aarch64'), '-S', '-machine', 'virt,gic-version=3,highmem=off',
                                '-accel', 'hvf', '-cpu', 'host', '-m', '128', '-nodefaults', '-display', 'none',
                                '-monitor', 'none', '-serial', 'none', '-qmp', 'stdio'],
                               input='{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n',
                               text=True, capture_output=True, timeout=15)
        if probe.returncode != 0:
            return False
        return True
    except FileNotFoundError:
        return False


def build_runtime(reference):
    override = os.environ.get('PERPENDICULAR_COMPLETE_RUNTIME_APP')
    if override:
        app = Path(override).expanduser().resolve(strict=True)
        if not complete(app):
            raise ValueError('The explicitly selected runtime lacks shared-folder support')
        return app
    # This is the retained, modified QEMU source, never a stock replacement.
    configured = os.environ.get('PERPENDICULAR_QEMU_SEED')
    candidates = [Path(configured).expanduser()] if configured else sorted((Path.home() / '.local/share').glob('perpendicular-memory-*'))
    seeds = [p for p in candidates if (p / 'qemu/ui/perpendicular-display/qemu-native-sync.m').is_file()
             and (p / 'tools/bin/ninja').is_file() and (p / 'deps/lib/pkgconfig/virglrenderer.pc').is_file()]
    if len(seeds) != 1:
        raise ValueError('Set PERPENDICULAR_QEMU_SEED to the retained native QEMU source/tools/deps directory')
    seed = seeds[0]
    signature = hashlib.sha256((reference / 'Contents/Resources/Native3D/runtime.json').read_bytes())
    for name in PATCHES + ['scripts/prepare-build-dependencies.py', 'scripts/package-virtiofs-runtime.py']:
        signature.update((REPO / name).read_bytes())
    work = CACHE / ('native-' + signature.hexdigest()[:16])
    result = work / 'Perpendicular.app'
    if complete(result):
        return result
    work.mkdir(parents=True, exist_ok=True)
    source = work / 'qemu'
    if source.exists() and not (work / 'source-ready.json').exists():
        raise ValueError('An incomplete source preparation is preserved at ' + str(source) + '; inspect it before retrying')
    if not source.exists():
        # Pin the adaptation boundary and require the native RAM/scanout hooks.
        if sha(seed / 'qemu/ui/console.c') not in {'d7a17f8c1eb69fc15245bd6371bc78d79aab3e3a871b3a6f2318314119e46b7f',
                                                 '5f7405a341f830dbe58be6fbd9d9202c9a5fcca1edb1b472d4a777a743a55bda'}:
            raise ValueError('Different QEMU console source; adapt this actual native profile first')
        run(['cp', '-cR', seed / 'qemu', source])
        # Some retained profiles publish native frames from the GPU hooks and
        # still need stock EGL to create contexts. Other profiles register their
        # own EGL display backend. Remove stock registration only in that case.
        custom_egl = any('qemu_display_register' in path.read_text(errors='replace')
                         and 'DISPLAY_TYPE_EGL_HEADLESS' in path.read_text(errors='replace')
                         for path in (source / 'ui').rglob('*')
                         if path.suffix in {'.c', '.m'} and path.name != 'egl-headless.c')
        for patch in PATCHES:
            if patch.endswith('native-display-registration.patch') and not custom_egl:
                continue
            applied = subprocess.run(['patch', '--batch', '--dry-run', '--reverse', '-p1', '-i', str(REPO / patch)], cwd=source, capture_output=True)
            if applied.returncode != 0:
                run(['patch', '--batch', '--forward', '-p1', '-i', REPO / patch], cwd=source)
        (work / 'source-ready.json').write_text(json.dumps({name: sha(REPO / name) for name in PATCHES}, indent=2) + '\n')
    build = work / 'qemu-build'
    build.mkdir(exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = str(seed / 'tools/bin') + ':/opt/homebrew/bin:' + env.get('PATH', '')
    env['PKG_CONFIG_PATH'] = str(seed / 'deps/lib/pkgconfig')
    if not (build / 'build.ninja').exists():
        run([source / 'configure', '--target-list=aarch64-softmmu', '--enable-hvf', '--disable-tcg',
             '--enable-opengl', '--enable-virglrenderer', '--enable-vnc', '--enable-slirp', '--disable-cocoa',
             '--disable-sdl', '--disable-gtk', '--disable-docs', '--disable-tools', '--disable-guest-agent',
             '--disable-werror', '--disable-plugins', '--disable-curl', '--disable-libssh', '--disable-vte',
             '--disable-rust', '--disable-pvg', '--enable-vhost-user', '--python=' + str(seed / 'tools/bin/python3')], cwd=build, env=env)
    run([seed / 'tools/bin/ninja', '-j', '6', 'qemu-system-aarch64-unsigned'], cwd=build, env=env)
    prepared = work / 'Prepared.app'
    if not prepared.exists():
        run(['cp', '-cR', reference, prepared])
    run([sys.executable, REPO / 'scripts/package-memory-runtime.py', '--app', prepared,
         '--qemu', build / 'qemu-system-aarch64-unsigned', '--native', '--library-dir', seed / 'deps/lib'])
    manifest_path = prepared / 'Contents/Resources/Native3D/runtime.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['app_monitor_mode_version'] = 1
    manifest['app_monitor_mode_patch_sha256'] = sha(REPO / 'graphics/monitor/app-monitor-mode.patch')
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    run(['codesign', '--force', '--sign', '-', prepared])
    daemon = work / 'macosvirtiofsd'
    if not daemon.exists():
        run(['git', 'clone', 'https://github.com/mheese/macosvirtiofsd.git', daemon])
        run(['git', '-C', daemon, 'checkout', '--detach', 'fef121023b40ddebdbd8165509088f6f549ddb6e'])
        for name in ['macosvirtiofsd-descriptors.patch', 'macosvirtiofsd-directory-refresh.patch']:
            run(['patch', '--batch', '-p1', '-i', REPO / 'filesystem' / name], cwd=daemon)
    run([Path.home() / '.cargo/bin/cargo', 'build', '--release', '--locked'], cwd=daemon)
    run([sys.executable, REPO / 'scripts/package-virtiofs-runtime.py', '--prepared-app', prepared,
         '--daemon-source', daemon, '--output', result])
    if not complete(result):
        raise ValueError('The prepared runtime is incomplete')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if complete(app):
        print('Host shared-folder runtime verified.', flush=True)
    else:
        runtime = build_runtime(app)
        run([sys.executable, REPO / 'scripts/copy-main-runtime.py', '--from-app', runtime, '--to-app', app])
    guest_payload(app)
    print('Host runtime and signed Windows shared-folder payload complete.', flush=True)


if __name__ == '__main__':
    main()
