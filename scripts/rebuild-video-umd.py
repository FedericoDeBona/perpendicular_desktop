#!/usr/bin/env python3
"""Build a private ARM64 video UMD; never installs drivers or changes Windows.

Uses the paired, pinned Mesa/Neptune source and the shared resource ABI.
The resulting unsigned DLL is experimental, not a replacement driver package.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile

import importlib.util

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('native_video_recipe', REPO / 'scripts/rebuild-native-video.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
digest, extract = recipe.digest, recipe.extract


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('mesa', 'wdk', 'llvm'):
        parser.add_argument('--' + name + '-archive', type=Path, required=True)
    parser.add_argument('--windows-sdk', type=Path, required=True,
                        help='Tool directory containing clang-cl, lld-link, llvm-lib and xwin/')
    parser.add_argument('--meson', type=Path, required=True)
    parser.add_argument('--ninja', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prepare-only', action='store_true', help='Check inputs and reconstruct source without compiling')
    parser.add_argument('--toolchain-profile', default='original',
                        help='Explicit pinned toolchain; profiles do not change the driver/source ABI')
    args = parser.parse_args()
    pins = json.loads((REPO / 'graphics/backend/video-umd-inputs.json').read_text())
    if args.toolchain_profile != 'original':
        profiles = pins.get('toolchain_profiles', {})
        if args.toolchain_profile not in profiles:
            raise ValueError('Unknown pinned toolchain profile: ' + args.toolchain_profile)
        profile = profiles[args.toolchain_profile]
        pins = {**pins, 'compiler_version': profile['compiler_version'],
                'sdk_files': {**pins['sdk_files'], **profile['sdk_files']}}
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(REPO):
        raise ValueError('A fresh output outside the repository is required')
    archives = {name: getattr(args, name + '_archive').resolve(strict=True) for name in ('mesa', 'wdk', 'llvm')}
    for name, key in (('mesa', 'mesa'), ('wdk', 'wdk'), ('llvm', 'llvm_resource_compiler')):
        if digest(archives[name]) != pins[key]['sha256']:
            raise ValueError('Archive differs from the pinned input: ' + name)
    patch, processor_patch, allocation_trace_patch, compact_shmem_patch, header = [REPO / 'graphics/backend' / name for name in
                                     ('video-ddi.patch', 'video-processor-ddi.patch', 'map-allocation-trace.patch', 'compact-shmem-fallback.patch', 'video-resource-submit.h')]
    for path, key in ((patch, 'mesa_patch_sha256'), (processor_patch, 'processor_patch_sha256'),
                      (allocation_trace_patch, 'map_allocation_trace_patch_sha256'),
                      (compact_shmem_patch, 'compact_shmem_patch_sha256'),
                      (header, 'resource_header_sha256')):
        if digest(path) != pins[key]:
            raise ValueError('Shared fix differs from the pinned input: ' + path.name)
    sdk = args.windows_sdk.resolve(strict=True)
    for name, expected in pins['sdk_files'].items():
        if digest(sdk / name) != expected:
            raise ValueError('SDK/tool input differs: ' + name)
    compiler = sdk / 'clang-cl'
    version = subprocess.check_output([str(compiler), '--version'], text=True).splitlines()[0]
    if version != pins['compiler_version']:
        raise ValueError('Compiler differs from the qualified version: ' + version)
    meson, ninja = args.meson.resolve(strict=True), args.ninja.resolve(strict=True)
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([str(args.meson.absolute().parent), str(args.ninja.absolute().parent), str(sdk), env.get('PATH', '')])
    # Meson finds Python through PATH. Check the same interpreter and packages
    # it will use, before generating any output.
    python = shutil.which('python3', path=env['PATH'])
    code = 'import importlib.metadata as m,json; print(json.dumps({p:m.version(p) for p in '+repr(list(pins['python_packages']))+'}))'
    packages = json.loads(subprocess.check_output([python, '-c', code], env=env, text=True))
    if packages != pins['python_packages']:
        raise ValueError('Use a Python environment with the pinned Meson/Mako versions')
    output.mkdir(parents=True)
    source = output / 'source'
    extract(archives['mesa'], source)
    wdk = output / 'wdk'
    with zipfile.ZipFile(archives['wdk']) as archive:
        for name in archive.namelist():
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Unsafe WDK archive path')
            if not name.startswith('c/Include/') or name.endswith('/'):
                continue
            target = wdk / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(name))
    resource_compiler = output / 'llvm-rc'
    with tarfile.open(archives['llvm'], 'r|*') as archive:
        for member in archive:
            if member.name.endswith('/bin/llvm-rc') and member.isfile():
                resource_compiler.write_bytes(archive.extractfile(member).read())
                resource_compiler.chmod(0o755)
                break
    if not resource_compiler.exists():
        raise ValueError('Resource compiler missing from pinned LLVM input')
    commands = []

    def run(command, cwd=None):
        command = list(map(str, command))
        commands.append(command)
        subprocess.run(command, cwd=cwd, env=env, check=True)

    run(['git', 'apply', '--check', patch], cwd=source)
    run(['git', 'apply', patch], cwd=source)
    run(['git', 'apply', '--check', processor_patch], cwd=source)
    run(['git', 'apply', processor_patch], cwd=source)
    run(['git', 'apply', '--check', allocation_trace_patch], cwd=source)
    run(['git', 'apply', allocation_trace_patch], cwd=source)
    run(['git', 'apply', '--check', compact_shmem_patch], cwd=source)
    run(['git', 'apply', compact_shmem_patch], cwd=source)
    shutil.copyfile(header, source / 'src/virtio/neptune/triton/video-resource-submit.h')
    includes = [wdk / 'c/Include' / pins['wdk']['include_version'] / kind for kind in ('um', 'shared')]
    includes += [sdk / 'xwin' / name for name in ('sdk/include/ucrt', 'sdk/include/shared', 'sdk/include/um', 'sdk/include/winrt', 'crt/include')]
    aliases = ['exchange64', 'exchangeadd64', 'increment64', 'decrement64', 'add', 'add64']
    # The pinned Mesa source spells six ARM64 intrinsic names in lower case;
    # Apple clang exposes the documented _Interlocked* names instead.
    intrinsic_flags = ['/D_interlocked'+n+'=_Interlocked'+n[0].upper()+n[1:] for n in aliases]
    # ExchangeAdd/Increment/Decrement have a second capitalised word.
    intrinsic_flags = [f.replace('Exchangeadd', 'ExchangeAdd') for f in intrinsic_flags]
    compile_args = ['/clang:--target=aarch64-pc-windows-msvc'] + ['/imsvc'+str(path) for path in includes]
    wrapper = output / 'clang-cl'
    wrapper.write_text('#!/usr/bin/python3\nimport os,sys\nargs='+repr(['-fuse-ld=lld', *intrinsic_flags, *compile_args])+'''\nfor a in sys.argv[1:]:
 if a == '-fuse-ld=lld-link': continue
 if a.startswith('/') and os.path.isfile(a) and a.lower().endswith(('.c','.cc','.cpp','.obj','.o')): a=os.path.relpath(a)
 args.append(a)
'''+'os.execv('+repr(str(compiler))+', ["clang-cl", "--driver-mode=cl", *args])\n')
    wrapper.chmod(0o755)
    rc_wrapper = output / 'llvm-rc-wrapper'
    rc_wrapper.write_text('#!/usr/bin/python3\nimport os,sys\nif sys.argv[1:]==["/?"]:\n print("LLVM Resource Converter 15.0.7");sys.exit(0)\n' +
                          'os.execv('+repr(str(resource_compiler))+', ["llvm-rc", '+', '.join(repr('/I'+str(path)) for path in includes)+', *sys.argv[1:]])\n')
    rc_wrapper.chmod(0o755)
    link_args = ['/LIBPATH:'+str(sdk / 'xwin' / name / 'aarch64') for name in ('sdk/lib/um', 'sdk/lib/ucrt', 'crt/lib')]
    cross = output / 'cross.ini'
    cross.write_text('[binaries]\nc = '+repr([str(wrapper)])+'\ncpp = '+repr([str(wrapper)])+
                     '\nar = '+repr(str(sdk / 'llvm-lib'))+"\nc_ld = 'lld-link'\ncpp_ld = 'lld-link'\nwindres = "+repr(str(rc_wrapper))+
                     "\n[host_machine]\nsystem = 'windows'\ncpu_family = 'aarch64'\ncpu = 'armv8'\nendian = 'little'\n[built-in options]\n"+
                     'c_args = '+repr(compile_args)+'\ncpp_args = '+repr(compile_args)+'\nc_link_args = '+repr(link_args)+
                     '\ncpp_link_args = '+repr(link_args)+"\nb_vscrt = 'mt'\n")
    receipt = {'inputs': pins, 'toolchain_profile': args.toolchain_profile, 'compiler': version, 'commands': commands,
               'qualification': 'source preparation only; no Windows install or video qualification'}
    if not args.prepare_only:
        build = output / 'build'
        options = ['neptune=true', 'npt_wine=false', 'npt_umd=ddi', 'npt_umd_version='+pins['candidate_file_version'],
                   'llvm=disabled', 'gallium-drivers=', 'vulkan-drivers=', 'platforms=', 'opengl=false',
                   'gles1=disabled', 'gles2=disabled', 'glx=disabled', 'egl=disabled', 'shared-glapi=disabled',
                   'shader-cache=disabled', 'zlib=disabled', 'zstd=disabled', 'libunwind=disabled',
                   'valgrind=disabled', 'build-tests=false', 'video-codecs=']
        run([meson, 'setup', build, source, '--cross-file', cross, '--buildtype=release', *['-D'+option for option in options]])
        run([ninja, '-C', build, '-j1', 'src/virtio/neptune/triton/neptune_umd.dll'])
        library = build / 'src/virtio/neptune/triton/neptune_umd.dll'
        receipt.update(umd_sha256=digest(library), qualification='build only; unsigned candidate, no Windows video qualification')
        print(library)
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')


if __name__ == '__main__':
    main()
