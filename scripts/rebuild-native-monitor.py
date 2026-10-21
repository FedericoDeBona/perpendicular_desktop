#!/usr/bin/env python3
"""Patch two matching QEMU units into a fresh private Native3D runtime.

Reads the reference only. Never starts a VM or changes an app, renderer, driver,
machine configuration or reference build. Outputs must remain under .build.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess

REPO = Path(__file__).resolve().parent.parent
PINS = {
    'build.json': '85ed0ac4fa83734896501513dbc2d00e4e443a6f0f50ffb9a9aa4b1ec0c4fc34',
    'protected.json': 'f9a0afbe711905221c82f287394337c6a1d36f10fc048788a7903e34767b76a7',
    'logs/link.log': '6977f21de2e5fa60fa5f14373e931f43fe49335ac80fe03fae50a56e566790ee',
    'qemu-system-aarch64': 'ed3d3563eb43a58e615e3c4669f0f138e6fea7877dbb9112f1f5e0babca9d883',
    'source/vm/ui/vnc.c': '811b165a552bcb1b2d957c1f22649818183b146fec393923570b03e671df6470',
    'source/vm/ui/vnc.h': 'bdb911e480a8b2129e90e4ed064078a0c9a3b9cd99e766cfca60c4616873e3a2',
    'source/vm/include/ui/input.h': '85a61a9722ba4ece4b5c4b08f7b2e0c9d139c1cda972e62090a3db1d3ec68096',
    'source/vm/hw/display/virtio-gpu-base.c': '25402b3268a4a1238caedaf588294e5648abeab4c996d93594f96aab429f932b',
    'source/perp-flexible-monitor.h': 'cfe73665d93fe85418651eea8c4e09280539bd085547fda6746dd4a038f9b80e',
}
COMMANDS_SHA = 'c3425f1ba771f9435e79ef909f9d6181681f5cce30d6baf99763b423cfa00f16'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_runtime(root, manifest):
    require((manifest.get('guest_wire_version'), manifest.get('host_transport_version'),
             manifest.get('native_descriptor_version')) == (1, 3, 2), 'Incompatible graphics protocols')
    require(manifest.get('source_receipt_sha256') == PINS['build.json'], 'Different QEMU source receipt')
    for name, expected in manifest['files'].items():
        relative = Path(name)
        require(not relative.is_absolute() and '..' not in relative.parts, 'Unsafe runtime member')
        path = root / relative
        require(not path.is_symlink() and path.is_file() and digest(path) == expected,
                'Runtime hash mismatch: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', required=True, type=Path)
    parser.add_argument('--qemu', required=True, type=Path, help='Matching graphics-rebuild-qemu profile')
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='New directory beneath this repo .build')
    args = parser.parse_args()
    reference = args.reference.resolve(strict=True)
    profile = args.qemu.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True)
    output = args.output.resolve()
    require(output.is_relative_to(REPO / '.build') and not output.exists(), 'Fresh private .build output required')
    require(reference.parent == profile.parent, 'Reference profiles must share their tool root')
    for name, expected in PINS.items():
        require(digest(reference / name) == expected, 'Reference input mismatch: ' + name)
    records_file = profile / 'build/compile_commands.json'
    require(digest(records_file) == COMMANDS_SHA, 'Different QEMU compiler recipes')
    records = json.loads(records_file.read_text())
    recipe = json.loads((reference / 'logs/link.log').read_text().splitlines()[0])
    protected = json.loads((reference / 'protected.json').read_text())
    original_root = recipe['cwd'].split('/.tools/', 1)[0]

    def relocate(text):
        return str(text).replace(original_root + '/.tools/', str(reference.parent) + '/')

    build = Path(relocate(recipe['cwd']))
    require(build == profile / 'build', 'Link/compile profile mismatch')
    link_input_hashes = {}
    for argument in recipe['argv']:
        if not argument.startswith('-') and argument.endswith(('.o', '.a')):
            original = argument if argument.startswith('/') else recipe['cwd'] + '/' + argument
            expected = protected.get(original)
            actual = Path(relocate(original))
            require(expected is not None and digest(actual) == expected, 'Link input mismatch: ' + str(actual))
            link_input_hashes[original] = expected
    require(len(link_input_hashes) >= 1000, 'Incomplete pinned link input inventory')
    manifest = json.loads((runtime / 'runtime.json').read_text())
    verify_runtime(runtime, manifest)

    output.mkdir(parents=True)
    logs = output / 'logs'
    logs.mkdir()

    def run(label, arguments, cwd=None):
        command = list(map(str, arguments))
        (logs / (label + '.command.json')).write_text(json.dumps({'argv': command, 'cwd': str(cwd) if cwd else None}, indent=2) + '\n')
        result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (logs / (label + '.log')).write_bytes(result.stdout)
        if result.returncode:
            raise RuntimeError(label + ' failed: ' + result.stdout.decode(errors='replace')[-2500:])
        return result.stdout

    result = output / 'Native3D'
    shutil.copytree(runtime, result, symlinks=True)
    source = output / 'source'
    for name in ('ui/vnc.c', 'ui/vnc.h', 'include/ui/input.h', 'hw/display/virtio-gpu-base.c'):
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(reference / 'source/vm' / name, target)
    shutil.copy2(reference / 'source/perp-flexible-monitor.h', source)
    header = REPO / 'graphics/monitor/primary-monitor.h'
    patch = REPO / 'graphics/monitor/primary-monitor.patch'
    shutil.copy2(header, source)
    run('apply-monitor-patch', ['patch', '-p1', '--batch', '--forward', '-i', patch], source)

    # One small check of the exact compiled metadata header, without QEMU/VM.
    check = output / 'check-monitor.c'
    check.write_text('''#include <assert.h>
#include <stdio.h>
#include "primary-monitor.h"
int main(void) {
    assert(setenv("PERP_PRIMARY_MONITOR_WIDTH_MM", "310", 1) == 0);
    assert(setenv("PERP_PRIMARY_MONITOR_HEIGHT_MM", "200", 1) == 0);
    assert(setenv("PERP_PRIMARY_MONITOR_ID", "01234567-89ab-cdef-0123-456789abcdef", 1) == 0);
    PerpPrimaryMonitor first, again;
    assert(perp_primary_monitor_read(&first));
    uint16_t width=0, height=0;
    perp_primary_monitor_seed_size(&width, &height);
    assert(width == 310 && height == 200);
    width=400; height=300;
    perp_primary_monitor_seed_size(&width, &height);
    assert(width == 400 && height == 300);
    assert(setenv("PERP_PRIMARY_MONITOR_ID", "01234567-89AB-CDEF-0123-456789ABCDEF", 1) == 0);
    assert(perp_primary_monitor_read(&again) && first.serial == again.serial);
    uint8_t edid[128]={0}; edid[75]=0xf7; edid[93]=0xfd;
    perp_primary_monitor_edid_serial(edid, sizeof(edid), first.serial);
    unsigned sum=0; for (unsigned i=0;i<128;i++) sum+=edid[i];
    assert((sum & 255) == 0 && edid[75] == 0xf7 && edid[93] == 0xfd);
    assert(setenv("PERP_PRIMARY_MONITOR_WIDTH_MM", "-1", 1) == 0);
    assert(!perp_primary_monitor_read(&again));
    puts("monitor metadata: physical seed, preserved size, stable serial, EDID checksum and invalid-input rejection passed");
    return 0;
}
''')
    run('compile-monitor-check', ['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-I' + str(source), check, '-o', output / 'check-monitor'])
    run('check-monitor', [output / 'check-monitor'])

    replacements = {}
    for name in ('ui/vnc.c', 'hw/display/virtio-gpu-base.c'):
        record = next(r for r in records if r['file'].endswith('/' + name))
        command = [relocate(a) for a in shlex.split(record['command'])]
        obj = output / (name.replace('/', '_') + '.o')
        command[1:1] = ['-I' + str(source), '-iquote', str(source / 'include'),
                        '-iquote', str(profile / 'src/qemu' / Path(name).parent)]
        for option, value in (('-c', source / name), ('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)):
            command[command.index(option) + 1] = str(value)
        run('compile-' + name.replace('/', '_'), command, build)
        matching = [a for a in recipe['argv'] if a.endswith('/vm/' + name + '.o')]
        require(len(matching) == 1, 'Expected one overlaid QEMU object for ' + name)
        replacements[matching[0]] = str(obj)

    binary = result / 'bin/qemu-system-aarch64'
    command = []
    for argument in recipe['argv']:
        if argument.startswith('-Wl,-rpath,'):
            continue
        if argument in replacements:
            command.append(replacements[argument])
            continue
        relocated = relocate(argument)
        if relocated.startswith('/') and relocated.endswith('.dylib'):
            dependency = Path(relocated)
            packaged = result / 'lib' / dependency.resolve(strict=True).name
            if not packaged.is_file():
                # A dylib's real filename may include a patch version while
                # packaging intentionally uses its ABI install-name basename.
                identifiers = subprocess.check_output(['otool', '-D', str(dependency)], text=True).splitlines()[1:]
                choices = [result / 'lib' / Path(value.strip()).name for value in identifiers]
                packaged = next((path for path in choices if path.is_file()), packaged)
            require(packaged.is_file(), 'Missing corresponding packaged library: ' + relocated)
            relocated = str(packaged)
        command.append(relocated)
    command[command.index('-o') + 1] = str(binary)
    command.append('-Wl,-rpath,@executable_path/../lib')
    run('link-qemu', command, build)

    imports = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    changes = []
    for line in imports:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith(('/System/', '/usr/lib/', '@')):
            continue
        member = result / 'lib' / Path(dependency).name
        require(member.is_file(), 'Unpackaged dependency: ' + dependency)
        changes += ['-change', dependency, '@executable_path/../lib/' + member.name]
    if changes:
        run('relocate-qemu-libraries', ['install_name_tool', *changes, binary])
    signed = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(runtime / 'bin/qemu-system-aarch64')], capture_output=True, check=True)
    entitlements = plistlib.loads(signed.stdout)
    require(entitlements.get('com.apple.security.hypervisor') is True, 'Missing source Hypervisor entitlement')
    entitlement_file = output / 'Hypervisor.entitlements'
    entitlement_file.write_bytes(plistlib.dumps(entitlements))
    run('sign-qemu', ['codesign', '--force', '--sign', '-', '--timestamp=none', '--identifier',
                      'com.perpendicular.runtime.qemu.primary-monitor', '--entitlements', entitlement_file, binary])
    run('verify-qemu-signature', ['codesign', '--verify', '--strict', binary])
    version = run('qemu-version', [binary, '--version']).decode().strip()
    require('QEMU emulator version 10.0.12' in version, 'Unexpected QEMU version')

    manifest['files']['bin/qemu-system-aarch64'] = digest(binary)
    manifest['primary_monitor_metadata'] = 1
    notice = result / 'Notices/Perpendicular'
    require(notice.resolve().is_relative_to(result), 'Notices must remain inside the output runtime')
    notice.mkdir(parents=True, exist_ok=True)
    for file in (header, patch):
        shutil.copy2(file, notice / file.name)
    receipt = {
        'base_source_receipt_sha256': PINS['build.json'],
        'base_runtime_manifest_sha256': digest(runtime / 'runtime.json'),
        'base_qemu_sha256': json.loads((runtime / 'runtime.json').read_text())['files']['bin/qemu-system-aarch64'],
        'qemu_sha256': manifest['files']['bin/qemu-system-aarch64'],
        'reference_inputs': PINS, 'compiler_recipes_sha256': COMMANDS_SHA,
        'link_inputs_verified': len(link_input_hashes),
        'link_inputs_digest': hashlib.sha256(json.dumps(link_input_hashes, sort_keys=True).encode()).hexdigest(),
        'patch_sha256': digest(patch), 'header_sha256': digest(header),
        'compiled_units': ['ui/vnc.c', 'hw/display/virtio-gpu-base.c'],
        'primary_monitor_metadata': 1, 'guest_wire_version': 1, 'host_transport_version': 3,
        'renderer_control_version': manifest.get('renderer_control_version', 1),
        'checks': ['metadata header', 'QEMU version', 'signature', 'runtime hashes'],
        'VM_started': False, 'runtime_verified': False,
    }
    receipt_path = notice / 'primary-monitor.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    manifest['primary_monitor_receipt_sha256'] = digest(receipt_path)
    (result / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    verify_runtime(result, manifest)
    for name, expected in PINS.items():
        require(digest(reference / name) == expected, 'Reference changed during the build: ' + name)
    print('Prepared:', result)
    print(version.splitlines()[0])
    print('Two QEMU units rebuilt; renderer/server unchanged. No app or VM changed.')


if __name__ == '__main__':
    main()
