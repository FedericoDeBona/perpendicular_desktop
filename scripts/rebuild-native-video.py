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
    parser.add_argument('--gpu-output', action='store_true', help='Opt in to the pixel-qualified GPU transfer experiment; browser performance is not qualified')
    parser.add_argument('--reuse-bitstream-staging', action='store_true', help='Opt in to bounded per-decoder input staging reuse; browser performance must be qualified')
    parser.add_argument('--cpu-video-input', action='store_true', help='Opt in to the pixel-qualified CPU input experiment; no browser gain qualified')
    parser.add_argument('--shared-origin-trace', action='store_true', help='QA-only bounded CPU origin trace for shared BGRA atlases; not a graphics fix or performance qualification')
    parser.add_argument('--late-texture-initialization-fences', action='store_true', help='QA candidate: retain GPU dependencies for textures created before their initial upload')
    args = parser.parse_args()
    if args.cpu_video_input and args.reuse_bitstream_staging:
        raise ValueError('CPU video input and the rejected staging reuse experiment must be qualified separately')
    if (args.shared_origin_trace or args.late_texture_initialization_fences) and (args.gpu_output or args.reuse_bitstream_staging or args.cpu_video_input):
        raise ValueError('Qualify the Desktop diagnostic/candidate separately from video experiments')
    pins = json.loads((REPO / 'graphics/backend/video-inputs.json').read_text())
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(REPO):
        raise ValueError('A fresh private output outside the repository is required')
    archives = {name: getattr(args, name + '_archive').resolve(strict=True)
                for name in ('dxmt', 'headers', 'llvm')}
    for name, path in archives.items():
        if digest(path) != pins[name]['sha256']:
            raise ValueError('Archive differs from the pinned input: ' + name)
    patch_inputs = (
        ('shared-initialization.patch', 'shared_initialization_patch_sha256'),
        ('nv12-native.patch', 'nv12_patch_sha256'),
        ('vp9-video-device.patch', 'vp9_video_patch_sha256'),
        ('video-resource-submit.patch', 'resource_submit_patch_sha256'),
        ('shared-video-native.patch', 'shared_video_patch_sha256'),
        ('video-named-errors.patch', 'named_errors_patch_sha256'),
        ('video-processor-format-support.patch', 'processor_formats_patch_sha256'),
        ('video-processor-native.patch', 'processor_patch_sha256'),
        ('native-shared-origin-trace.patch', 'shared_origin_trace_patch_sha256'),
        ('native-late-texture-initialization.patch', 'late_texture_initialization_patch_sha256'),
        ('vp9-gpu-output.patch', 'vp9_gpu_output_patch_sha256'),
        ('video-staging-reuse.patch', 'staging_reuse_patch_sha256'),
        ('video-staging-input.patch', 'staging_input_patch_sha256'),
    )
    patches = [REPO / 'graphics/backend' / name for name, _ in patch_inputs
               if (name != 'vp9-gpu-output.patch' or args.gpu_output)
               and (name != 'video-staging-reuse.patch' or args.reuse_bitstream_staging)
               and (name != 'video-staging-input.patch' or args.cpu_video_input)]
    patches = [patch for patch in patches
               if patch.name != 'native-shared-origin-trace.patch' or args.shared_origin_trace]
    patches = [patch for patch in patches
               if patch.name != 'native-late-texture-initialization.patch' or args.late_texture_initialization_fences]
    for name, key in patch_inputs:
        if digest(REPO / 'graphics/backend' / name) != pins[key]:
            raise ValueError('Patch differs from the pinned input: ' + name)
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
    receipt = {'inputs': pins, 'gpu_output_experiment': args.gpu_output,
               'shared_origin_trace_experiment': args.shared_origin_trace,
               'late_texture_initialization_fences_experiment': args.late_texture_initialization_fences,
               'staging_reuse_experiment': args.reuse_bitstream_staging,
               'cpu_video_input_experiment': args.cpu_video_input, 'commands': commands, 'backend_sha256': digest(library),
               'qualification': 'build-only; qualify processor pixels, decoder, ordinary/shared NV12 and BGRA, then Windows/Edge separately'}
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(library)


if __name__ == '__main__':
    main()
