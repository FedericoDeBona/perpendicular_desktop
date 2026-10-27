#!/usr/bin/env python3
"""Add exact per-console app modes to the retained local QEMU build.

Requires the matching source/build and rebuilt object files. Produces a new app;
never replaces the reference, a running runtime, or any Windows state.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess

REPO = Path(__file__).resolve().parent.parent
SOURCE_SHA = '5f7405a341f830dbe58be6fbd9d9202c9a5fcca1edb1b472d4a777a743a55bda'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, *, cwd=None, log=None):
    result = subprocess.run(list(map(str, args)), cwd=cwd, capture_output=True, text=True)
    if log:
        log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError((result.stdout + result.stderr)[-3000:])
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--ninja', type=Path, required=True)
    parser.add_argument('--reference-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source, build, reference, out = map(Path.resolve, [args.source, args.build, args.reference_app, args.output])
    if out.exists() or out == reference or reference in out.parents:
        raise ValueError('A new, separate output directory is required')
    original = source / 'ui/console.c'
    if digest(original) != SOURCE_SHA:
        raise ValueError('Different console source; use an adapter for that actual runtime')
    config = (build / 'config-host.h').read_text()
    if not any(line.split()[:2] == ['#define', 'HAVE_VIRGL_RENDERER_NATIVE_SCANOUT'] for line in config.splitlines()):
        raise ValueError('Native scanout must be positively configured')
    run(['codesign', '--verify', '--deep', '--strict', reference])
    native = reference / 'Contents/Resources/Native3D'
    manifest = json.loads((native / 'runtime.json').read_text())
    if manifest.get('hvf_dynamic_memory_version') != 1 or manifest.get('mixed_display_identity_version') != 1:
        raise ValueError('The reference must retain dynamic RAM and mixed display identities')
    for name, expected in manifest['files'].items():
        if digest(native / name) != expected:
            raise ValueError('Reference runtime differs: ' + name)
    out.mkdir(parents=True)
    patched = out / 'source/ui/console.c'
    patched.parent.mkdir(parents=True)
    shutil.copy2(original, patched)
    run(['patch', '--batch', '--forward', '-p1', '-i', REPO / 'graphics/monitor/app-monitor-mode.patch'], cwd=out / 'source', log=out / 'patch.log')
    rows = json.loads((build / 'compile_commands.json').read_text())
    row = next(r for r in rows if Path(r['file']).resolve() == original or r['file'].endswith('/ui/console.c'))
    compile_args = shlex.split(row['command'])
    compile_args[compile_args.index(row['file'])] = str(patched)
    compile_args[1:1] = ['-I' + str(source / 'ui')]
    obj = out / 'console-app-mode.o'
    for flag, value in [('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)]:
        if flag in compile_args:
            compile_args[compile_args.index(flag) + 1] = str(value)
    run(compile_args, cwd=build, log=out / 'compile.log')
    commands = run([args.ninja, '-C', build, '-t', 'commands', 'qemu-system-aarch64-unsigned']).splitlines()
    link = shlex.split(commands[-1])
    if link.count('libcommon.a.p/ui_console.c.o') != 1 or any('ui_egl-headless.c.o' in x for x in link):
        raise ValueError('Different link profile or duplicate stock EGL backend')
    link[link.index('libcommon.a.p/ui_console.c.o')] = str(obj)
    executable = out / 'qemu-app-monitor'
    link[link.index('-o') + 1] = str(executable)
    # These are the paired, already packaged libraries. The historical build
    # paths were retired during cleanup; do not substitute new upstream ones.
    libs = native / 'lib'
    link = [str(libs / 'libepoxy.0.dylib') if x == '-lepoxy' else
            str(libs / 'libslirp.0.dylib') if x == '-lslirp' or x.endswith('/libslirp.dylib') else x for x in link]
    link += ['-framework', 'Metal', '-framework', 'Foundation']
    run(link, cwd=build, log=out / 'link.log')
    app = out / 'Perpendicular.app'
    run(['cp', '-cR', reference, app])
    runtime = app / 'Contents/Resources/Native3D'
    target = runtime / 'bin/qemu-system-aarch64'
    shutil.copy2(executable, target)
    for line in run(['otool', '-L', target]).splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith(('/System/', '/usr/lib/', '@executable_path/')):
            continue
        name = Path(dependency).name
        if (runtime / 'lib' / name).is_file():
            replacement = '@loader_path/../lib/' + name
        elif (app / 'Contents/Frameworks/Runtime/lib' / name).is_file():
            replacement = '@loader_path/../../../Frameworks/Runtime/lib/' + name
        else:
            raise ValueError('Unpackaged runtime dependency: ' + dependency)
        run(['install_name_tool', '-change', dependency, replacement, target])
    run(['codesign', '--force', '--sign', '-', '--entitlements', REPO / 'macos/Hypervisor.entitlements', target])
    manifest['files']['bin/qemu-system-aarch64'] = digest(target)
    manifest['app_monitor_mode_version'] = 1
    manifest['app_monitor_mode_patch_sha256'] = digest(REPO / 'graphics/monitor/app-monitor-mode.patch')
    (runtime / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run(['codesign', '--force', '--sign', '-', app])
    run(['codesign', '--verify', '--deep', '--strict', app])
    if digest(target) != manifest['files']['bin/qemu-system-aarch64']:
        raise ValueError('Final signing changed the native runtime')
    receipt = {'originalSource': SOURCE_SHA, 'patch': manifest['app_monitor_mode_patch_sha256'],
               'qemu': digest(target), 'reference': str(reference), 'output': str(app),
               'compile': compile_args, 'link': link}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(app)


if __name__ == '__main__':
    main()
