#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build a private whole-source QEMU with the native Metal publisher; never install or launch."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
COMMON = ROOT / '.tools/graphics-experiment'
TOOLS = ROOT / '.tools/build-venv/bin'
GIT = '/Library/Developer/CommandLineTools/usr/bin/git'
PIN = '88e5ee7ec6703662fec7b638cca74c4769e683d6'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


shared = module('wire1_rebuild', ROOT / 'scripts/graphics-wire1-rebuild.py')
cocoa = module('native_cocoa_patch', ROOT / 'experimental/cocoa-native-display/build.py')
sha, require, save = shared.sha, shared.require, shared.save


def inventory(directory):
    return {str(p.relative_to(directory)): os.readlink(p) if p.is_symlink() else sha(p)
            for p in sorted(directory.rglob('*')) if p.is_file() or p.is_symlink()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--renderer', required=True, type=Path)
    parser.add_argument('--backend', required=True, type=Path)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--source-only', action='store_true')
    args = parser.parse_args()
    profiles = [args.output.absolute(), args.renderer.absolute(), args.backend.absolute()]
    for path in profiles:
        require(path.parent.resolve() == (ROOT / '.tools').resolve() and not path.is_symlink() and
                re.fullmatch(r'graphics-rebuild-[a-z0-9-]{1,64}', path.name), 'Expected private rebuild profile')
    base, renderer, backend = [p.parent.resolve() / p.name for p in profiles]
    require(len(set((base, renderer, backend))) == 3, 'Distinct profiles required')
    dependencies = {}
    for name, profile in (('renderer', renderer), ('backend', backend)):
        receipt = json.loads((profile / 'build.json').read_text())
        require(receipt['plan']['component'] == name and receipt['plan']['output'] == str(profile) and
                receipt['plan']['source']['pin'] == shared.PINS[name]['pin'], 'Matched build identity required')
        dependencies[str(profile / 'build.json')] = sha(profile / 'build.json')
        require(sha(profile / 'dependencies.json') == receipt['dependencies_sha256'], 'Dependency inventory changed')
        dependencies.update(json.loads((profile / 'dependencies.json').read_text()))
        dependencies.update({p: item['sha256'] for p, item in receipt['binaries'].items()})
    inputs = {str(p): sha(p) for p in [Path(__file__), ROOT / 'scripts/graphics-wire1-rebuild.py',
        ROOT / 'scripts/graphics-sources.json', ROOT / 'scripts/graphics-fetch.py',
        ROOT / 'experimental/cocoa-native-display/build.py', *cocoa.INPUTS.values()]}
    plan = {'schema': 1, 'qemu_pin': PIN, 'output': str(base), 'renderer': str(renderer),
            'backend': str(backend), 'optimization': '3', 'max_jobs': 2,
            'inputs': inputs, 'dependencies': dependencies}
    if args.resume:
        require(json.loads((base / 'plan.json').read_text()) == plan, 'Resume inputs/dependencies/plan changed')
    else:
        require(not os.path.lexists(base), 'Fresh output required, or resume exact plan')
        base.mkdir(mode=0o700); (base / 'logs').mkdir()
        save(base / 'plan.json', plan)
        app = Path('/Applications/Perpendicular Desktop.app')
        require(app.is_dir(), 'Installed app preservation baseline required')
        save(base / 'protected.json', {str(p): sha(p) for p in sorted(app.rglob('*')) if p.is_file()})

    def verify():
        for name, expected in {**inputs, **dependencies, **json.loads((base / 'protected.json').read_text())}.items():
            require(sha(Path(name)) == expected, 'Protected input changed: ' + name)

    verify()
    angle = COMMON / 'prefix/ANGLE.xcarchive/Products/usr/local/lib'
    prefix, build, source = base / 'prefix', base / 'build', base / 'src/qemu'
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('DYLD_', 'QEMU_', 'VIRGL_', 'NPT_', 'ANGLE_', 'PERP_'))}
    env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
        PATH=str(TOOLS) + ':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
        PYTHONPATH=str(COMMON / 'python-deps'), PYTHONDONTWRITEBYTECODE='1',
        PKG_CONFIG_PATH=':'.join(str(p / 'lib/pkgconfig') for p in (renderer / 'prefix', prefix, COMMON / 'prefix')),
        DYLD_FALLBACK_LIBRARY_PATH=':'.join(map(str, (renderer / 'prefix/lib', backend / 'prefix/lib', COMMON / 'prefix/lib', angle))),
        CMAKE_BUILD_PARALLEL_LEVEL='2', MAKEFLAGS='-j2', NINJAFLAGS='-j2')

    def run(label, command, cwd=None):
        path = base / 'logs' / (label + '-' + str(time.time_ns()) + '.log')
        print(label + ': ' + str(path.relative_to(ROOT)), flush=True)
        with path.open('w') as stream:
            stream.write(json.dumps({'argv': list(map(str, command)), 'cwd': str(cwd or ROOT)}) + '\n'); stream.flush()
            result = subprocess.run(list(map(str, command)), cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        require(result.returncode == 0, label + ' failed: ' + str(path))

    def capture(command):
        return subprocess.check_output(list(map(str, command)), env=env, text=True).strip()

    run('verify-sources', [sys.executable, ROOT / 'scripts/graphics-fetch.py', '--verify', '--qemu-wraps', '--python-tools'])
    require(capture([GIT, '-C', COMMON / 'src/qemu', 'rev-parse', 'HEAD']) == PIN, 'QEMU pin changed')
    prepared = base / 'source-files.json'
    if not prepared.exists():
        require(not source.exists(), 'Incomplete source preparation; preserve this attempt and choose a fresh profile')
        shutil.copytree(COMMON / 'src/qemu', source, symlinks=True, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        path = source / 'ui/cocoa.m'
        require(sha(path) == cocoa.COCOA_SHA, 'Pristine Cocoa source changed')
        path.write_text(cocoa.patch_cocoa(path.read_text()))
        for name, original in cocoa.INPUTS.items():
            shutil.copyfile(original, source / 'ui' / name)
        meson = source / 'ui/meson.build'
        anchor = "system_ss.add(when: cocoa, if_true: files('cocoa.m'))"
        require(meson.read_text().count(anchor) == 1, 'Cocoa build anchor changed')
        addition = """
if cocoa.found()
  native_frameworks = dependency('appleframeworks', modules: ['Metal', 'Foundation'])
  native_publisher = static_library('perp-native-publisher', 'publisher.m',
    objc_args: ['-fobjc-arc', '-fblocks'], dependencies: native_frameworks)
  native_transport = static_library('perp-native-transport', 'ndt.c', c_args: ['-std=c17'])
  system_ss.add(declare_dependency(link_whole: [native_publisher, native_transport],
    dependencies: native_frameworks))
endif
"""
        meson.write_text(meson.read_text().replace(anchor, anchor + addition))
        save(prepared, inventory(source))
    require(inventory(source) == json.loads(prepared.read_text()), 'Prepared source changed')
    verify()
    if args.source_only:
        print('Native publisher source prepared; no compiler/runtime/VM launched.', flush=True)
        return

    build.mkdir(exist_ok=True)
    slirp = base / 'slirp-build'
    meson = TOOLS / 'meson'
    if not (slirp / 'meson-private/coredata.dat').exists():
        run('slirp-configure', [meson, 'setup', slirp, source / 'subprojects/slirp', '--prefix=' + str(prefix),
            '--libdir=lib', '--buildtype=release', '--wrap-mode=nodownload', '-Doptimization=3'])
    run('slirp-compile', [meson, 'compile', '-C', slirp, '-j', '2'])
    run('slirp-install', [meson, 'install', '-C', slirp, '--no-rebuild'])
    if not (build / 'build.ninja').exists():
        run('configure', [source / 'configure', '--prefix=' + str(prefix), '--target-list=aarch64-softmmu',
            '--python=' + sys.executable, '--extra-cflags=-I' + str(COMMON / 'src/WebKit/Source/ThirdParty/ANGLE/include'),
            '--extra-ldflags=-L' + str(angle), '--disable-download', '--disable-rust', '--enable-hvf',
            '--disable-hvf-private', '--enable-fdt=internal', '--enable-vnc', '--enable-tpm', '--enable-slirp',
            '--enable-cocoa', '--enable-opengl', '--enable-virglrenderer', '--disable-docs', '--disable-gtk',
            '--disable-sdl', '--disable-pvg', '--disable-werror', '-Doptimization=3'], build)
    run('compile', [TOOLS / 'ninja', '-j', '2', 'qemu-system-aarch64-unsigned'], build)
    candidate = base / 'candidate/qemu-system-aarch64'
    candidate.parent.mkdir(exist_ok=True)
    shutil.copyfile(build / 'qemu-system-aarch64-unsigned', candidate); candidate.chmod(0o700)
    entitlement = source / 'accel/hvf/entitlements.plist'
    require(plistlib.loads(entitlement.read_bytes()) == {'com.apple.security.hypervisor': True}, 'Unexpected entitlements')
    run('sign', ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', '--entitlements', entitlement, candidate])
    run('verify-signature', ['/usr/bin/codesign', '--verify', '--strict', candidate])
    actual_entitlements = subprocess.check_output(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(candidate)], stderr=subprocess.DEVNULL)
    require(plistlib.loads(actual_entitlements) == {'com.apple.security.hypervisor': True}, 'Actual entitlements changed')
    require(capture(['/usr/bin/lipo', '-archs', candidate]) == 'arm64', 'Expected arm64')
    imports = capture(['/usr/bin/otool', '-L', candidate])
    require(str(renderer / 'prefix/lib/libvirglrenderer.1.dylib') in imports, 'Matching renderer not linked')
    run('version', [candidate, '--version'])
    verify()
    # QEMU configure may generate source-side version/package metadata. Verify
    # every prepared input individually; generated files are separate outputs.
    for name, expected in json.loads(prepared.read_text()).items():
        p = source / name
        require((os.readlink(p) if p.is_symlink() else sha(p)) == expected, 'Build changed prepared source: ' + name)
    save(base / 'build.json', {'plan': plan, 'source_inventory_sha256': sha(prepared),
        'candidate': str(candidate), 'candidate_sha256': sha(candidate), 'imports': imports,
        'compile_commands_sha256': sha(build / 'compile_commands.json'),
        'compiler': capture(['/usr/bin/xcrun', 'clang', '--version']),
        'sdk': capture(['/usr/bin/xcrun', '--show-sdk-path']), 'installed_app_unchanged': True,
        'Windows_tested': False, 'VM_started': False,
        'scope': 'Direct-source/ACK-retired-pool publisher; no STP or HID patch; no GPU diagnostic overlay'})
    print('Native publisher QEMU candidate built; no installation or VM launch.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('QEMU rebuild stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)
