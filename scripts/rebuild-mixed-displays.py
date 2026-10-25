#!/usr/bin/env python3
"""Build the opt-in PCI identity needed by the original signed 3D/DOD pair.

Reuses the qualified local QEMU objects. Writes a new app, never the reference,
source or object tree. Does not modify any Windows driver or security setting.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

REPO = Path(__file__).resolve().parents[1]
SOURCE_SHA = 'a48017c8fc346e106c51dc77bd033194e63babc65660bc8ec5198c6f4d7cf267'
PATCHED_SHA = '3310d1ef9a0e59c108b5aa914d3f82b1eea82e48c516de29b4955e261f98e578'
REFERENCE_QEMU_SHA = 'bc411d2f1acac34f8c8e73794da5eda0a8983c3265bec3464a372aa48e00c2db'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(argv, **kwargs):
    return subprocess.run([str(a) for a in argv], check=True, **kwargs)


def dependencies(binary):
    lines = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    return [(line.strip().split(' (', 1)[0], line.split('compatibility version ', 1)[1].split(',', 1)[0]) for line in lines]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--commands', type=Path, required=True, help='Saved ninja -t commands from that build')
    parser.add_argument('--from-app', type=Path, required=True)
    parser.add_argument('--to-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New directory for objects, logs and receipt')
    args = parser.parse_args()
    source, build, reference = (p.resolve(strict=True) for p in (args.source, args.build, args.from_app))
    app, out = args.to_app.resolve(), args.output.resolve()
    if app.exists() or out.exists():
        raise ValueError('App and output must both be new paths')
    if app.is_relative_to(out) or out.is_relative_to(app):
        raise ValueError('App and build outputs must be separate directories')
    if any(p.is_relative_to(root) or root.is_relative_to(p) for p in (app, out) for root in (source, build, reference)):
        raise ValueError('Outputs must be separate from the reference and build trees')
    original = source / 'hw/display/virtio-ramfb.c'
    native = reference / 'Contents/Resources/Native3D'
    reference_qemu = native / 'bin/qemu-system-aarch64'
    if sha(original) != SOURCE_SHA or sha(reference_qemu) != REFERENCE_QEMU_SHA:
        raise ValueError('This patch requires the qualified memory-runtime source and reference')
    run(['codesign', '--verify', '--deep', '--strict', reference])
    manifest = json.loads((native / 'runtime.json').read_text())
    for name, expected in manifest['files'].items():
        file = native / name
        if not file.resolve().is_relative_to(native) or sha(file) != expected:
            raise ValueError('Reference runtime differs: ' + name)
    out.mkdir(parents=True, mode=0o700)
    # Apply to a private tree. Even a failed patch cannot change the source.
    patched = out / 'hw/display/virtio-ramfb.c'
    patched.parent.mkdir(parents=True)
    patched.write_bytes(original.read_bytes())
    patch = REPO / 'graphics/monitor/mixed-display-identity.patch'
    run(['patch', '--batch', '-p1', '-i', patch], cwd=out, capture_output=True)
    if sha(patched) != PATCHED_SHA:
        raise ValueError('Patched source differs from the verified experiment')
    commands = args.commands.read_text().splitlines()
    compile_commands = [x for x in commands if 'virtio-ramfb.c.o' in x and ' -c ' in x]
    link_commands = [x for x in commands if ' -o qemu-system-aarch64-unsigned ' in x]
    if len(compile_commands) != 1 or len(link_commands) != 1:
        raise ValueError('Expected one qualified compile and link recipe')
    compile_argv = shlex.split(compile_commands[0]) + ['-iquote', str(original.parent)]
    obj = out / 'virtio-ramfb.o'
    for flag, value in [('-o', str(obj)), ('-MF', str(obj) + '.d'), ('-MQ', str(obj)), ('-c', str(patched))]:
        compile_argv[compile_argv.index(flag) + 1] = value
    link_argv = shlex.split(link_commands[0])
    unit = 'libcommon.a.p/hw_display_virtio-ramfb.c.o'
    if link_argv.count(unit) != 1:
        raise ValueError('Missing original ramfb unit in link recipe')
    link_argv[link_argv.index(unit)] = str(obj)
    binary = out / 'qemu-system-aarch64-unsigned'
    link_argv[link_argv.index('-o') + 1] = str(binary)
    for name, argv in [('compile', compile_argv), ('link', link_argv)]:
        (out / (name + '.json')).write_text(json.dumps({'cwd': str(build), 'argv': argv}, indent=2) + '\n')
        with (out / (name + '.log')).open('wb') as log:
            run(argv, cwd=build, stdout=log, stderr=subprocess.STDOUT)
    run(['cp', '-cR', reference, app])
    target_native = app / 'Contents/Resources/Native3D'
    target = target_native / 'bin/qemu-system-aarch64'
    target.write_bytes(binary.read_bytes())
    qualified = dependencies(reference_qemu)
    for old, version in dependencies(target):
        if old.startswith(('/System/', '/usr/lib/')):
            continue
        matches = [(dep, compat) for dep, compat in qualified if Path(dep).name.split('.')[0] == Path(old).name.split('.')[0]]
        if len(matches) != 1 or matches[0][1] != version:
            raise ValueError('Ambiguous or incompatible dependency: ' + old)
        new = matches[0][0]
        resolved = (target.parent / new.replace('@loader_path/', '')).resolve(strict=True)
        if not resolved.is_relative_to(app):
            raise ValueError('Dependency escapes app: ' + new)
        run(['install_name_tool', '-change', old, new, target], capture_output=True)
    run(['codesign', '--force', '--sign', '-', '--entitlements', source / 'accel/hvf/entitlements.plist', target], capture_output=True)
    manifest['files']['bin/qemu-system-aarch64'] = sha(target)
    manifest['mixed_display_identity_version'] = 1
    (target_native / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run(['codesign', '--force', '--deep', '--sign', '-', '--entitlements', REPO / 'macos/Hypervisor.entitlements', app], capture_output=True)
    run(['codesign', '--verify', '--deep', '--strict', app])
    if sha(target) != manifest['files']['bin/qemu-system-aarch64']:
        raise ValueError('Final signature changed the runtime hash')
    receipt = {'sourceSHA256': sha(original), 'patchSHA256': sha(patch), 'patchedSourceSHA256': sha(patched),
               'referenceQemuSHA256': sha(reference_qemu), 'qemuSHA256': sha(target),
               'referenceApp': str(reference), 'outputApp': str(app), 'mixed_display_identity_version': 1}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
