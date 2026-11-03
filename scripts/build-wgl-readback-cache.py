#!/usr/bin/env python3
"""Build release WGL readback reuse from a qualified Mesa 25.1.9 cache.

Optional cached batch with the same serial fallback. No timing/control patch.
Restores qualified sources and DLLs on every exit.
Use the existing host-specific toolchain/cache; this never installs a payload.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess

REPO = Path(__file__).resolve().parents[1]


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
    parser.add_argument('--base-release', type=Path, required=True)
    parser.add_argument('--batch-readback', action='store_true', help='Build production cached color readback batch, enabled by default in the result')
    args = parser.parse_args()
    cache = args.cache.resolve(strict=True)
    source = cache / 'mesa-25.1.9/mesa-25.1.9'
    output = args.output.absolute()
    release = json.loads(args.base_release.read_text())
    # Same qualified source base as the diagnostic; host/DLL pins may differ.
    pins = runpy.run_path(str(REPO / 'scripts/build-wgl-present-timing.py'))
    expected_sources = dict(pins['REUSE_SOURCES'])
    expected_sources['src/gallium/targets/wgl/wgl.c'] = pins['SOURCE_SHA']
    if args.batch_readback:
        expected_sources.update(pins['BATCH_SOURCES'])
    patch = REPO / 'graphics/opengl/windows-zink-readback-cache.patch'
    patches = [patch]
    if args.batch_readback:
        patches.append(REPO / 'graphics/opengl/windows-zink-cached-batch-readback.patch')
    meson, ninja = args.meson.resolve(strict=True), args.ninja.resolve(strict=True)
    version = subprocess.check_output([str(meson), '--version'], text=True).strip()
    if version != '1.12.1':
        raise ValueError('Use Meson 1.12.1 matching the qualified cache')
    with (cache / 'wgl-diagnostic-build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        originals = {}
        for name, expected in expected_sources.items():
            file = source / name
            originals[file] = file.read_bytes()
            if sha(originals[file]) != expected:
                raise ValueError('Unqualified source: ' + name)
        for arch in ('arm64', 'x64'):
            file = cache / ('zink-' + arch) / 'src/gallium/targets/wgl/libgallium_wgl.dll'
            originals[file] = file.read_bytes()
            if sha(originals[file]) != release['files'][arch + '/libgallium_wgl.dll']:
                raise ValueError('Unqualified baseline DLL: ' + arch)
        output.mkdir(parents=True, exist_ok=False)
        for index, (file, data) in enumerate(originals.items()):
            (output / ('backup-%d-%s' % (index, file.name))).write_bytes(data)
        signal.signal(signal.SIGTERM, interrupted)
        env = os.environ.copy()
        env['PATH'] = os.pathsep.join([str(args.meson.absolute().parent), str(args.ninja.absolute().parent), env.get('PATH', '')])
        receipt = {'mesa': '25.1.9', 'meson': version, 'production': True,
                   'timing': False, 'control': False, 'batch': args.batch_readback, 'patch_sha256': sha(patch.read_bytes()),
                   'patches': {p.name: sha(p.read_bytes()) for p in patches},
                   'base_release_sha256': sha(args.base_release.read_bytes()), 'files': {}}
        try:
            for patch in patches:
                subprocess.run(['patch', '-p1', '--batch', '--forward', '-i', str(patch)], cwd=source, check=True)
            for arch in ('arm64', 'x64'):
                build = cache / ('zink-' + arch)
                with (output / (arch + '-build.log')).open('w') as log:
                    subprocess.run([str(ninja), '-j2', '-C', str(build), 'src/gallium/targets/wgl/libgallium_wgl.dll'],
                                   env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
                data = (build / 'src/gallium/targets/wgl/libgallium_wgl.dll').read_bytes()
                target = output / arch / 'libgallium_wgl.dll'
                target.parent.mkdir()
                target.write_bytes(data)
                receipt['files'][arch + '/libgallium_wgl.dll'] = sha(data)
            (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        finally:
            for file, data in originals.items():
                file.write_bytes(data)
        print('Production WGL candidates built; qualified cache restored. Nothing installed.')


if __name__ == '__main__':
    main()
