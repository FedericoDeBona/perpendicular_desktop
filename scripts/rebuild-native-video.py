#!/usr/bin/env python3
"""Build the private NV12 and native D3D11 VP9 prerequisites from pinned source archives.

Does not install, sign, package a runtime, or touch an app/Windows/VM.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

REPO = Path(__file__).resolve().parent.parent


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def extract(archive, destination, llvm=False):
    # Archives are hash-checked before extraction; still reject path traversal.
    root = None
    with tarfile.open(archive, 'r|*') as members:
        for member in members:
            path = Path(member.name)
            parts = path.parts
            if path.is_absolute() or '..' in parts or not parts:
                raise ValueError('Unsafe archive path')
            if root is None:
                root = parts[0]
            if parts[0] != root:
                raise ValueError('Multiple archive roots')
            if len(parts) < 2:
                continue
            relative = Path(*parts[1:])
            if llvm and (relative.parts[0] not in ('include', 'lib') or
                         relative.name in ('libc++.a', 'libc++abi.a')):
                # Use the host SDK C++ runtime, not LLVM's unrelated static libc++.
                continue
            target = destination / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with members.extractfile(member) as src, target.open('xb') as dst:
                    shutil.copyfileobj(src, dst)
            elif not (member.issym() or member.islnk()):
                raise ValueError('Unsupported archive member')
            # Neither build needs archive symlinks, devices, or hard links.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('dxmt', 'headers', 'llvm'):
        parser.add_argument('--' + name + '-archive', type=Path, required=True)
    parser.add_argument('--meson', type=Path, required=True)
    parser.add_argument('--ninja', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    pins = json.loads((REPO / 'graphics/backend/video-inputs.json').read_text())
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(REPO):
        raise ValueError('A fresh private output outside the repository is required')
    archives = {name: getattr(args, name + '_archive').resolve(strict=True)
                for name in ('dxmt', 'headers', 'llvm')}
    for name, path in archives.items():
        if digest(path) != pins[name]['sha256']:
            raise ValueError('Archive differs from the pinned input: ' + name)
    patches = [REPO / 'graphics/backend' / name for name in
               ('shared-initialization.patch', 'nv12-native.patch', 'vp9-video-device.patch', 'video-resource-submit.patch', 'shared-video-native.patch', 'video-named-errors.patch')]
    for patch, key in zip(patches, ('shared_initialization_patch_sha256', 'nv12_patch_sha256', 'vp9_video_patch_sha256', 'resource_submit_patch_sha256', 'shared_video_patch_sha256', 'named_errors_patch_sha256')):
        if digest(patch) != pins[key]:
            raise ValueError('Patch differs from the pinned input: ' + patch.name)
    header = REPO / 'graphics/backend/video-resource-submit.h'
    if digest(header) != pins['resource_submit_header_sha256']:
        raise ValueError('Resource submission ABI differs from the pinned input')
    meson, ninja = args.meson.resolve(strict=True), args.ninja.resolve(strict=True)
    env = dict(os.environ)
    env['PATH'] = str(ninja.parent) + os.pathsep + env.get('PATH', '')
    output.mkdir(parents=True)
    source, llvm, build = [output / name for name in ('source', 'llvm', 'build')]
    extract(archives['dxmt'], source)
    extract(archives['headers'], source / 'include/native/directx')
    extract(archives['llvm'], llvm, llvm=True)
    commands = []

    def run(command, cwd=None):
        command = list(map(str, command))
        commands.append(command)
        subprocess.run(command, cwd=cwd, env=env, check=True)

    for index, patch in enumerate(patches):
        run(['git', 'apply', '--check', patch], cwd=source)
        run(['git', 'apply', patch], cwd=source)
        if index == 0 and digest(source / 'src/d3d11/d3d11_texture_device.cpp') != pins['shared_initialization_source_sha256']:
            raise ValueError('The existing shared-initialization fix was not reconstructed')
    shutil.copyfile(header, source / 'src/d3d11/video-resource-submit.h')
    run([meson, 'setup', build, source, '-Dnative_llvm_path=' + str(llvm),
         '-Dbuildtype=release', '-Doptimization=3', '-Db_lto=false', '-Denable_tests=false'])
    run([ninja, '-C', build, '-j1', 'src/dxmt-native/libdxmt-native.dylib'])
    library = build / 'src/dxmt-native/libdxmt-native.dylib'
    receipt = {'inputs': pins, 'commands': commands, 'backend_sha256': digest(library),
               'qualification': 'build-only; run NativeVideoDecodeChecks, NativeVideoTextureChecks and NativeSharedTextureChecks'}
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(library)


if __name__ == '__main__':
    main()
