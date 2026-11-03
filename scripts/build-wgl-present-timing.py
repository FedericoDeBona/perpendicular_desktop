#!/usr/bin/env python3
"""Build private WGL timing diagnostics from the qualified local Mesa cache.

Restores source and qualified DLL on exit. Never installs into Windows or an app.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess

REPO = Path(__file__).resolve().parent.parent
SOURCE_SHA = '9203b15da84d4dfbf7345eb6568a113790c66277adeec8dba0774fd6860f2b76'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def interrupted(*_):
    raise KeyboardInterrupt()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--meson', type=Path, required=True)
    parser.add_argument('--ninja', type=Path, required=True)
    args = parser.parse_args()
    cache = args.cache.resolve(strict=True)
    output = args.output.absolute()
    source = cache / 'mesa-25.1.9/mesa-25.1.9'
    build = cache / 'zink-x64'
    wgl = source / 'src/gallium/targets/wgl/wgl.c'
    dll = build / 'src/gallium/targets/wgl/libgallium_wgl.dll'
    release = json.loads((REPO / 'graphics/opengl/releases/0.2.31-darwin-arm64.json').read_text())
    patch = REPO / 'graphics/opengl/windows-zink-present-timing.patch'
    meson, ninja = args.meson.resolve(strict=True), args.ninja.resolve(strict=True)
    if subprocess.check_output([str(meson), '--version'], text=True).strip() != '1.12.1':
        raise ValueError('Use Meson 1.12.1, matching the qualified cache')
    with (cache / 'wgl-diagnostic-build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        original, qualified = wgl.read_bytes(), dll.read_bytes()
        if sha(original) != SOURCE_SHA or sha(qualified) != release['files']['x64/libgallium_wgl.dll']:
            raise ValueError('Local source/DLL differs from the qualified timing baseline')
        output.mkdir(parents=True, exist_ok=False)
        (output / 'wgl-before.c').write_bytes(original)
        (output / 'libgallium_wgl-before.dll').write_bytes(qualified)
        signal.signal(signal.SIGTERM, interrupted)
        env = os.environ.copy()
        env['PATH'] = os.pathsep.join([str(args.meson.absolute().parent), str(args.ninja.absolute().parent), env.get('PATH', '')])
        try:
            subprocess.run(['patch', '-p1', '--batch', '--forward', '-i', str(patch)], cwd=source, check=True)
            with (output / 'build.log').open('w') as log:
                subprocess.run([str(ninja), '-C', str(build), 'src/gallium/targets/wgl/libgallium_wgl.dll'],
                               env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            candidate = dll.read_bytes()
            (output / 'libgallium_wgl.dll').write_bytes(candidate)
            (output / 'receipt.json').write_text(json.dumps({
                'diagnostic_only': True, 'source_sha256': SOURCE_SHA,
                'patch_sha256': sha(patch.read_bytes()), 'dll_sha256': sha(candidate),
                'baseline_sha256': sha(qualified), 'mesa': '25.1.9', 'meson': '1.12.1',
                'architecture': 'x64', 'limit': 600,
            }, indent=2) + '\n')
        finally:
            wgl.write_bytes(original)
            dll.write_bytes(qualified)
        print('Private timing DLL built; qualified source/DLL restored. Windows unchanged.')


if __name__ == '__main__':
    main()
