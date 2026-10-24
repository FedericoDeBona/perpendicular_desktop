#!/usr/bin/env python3
"""Build an isolated IVSHMEM QEMU; never start a VM or replace an app/runtime."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('local_graphics', REPO / 'scripts/rebuild-local-graphics.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-root', required=True, type=Path)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    reference = args.tools_root.resolve() / 'graphics-rebuild-resize-qemu-20261019'
    runtime = args.runtime.resolve(strict=True)
    out = args.output.resolve()
    base.require(not out.exists(), 'Output must be new')
    base.require(not out.is_relative_to(runtime) and not runtime.is_relative_to(out), 'Output overlaps runtime')
    base.verify(reference, base.QEMU_PINS)
    base.verify(reference, base.OVERLAY_PINS)
    manifest = json.loads((runtime / 'runtime.json').read_text())
    base.verify(runtime, manifest['files'])
    base.require(manifest['files']['bin/qemu-system-aarch64'] ==
        '64a5e90ee941f32e270ee119347a2569dc444ba2e2c26af24c07d3eb5cfef07b', 'Different base QEMU')
    recipe = json.loads((reference / 'logs/link-1792361609049126000.log').read_text().splitlines()[0])
    original_root = recipe['cwd'].split('/.tools/', 1)[0]

    def relocate(arg):
        return arg.replace(original_root + '/.tools/', str(reference.parent) + '/')

    build = Path(relocate(recipe['cwd']))
    protected = json.loads((reference / 'protected.json').read_text())
    inputs = {}
    for arg in recipe['argv']:
        if not arg.startswith('-') and arg.endswith(('.o', '.a')):
            old = arg if arg.startswith('/') else recipe['cwd'] + '/' + arg
            path = Path(relocate(old))
            expected = protected.get(old)
            if expected is None and path.is_relative_to(reference):
                expected = base.OVERLAY_PINS.get(str(path.relative_to(reference)))
            base.require(expected and base.digest(path) == expected, 'Changed link input: ' + str(path))
            inputs[str(path)] = expected
    base.require(len(inputs) >= 1000, 'Incomplete link input inventory')
    out.mkdir(parents=True)
    logs = out / 'logs'
    logs.mkdir()

    def run(label, command, cwd=None):
        command = list(map(str, command))
        (logs / (label + '.command.json')).write_text(json.dumps({'argv': command, 'cwd': str(cwd)}, indent=2))
        result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (logs / (label + '.log')).write_bytes(result.stdout)
        base.require(result.returncode == 0, label + ': ' + result.stdout.decode(errors='replace')[-3000:])
        return result.stdout

    # Recreate the two monitor overlays already in the current QEMU.
    src = out / 'monitor-source'
    for name in ['ui/vnc.c', 'ui/vnc.h', 'include/ui/input.h', 'hw/display/virtio-gpu-base.c']:
        dst = src / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(reference / 'source/vm' / name, dst)
    shutil.copy2(reference / 'source/perp-flexible-monitor.h', src)
    shutil.copy2(REPO / 'graphics/monitor/primary-monitor.h', src)
    run('monitor-patch', ['patch', '-p1', '--batch', '-i', REPO / 'graphics/monitor/primary-monitor.patch'], src)
    replacements = {}
    templates = [('ui/vnc.c', 'compile-vm_ui_vnc.c-1792361601158706000.log'),
                 ('hw/display/virtio-gpu-base.c', 'compile-vm_hw_display_virtio-gpu-base.c-1792361606825325000.log')]
    for name, log in templates:
        record = json.loads((reference / 'logs' / log).read_text().splitlines()[0])
        command = [relocate(a) for a in record['argv']]
        command[1:1] = ['-I' + str(src), '-iquote', str(src / 'include'),
            '-ffile-prefix-map=' + str(src) + '=/Users/federico/Desktop/perpendicular_desktop/.build/local-graphics-admission/monitor-source']
        obj = out / (name.replace('/', '_') + '.o')
        for flag, value in [('-c', src / name), ('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)]:
            command[command.index(flag) + 1] = str(value)
        run('compile-' + obj.stem, command, build)
        matching = [a for a in recipe['argv'] if a.endswith('/vm/' + name + '.o')]
        base.require(len(matching) == 1, 'Overlay not unique')
        replacements[matching[0]] = str(obj)

    # Use the same QEMU compiler definitions/includes, adding only this unit.
    record = json.loads((reference / 'logs' / templates[0][1]).read_text().splitlines()[0])
    command = [relocate(a) for a in record['argv']]
    obj = out / 'ivshmem-host.o'
    source = Path(__file__).with_name('ivshmem-host.c')
    for flag, value in [('-c', source), ('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)]:
        command[command.index(flag) + 1] = str(value)
    run('compile-ivshmem', command, build)
    result = out / 'Native3D'
    shutil.copytree(runtime, result, symlinks=True)

    def packaged(arg):
        dep = Path(arg)
        if (result / 'lib' / dep.name).is_file():
            return str(result / 'lib' / dep.name)
        for value in subprocess.check_output(['otool', '-D', arg], text=True).splitlines()[1:]:
            if (result / 'lib' / Path(value.strip()).name).is_file():
                return str(result / 'lib' / Path(value.strip()).name)
        raise ValueError('Missing packaged dependency: ' + arg)

    command = []
    for arg in recipe['argv']:
        if arg.startswith('-Wl,-rpath,'):
            continue
        arg = replacements.get(arg, relocate(arg))
        if arg.startswith('/') and arg.endswith('.dylib'):
            arg = packaged(arg)
        command.append(arg)
    binary = result / 'bin/qemu-system-aarch64'
    command[command.index('-o') + 1] = str(binary)
    command += ['-Wl,-rpath,@executable_path/../lib']
    unchanged = list(command)
    unchanged[unchanged.index('-o') + 1] = str(out / 'baseline')
    run('link-baseline', unchanged, build)

    def code_hash(path):
        rows = subprocess.check_output(['otool', '-s', '__TEXT', '__text', str(path)]).splitlines()
        base.require(b'(__TEXT,__text)' in rows[1], 'Missing code section')
        return hashlib.sha256(b'\n'.join(rows[2:])).hexdigest()

    baseline_hash = code_hash(out / 'baseline')
    base.require(baseline_hash == code_hash(runtime / 'bin/qemu-system-aarch64'), 'Baseline code differs from current runtime')
    command.append(str(obj))
    run('link-ivshmem', command, build)
    run('sign', ['codesign', '--force', '--sign', '-', '--entitlements', REPO / 'macos/Hypervisor.entitlements', binary])
    run('signature', ['codesign', '--verify', '--strict', binary])
    run('version', [binary, '--version'])
    device_help = run('device', [binary, '-device', 'perp-ivshmem-plain,help'])
    base.require(b'host-notify' in device_help and b'memdev' in device_help, 'Missing experimental device')
    manifest['files']['bin/qemu-system-aarch64'] = base.digest(binary)
    manifest['ivshmem_host_experiment'] = 1
    (result / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (out / 'build.json').write_text(json.dumps({'base_qemu': '64a5e90ee941', 'baseline_text_sha256': baseline_hash,
        'link_inputs': inputs, 'source_sha256': base.digest(source), 'qemu_sha256': base.digest(binary),
        'VM_started': False, 'Windows_verified': False}, indent=2))
    print(binary)


if __name__ == '__main__':
    main()
