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
BATCH_SOURCES = {
    'src/gallium/drivers/zink/zink_public.h': '889ff84eebf7cd7ecbc5ed90ece16d9ffe899248d171bd6a7f9421bf791586f1',
    'src/gallium/drivers/zink/zink_resource.c': '3c6a672b0a999c7a17c1d14f91a00dc879c9a6d8a21cc6ab9175a36bc1f86987',
}
REUSE_SOURCES = {
    'src/gallium/drivers/zink/zink_resource.c': BATCH_SOURCES['src/gallium/drivers/zink/zink_resource.c'],
    'src/gallium/drivers/zink/zink_types.h': 'abb94ba28c50549fefd7d3e93649ea0e1c8d0f977af7a62c90980c77387f0463',
    'src/gallium/drivers/zink/zink_context.c': '0fa7f49a3352827a41affc63679685893315af45cebf3a330798e4a20a104e73',
}


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
    experiment = parser.add_mutually_exclusive_group()
    experiment.add_argument('--batch-readback', action='store_true', help='Reproduce the rejected batch experiment (incorrect window pixels); never deploy')
    experiment.add_argument('--reuse-readback', action='store_true', help='Build bounded staging reuse; application performance is not yet qualified')
    parser.add_argument('--compare-readback', action='store_true', help='Compare rejected batch bytes with serial; presents serial, diagnostic only')
    parser.add_argument('--batch-host-read', action='store_true', help='Reproduce rejected host-visibility variant (still incorrect bytes); requires batch')
    parser.add_argument('--batch-box', action='store_true', help='Correct experimental batch pipe_box areas using u_box_2d; requires batch')
    parser.add_argument('--cached-batch', action='store_true', help='Keep production serial cache and bounded batch staging pool; requires batch and corrected boxes')
    args = parser.parse_args()
    if args.cached_batch and not (args.batch_readback and args.batch_box):
        parser.error('--cached-batch requires --batch-readback --batch-box')
    if args.cached_batch and (args.compare_readback or args.batch_host_read):
        parser.error('Use clean cached batch for application timing, no comparison instrumentation')
    if args.batch_box and not args.batch_readback:
        parser.error('--batch-box requires --batch-readback')
    if args.batch_host_read and not args.batch_readback:
        parser.error('--batch-host-read requires --batch-readback')
    if args.compare_readback and not args.batch_readback:
        parser.error('--compare-readback requires --batch-readback')
    cache = args.cache.resolve(strict=True)
    output = args.output.absolute()
    source = cache / 'mesa-25.1.9/mesa-25.1.9'
    build = cache / 'zink-x64'
    wgl = source / 'src/gallium/targets/wgl/wgl.c'
    dll = build / 'src/gallium/targets/wgl/libgallium_wgl.dll'
    release = json.loads((REPO / 'graphics/opengl/releases/0.2.31-darwin-arm64.json').read_text())
    patches = [REPO / 'graphics/opengl/windows-zink-present-timing.patch']
    if args.cached_batch:
        patches.append(REPO / 'graphics/opengl/windows-zink-readback-cache.patch')
    if args.batch_readback:
        patches.append(REPO / 'graphics/opengl/windows-zink-batch-readback.patch')
    if args.compare_readback:
        patches.append(REPO / 'graphics/opengl/windows-zink-readback-compare.patch')
    if args.batch_box:
        patches.append(REPO / 'graphics/opengl/windows-zink-batch-box.patch')
    if args.reuse_readback:
        patches.append(REPO / 'graphics/opengl/windows-zink-reuse-readback.patch')
    if args.batch_host_read:
        patches.append(REPO / 'graphics/opengl/windows-zink-batch-host-read.patch')
    if args.cached_batch:
        patches.append(REPO / 'graphics/opengl/windows-zink-batch-cache.patch')
    meson, ninja = args.meson.resolve(strict=True), args.ninja.resolve(strict=True)
    if subprocess.check_output([str(meson), '--version'], text=True).strip() != '1.12.1':
        raise ValueError('Use Meson 1.12.1, matching the qualified cache')
    with (cache / 'wgl-diagnostic-build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        original, qualified = wgl.read_bytes(), dll.read_bytes()
        if sha(original) != SOURCE_SHA or sha(qualified) != release['files']['x64/libgallium_wgl.dll']:
            raise ValueError('Local source/DLL differs from the qualified timing baseline')
        originals = {wgl: original}
        if args.batch_readback or args.reuse_readback:
            sources = dict(BATCH_SOURCES if args.batch_readback else REUSE_SOURCES)
            if args.cached_batch:
                sources.update(REUSE_SOURCES)
            if args.compare_readback:
                sources['src/gallium/drivers/zink/zink_context.c'] = REUSE_SOURCES['src/gallium/drivers/zink/zink_context.c']
            for name, expected in sources.items():
                file = source / name
                originals[file] = file.read_bytes()
                if sha(originals[file]) != expected:
                    raise ValueError('Local Zink source differs: ' + name)
        output.mkdir(parents=True, exist_ok=False)
        (output / 'wgl-before.c').write_bytes(original)
        for file, data in originals.items():
            backup = output / 'original' / file.relative_to(source)
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(data)
        (output / 'libgallium_wgl-before.dll').write_bytes(qualified)
        signal.signal(signal.SIGTERM, interrupted)
        env = os.environ.copy()
        env['PATH'] = os.pathsep.join([str(args.meson.absolute().parent), str(args.ninja.absolute().parent), env.get('PATH', '')])
        try:
            for patch in patches:
                subprocess.run(['patch', '-p1', '--batch', '--forward', '-i', str(patch)], cwd=source, check=True)
            with (output / 'build.log').open('w') as log:
                subprocess.run([str(ninja), '-j2', '-C', str(build), 'src/gallium/targets/wgl/libgallium_wgl.dll'],
                               env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            candidate = dll.read_bytes()
            (output / 'libgallium_wgl.dll').write_bytes(candidate)
            (output / 'receipt.json').write_text(json.dumps({
                'diagnostic_only': True, 'source_sha256': SOURCE_SHA,
                'patches': {p.name: sha(p.read_bytes()) for p in patches}, 'dll_sha256': sha(candidate),
                'baseline_sha256': sha(qualified), 'mesa': '25.1.9', 'meson': '1.12.1',
                'architecture': 'x64', 'limit': 600, 'batch_readback_opt_in': args.batch_readback,
                'reuse_readback_opt_in': args.reuse_readback, 'readback_compare': args.compare_readback, 'batch_host_read': args.batch_host_read, 'batch_box': args.batch_box, 'cached_batch': args.cached_batch,
            }, indent=2) + '\n')
        finally:
            for file, data in originals.items():
                file.write_bytes(data)
            dll.write_bytes(qualified)
        print('Private timing DLL built; qualified source/DLL restored. Windows unchanged.')


if __name__ == '__main__':
    main()
