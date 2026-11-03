#!/usr/bin/env python3
"""Reconstruct the private Win32 UMD candidate; never installs or changes Windows."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('native_recipe', REPO / 'scripts/rebuild-native-video.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('mesa', 'wdk', 'llvm'):
        p.add_argument('--' + name + '-archive', type=Path, required=True)
    for name in ('windows-sdk', 'x86-sdk', 'meson', 'ninja', 'output'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--prepare-only', action='store_true')
    a = p.parse_args()
    pins = json.loads((REPO / 'graphics/driver/x86-umd-inputs.json').read_text())
    output = a.output.resolve()
    if output.exists() or output.is_relative_to(REPO):
        raise ValueError('Use a fresh output outside the repository')
    archives = {n: getattr(a, n + '_archive').resolve(strict=True) for n in ('mesa', 'wdk', 'llvm')}
    for name, path in archives.items():
        if recipe.digest(path) != pins[name]['sha256']:
            raise ValueError('Archive differs: ' + name)
    patch = REPO / 'graphics/driver/x86-size-t-wire.patch'
    if recipe.digest(patch) != pins['patch_sha256']:
        raise ValueError('Shared patch differs from pin')
    toolchain_patch = REPO / 'graphics/opengl/windows-clang-atomics.patch'
    if recipe.digest(toolchain_patch) != pins['toolchain_patch_sha256']:
        raise ValueError('Qualified Clang atomics patch differs')
    sdk, x86 = a.windows_sdk.resolve(strict=True), a.x86_sdk.resolve(strict=True)
    for root, files in ((sdk, pins['tools']), (x86, pins['sdk_files'])):
        for name, sha in files.items():
            if recipe.digest(root / name) != sha:
                raise ValueError('Tool/SDK differs: ' + name)
    compiler = sdk / 'clang-cl'
    if subprocess.check_output([str(compiler), '--version'], text=True).splitlines()[0] != pins['compiler_version']:
        raise ValueError('Compiler version differs')
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([str(a.meson.absolute().parent), str(a.ninja.absolute().parent), str(sdk), env.get('PATH', '')])
    code = 'import importlib.metadata as m,json;print(json.dumps({p:m.version(p) for p in ' + repr(list(pins['python_packages'])) + '}))'
    if json.loads(subprocess.check_output([shutil.which('python3', path=env['PATH']), '-c', code], env=env, text=True)) != pins['python_packages']:
        raise ValueError('Python build packages differ')
    output.mkdir(parents=True)
    source = output / 'source'
    recipe.extract(archives['mesa'], source)
    wdk = output / 'wdk'
    with zipfile.ZipFile(archives['wdk']) as z:
        for name in z.namelist():
            rel = Path(name)
            if rel.is_absolute() or '..' in rel.parts:
                raise ValueError('Unsafe archive path')
            if name.startswith('c/Include/') and not name.endswith('/'):
                target = wdk / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(z.read(name))
    rc = output / 'llvm-rc'
    with tarfile.open(archives['llvm'], 'r|*') as z:
        for member in z:
            if member.name.endswith('/bin/llvm-rc') and member.isfile():
                rc.write_bytes(z.extractfile(member).read())
                rc.chmod(0o755)
                break
    if not rc.exists():
        raise ValueError('Resource compiler missing')
    commands = []

    def run(command, cwd=None):
        command = list(map(str, command))
        commands.append(command)
        subprocess.run(command, cwd=cwd, env=env, check=True)

    header = source / 'src/virtio/neptune/neptune-protocol/npt_protocol_common_types.h'
    if recipe.digest(header) != pins['original_header_sha256']:
        raise ValueError('Protocol source differs')
    run(['git', 'apply', '--check', patch], source)
    run(['git', 'apply', patch], source)
    run(['git', 'apply', '--check', toolchain_patch], source)
    run(['git', 'apply', toolchain_patch], source)
    includes = [wdk / 'c/Include' / pins['wdk']['include_version'] / n for n in ('um', 'shared')]
    includes += [x86 / n for n in ('sdk/include/ucrt', 'sdk/include/shared', 'sdk/include/um', 'sdk/include/winrt', 'crt/include')]
    flags = ['/clang:--target=i686-pc-windows-msvc'] + ['/imsvc' + str(n) for n in includes]
    wrapper = output / 'clang-cl'
    wrapper.write_text('#!/usr/bin/python3\nimport os,sys\nargs=' + repr(['-fuse-ld=lld', *flags]) + '''
for a in sys.argv[1:]:
 if a == '-fuse-ld=lld-link': continue
 if a.startswith('/') and os.path.isfile(a) and a.lower().endswith(('.c','.cc','.cpp','.obj','.o')): a=os.path.relpath(a)
 args.append(a)
''' + 'os.execv(' + repr(str(compiler)) + ', ["clang-cl", "--driver-mode=cl", *args])\n')
    wrapper.chmod(0o755)
    rc_wrapper = output / 'llvm-rc-wrapper'
    rc_wrapper.write_text('#!/usr/bin/python3\nimport os,sys\nif sys.argv[1:]==["/?"]:\n print("LLVM Resource Converter 15.0.7");sys.exit(0)\n' +
                          'os.execv(' + repr(str(rc)) + ', ["llvm-rc", ' + ', '.join(repr('/I' + str(n)) for n in includes) + ', *sys.argv[1:]])\n')
    rc_wrapper.chmod(0o755)
    links = ['/LIBPATH:' + str(x86 / n / 'x86') for n in ('sdk/lib/um', 'sdk/lib/ucrt', 'crt/lib')]
    cross = output / 'cross.ini'
    cross.write_text('[binaries]\nc = ' + repr([str(wrapper)]) + '\ncpp = ' + repr([str(wrapper)]) +
                     '\nar = ' + repr(str(sdk / 'llvm-lib')) + "\nc_ld = 'lld-link'\ncpp_ld = 'lld-link'\nwindres = " + repr(str(rc_wrapper)) +
                     "\n[host_machine]\nsystem = 'windows'\ncpu_family = 'x86'\ncpu = 'i686'\nendian = 'little'\n[built-in options]\n" +
                     'c_args = ' + repr(flags) + '\ncpp_args = ' + repr(flags) + '\nc_link_args = ' + repr(links) + '\ncpp_link_args = ' + repr(links) + "\nb_vscrt = 'mt'\n")
    receipt = {'pins': pins, 'commands': commands, 'qualification': 'source only; never installed', 'header_sha256': recipe.digest(header)}
    if not a.prepare_only:
        build = output / 'build'
        options = ['neptune=true', 'npt_wine=false', 'npt_umd=ddi', 'npt_umd_version=100.6.101.58000',
                   'llvm=disabled', 'gallium-drivers=', 'vulkan-drivers=', 'platforms=', 'opengl=false',
                   'gles1=disabled', 'gles2=disabled', 'glx=disabled', 'egl=disabled', 'shared-glapi=disabled',
                   'shader-cache=disabled', 'zlib=disabled', 'zstd=disabled', 'libunwind=disabled',
                   'valgrind=disabled', 'build-tests=false', 'video-codecs=']
        run([a.meson, 'setup', build, source, '--cross-file', cross, '--buildtype=release', *['-D' + o for o in options]])
        run([a.ninja, '-C', build, '-j1', 'src/virtio/neptune/triton/neptune_umd.dll'])
        receipt.update(umd_sha256=recipe.digest(build / 'src/virtio/neptune/triton/neptune_umd.dll'), qualification='build only; isolated Windows test required')
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
