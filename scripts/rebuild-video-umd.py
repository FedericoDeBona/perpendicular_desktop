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
    parser.add_argument('--bounded-map-growth', action='store_true', help='Opt in to v15 pressure cap experiment; browser performance is not qualified')
    parser.add_argument('--external-video-discard', action='store_true', help='Opt in to v16 shared input storage on decoder DISCARD; browser performance is not qualified')
    parser.add_argument('--present-amortization', action='store_true', help='Apply upstream present object cleanup to v16; requires --external-video-discard, Windows qualification required')
    parser.add_argument('--target-independent-coverage', action='store_true', help='Opt in to v18 upstream TIR coverage fixes above v17; requires --present-amortization, Windows qualification required')
    parser.add_argument('--map-timing', action='store_true', help='Opt-in diagnostic Map phase timing above v18; no performance qualification or production promotion')
    parser.add_argument('--async-pool-retire', action='store_true', help='Apply old-pool retirement above v18; --map-timing retains the separate diagnostic profile')
    parser.add_argument('--prepare-only', action='store_true', help='Check inputs and reconstruct source without compiling')
    parser.add_argument('--toolchain-profile', default='original',
                        help='Explicit pinned toolchain; profiles do not change the driver/source ABI')
    args = parser.parse_args()
    if args.bounded_map_growth and args.external_video_discard:
        parser.error('Choose one driver experiment at a time')
    if args.present_amortization and not args.external_video_discard:
        parser.error('--present-amortization requires the deployed --external-video-discard baseline')
    if args.target_independent_coverage and not args.present_amortization:
        parser.error('--target-independent-coverage requires the qualified --present-amortization baseline')
    if args.map_timing and not args.target_independent_coverage:
        parser.error('--map-timing requires the v18 coverage baseline')
    if args.async_pool_retire and not args.target_independent_coverage:
        parser.error('--async-pool-retire requires the v18 coverage baseline')
    pins = json.loads((REPO / 'graphics/backend/video-umd-inputs.json').read_text())
    if args.bounded_map_growth:
        pins['candidate_revision'] = pins['bounded_map_growth_revision']
    if args.external_video_discard:
        pins['candidate_revision'] = pins['external_video_discard_revision']
    if args.present_amortization:
        pins['candidate_revision'] = pins['present_amortization_revision']
    if args.target_independent_coverage:
        pins['candidate_revision'] = pins['target_independent_coverage_revision']
    if args.map_timing:
        pins['candidate_revision'] = pins['map_timing_revision']
    if args.async_pool_retire:
        pins['candidate_revision'] = pins['async_pool_retire_revision' if args.map_timing
                                          else 'async_pool_retire_production_revision']
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
    patch, processor_patch, allocation_trace_patch, compact_shmem_patch, bounded_growth_patch, header = [REPO / 'graphics/backend' / name for name in
                                     ('video-ddi.patch', 'video-processor-ddi.patch', 'map-allocation-trace.patch', 'compact-shmem-fallback.patch', 'bounded-map-growth.patch', 'video-resource-submit.h')]
    for path, key in ((patch, 'mesa_patch_sha256'), (processor_patch, 'processor_patch_sha256'),
                      (allocation_trace_patch, 'map_allocation_trace_patch_sha256'),
                      (compact_shmem_patch, 'compact_shmem_patch_sha256'),
                      (bounded_growth_patch, 'bounded_map_growth_patch_sha256'),
                      (header, 'resource_header_sha256')):
        if digest(path) != pins[key]:
            raise ValueError('Shared fix differs from the pinned input: ' + path.name)
    sdk = args.windows_sdk.resolve(strict=True)
    external_patch = REPO / 'graphics/backend/external-video-discard.patch'
    if digest(external_patch) != pins['external_video_discard_patch_sha256']:
        raise ValueError('Shared fix differs from the pinned input: ' + external_patch.name)
    present_patch = REPO / 'graphics/backend/present-amortization.patch'
    if digest(present_patch) != pins['present_amortization_patch_sha256']:
        raise ValueError('Shared fix differs from the pinned input: ' + present_patch.name)
    coverage_patches = []
    if args.target_independent_coverage:
        for name, key in (
                ('sample-mask-no-targets.patch', 'sample_mask_no_targets_patch_sha256'),
                ('target-independent-coverage.patch', 'target_independent_coverage_patch_sha256'),
                ('target-independent-coverage-version.patch', 'target_independent_coverage_version_patch_sha256')):
            coverage_patch = REPO / 'graphics/backend' / name
            if digest(coverage_patch) != pins[key]:
                raise ValueError('Shared fix differs from the pinned input: ' + coverage_patch.name)
            coverage_patches.append(coverage_patch)
    for name, expected in pins['sdk_files'].items():
        if digest(sdk / name) != expected:
            raise ValueError('SDK/tool input differs: ' + name)
    map_patch = REPO / 'graphics/backend/map-timing.patch'
    map_header = REPO / 'graphics/backend/map-timing.h'
    if args.map_timing:
        for path, key in ((map_patch, 'map_timing_patch_sha256'), (map_header, 'map_timing_header_sha256')):
            if digest(path) != pins[key]:
                raise ValueError('Map diagnostic differs from its shared pin: ' + path.name)
    pool_patch = REPO / 'graphics/backend' / ('async-pool-retire.patch' if args.map_timing
                                              else 'async-pool-retire-production.patch')
    pool_header = REPO / 'graphics/backend/pool-retire-timing.h'
    if args.async_pool_retire:
        pool_inputs = [(pool_patch, 'async_pool_retire_patch_sha256'),
                       (pool_header, 'pool_retire_timing_header_sha256')] if args.map_timing else [
                       (pool_patch, 'async_pool_retire_production_patch_sha256')]
        for path, key in pool_inputs:
            if digest(path) != pins[key]:
                raise ValueError('Pool candidate differs from its shared pin: ' + path.name)
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
    if args.bounded_map_growth:
        run(['git', 'apply', '--check', bounded_growth_patch], cwd=source)
        run(['git', 'apply', bounded_growth_patch], cwd=source)
    if args.external_video_discard:
        run(['git', 'apply', '--check', external_patch], cwd=source)
        run(['git', 'apply', external_patch], cwd=source)
    if args.present_amortization:
        run(['git', 'apply', '--check', present_patch], cwd=source)
        run(['git', 'apply', present_patch], cwd=source)
    for coverage_patch in coverage_patches:
        run(['git', 'apply', '--check', coverage_patch], cwd=source)
        run(['git', 'apply', coverage_patch], cwd=source)
    if args.map_timing:
        run(['git', 'apply', '--check', map_patch], cwd=source)
        run(['git', 'apply', map_patch], cwd=source)
        shutil.copyfile(map_header, source / 'src/virtio/neptune/triton/map-timing.h')
    if args.async_pool_retire:
        run(['git', 'apply', '--check', pool_patch], cwd=source)
        run(['git', 'apply', pool_patch], cwd=source)
        if args.map_timing:
            shutil.copyfile(pool_header, source / 'src/virtio/neptune/triton/pool-retire-timing.h')
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
    receipt = {'inputs': pins, 'bounded_map_growth_experiment': args.bounded_map_growth,
               'external_video_discard_experiment': args.external_video_discard,
               'target_independent_coverage_experiment': args.target_independent_coverage,
               'map_timing_diagnostic': args.map_timing,
               'async_pool_retire_experiment': args.async_pool_retire,
               'async_pool_retire_without_timing': args.async_pool_retire and not args.map_timing,
               'present_amortization': args.present_amortization, 'toolchain_profile': args.toolchain_profile, 'compiler': version, 'commands': commands,
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
        if args.target_independent_coverage and pins['candidate_revision'].encode('utf-16-le') not in library.read_bytes():
            raise ValueError('Built candidate does not contain the pinned PrivateBuild marker')
        receipt.update(umd_sha256=digest(library), qualification='build only; unsigned candidate, no Windows video qualification')
        print(library)
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')


if __name__ == '__main__':
    main()
