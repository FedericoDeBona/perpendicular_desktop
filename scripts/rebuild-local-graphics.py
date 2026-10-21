#!/usr/bin/env python3
"""Rebuild monitor metadata and context retirement for the installed resize base.

This is a separately pinned adapter for the October 19 local graphics build.
The other rebuild scripts retain their original pins. Only seven C units are
rebuilt into a new private output; no VM, installed app or reference is changed.
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
QEMU_PINS = {
    'build.json': '058581d6d9d39f12aa39cda694123aa8ab81d9b085ddf1d5476b4bbeda99bffd',
    'protected.json': '4019365ff1b28e860b640055f85210d50a8b45c96c65951ef3a0f6a9697227b6',
    'qemu-system-aarch64': 'ce9212ab70082c6a1607f05f14cfcc6ecb461e65bfb3a8dcba366e6b7f7d410c',
    'logs/link-1792361609049126000.log': '2b565051989b19545607056fa1b2749168b9d714078e3880d8d12eed3b12d78b',
    'logs/compile-vm_ui_vnc.c-1792361601158706000.log': '7d5b594ec4ed865f9e38d9d76b524a19c2e7e9f16f7591183d92ea7e26e06c7a',
    'logs/compile-vm_hw_display_virtio-gpu-base.c-1792361606825325000.log': 'c7ff05a802947e07815b8b998861f611adfe29745e7dc1f640be263e77edf95f',
    'source/vm/ui/vnc.c': '811b165a552bcb1b2d957c1f22649818183b146fec393923570b03e671df6470',
    'source/vm/ui/vnc.h': 'bdb911e480a8b2129e90e4ed064078a0c9a3b9cd99e766cfca60c4616873e3a2',
    'source/vm/include/ui/input.h': '85a61a9722ba4ece4b5c4b08f7b2e0c9d139c1cda972e62090a3db1d3ec68096',
    'source/vm/hw/display/virtio-gpu-base.c': '25402b3268a4a1238caedaf588294e5648abeab4c996d93594f96aab429f932b',
    'source/perp-flexible-monitor.h': 'cfe73665d93fe85418651eea8c4e09280539bd085547fda6746dd4a038f9b80e',
}
RENDERER_PINS = {
    'build.json': 'd7b924fc102bdb4ff43b20a328008ef0df12d8eff7f5dfc0794a2e7213d55d0f',
    'source-files.json': '815617f2f315dadb140e156be56bd85e635f9e0241a1ccc4c685799b54815b62',
    'build/compile_commands.json': 'c9be65fa34992de1d4a54d173f88f052cf64d8b729f02bff722b2dda97a6883e',
    'prefix/lib/libvirglrenderer.1.dylib': '415b6f0bc2615ec8beb6c4a263b807a8ba6f8d39a8308228c3c966c71a51ed00',
    'prefix/libexec/virgl_render_server': '1a4874be322485a61690d098182a81f282ea7741d820b4170f4d817d6ff5c9cf',
    'build/src/libvirgl.a': 'c3eefbd651936203d782d10dd92cd484b1c7a5fd7dece6ab576609f1ee24ff15',
}
RUNTIME_MANIFEST_SHA = 'ef582cb66e9ed495cfcf73188a5db190a7a4b2e88d07572115195d84d946d213'
# The old protected inventory predates these build outputs. Pin them explicitly
# and confirm their unchanged relink against the retained original candidate.
OVERLAY_PINS = {
    'backend.m.o': '733b56815e341d2575dc5e8714b88f5f91d0a487951dab500f4d7d914d240395',
    'qemu-native-sync.m.o': '2b3ca296da897f80eb0fba930d8c6d0b8643f524b4901f09f118e571813a2c0d',
    'vm/ui/input.c.o': '5321c78b09359e2a6f0e9d4e359a2c0f4d0915764221371c1b117a4c28017e41',
    'vm/ui/vnc.c.o': 'aea65caf8097ca8d05504aae9f8c3ad6c6ee36c1d023cc3764c7587ac338e1f4',
    'vm/ui/vnc-enc-zlib.c.o': 'b907f04b4bd0b96454f1a6dd200337951f04e378dfad2c632ff749f82d805277',
    'vm/ui/vnc-enc-hextile.c.o': '266e504e276eb3c9751db36c305bec5e75ca78b2dc38dcef474eaa505d099819',
    'vm/ui/vnc-enc-tight.c.o': '99dc54b5ba768e9049efd030ec124c9e368b110b114c2c1a79602409c761d492',
    'vm/ui/vnc-palette.c.o': '74b5bbbe1bec60ee78fa0f88ea6eba7350c08ec7b5358c84caff8428d5b8d267',
    'vm/ui/vnc-enc-zrle.c.o': 'e7e93921c32e9442c66beb8eaa8f37c8dc1b698b55daefef4df94ae50d61a6d1',
    'vm/ui/vnc-auth-vencrypt.c.o': '55a0e069c984cdd187f538c037eb2ad8833e5c09e610b9488148d28ba943587e',
    'vm/ui/vnc-ws.c.o': '96c66aedf80a3d44334e5e8ec5fee151fd4002a1d26f6b77b43baebc5d06a39d',
    'vm/ui/vnc-jobs.c.o': '4b5a606520f6dc7a68c7aecc889d92f200a53e066f07122f6cfb3328c3472e57',
    'vm/ui/vnc-clipboard.c.o': '6244ea511aa64a77efa9b95955dfcec5ac1d947888877d3758e22551d7f9be0e',
    'vm/ui/vnc-auth-sasl.c.o': 'f4b621aebf791beebd4681bb1cd9e7b94c812a3d5a745375a98e23021fa1a463',
    'vm/hw/input/hid.c.o': 'e25aa5bbeaaf3160c9a5f33220e540781b73fca7ef8b4a32d74c7ea75b5877b8',
    'vm/hw/display/virtio-gpu-base.c.o': 'ba524b6289dadf19e0fa09f9ff7a7961ef78a29f68fa1f22032a98a950ed99fa',
    'virtio-gpu-gl.c.o': 'fd2ab8ee9ba1a94d3b817b88fa1ea3b818137195fd81ad3731ad2aee2fca500e',
    'virtio-gpu-virgl.c.o': '5bda7e4f0caeba4cab6deb35d692d148cf6bff434fcb363bb1f7c10169ecf190',
    'vm/target/arm/hvf/hvf.c.o': '8bfad6d44fa56cbec55c1eab7656cad9745f44b51c07cc5ce07f109b92362a0b',
    'libperp-native-publisher.a': 'a86461dff7e20104398eb2543ca1aa2737471ab8d200016eef3ce89f642abed7',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def verify(root, pins):
    for name, expected in pins.items():
        path = root / name
        require(not path.is_symlink() and path.is_file() and digest(path) == expected,
                'Pinned input mismatch: ' + str(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu-reference', type=Path, required=True)
    parser.add_argument('--renderer-reference', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True, help='Prepared copy of the exact installed Native3D runtime')
    parser.add_argument('--output', type=Path, required=True, help='New directory under this project .build')
    args = parser.parse_args()
    reference = args.qemu_reference.resolve(strict=True)
    renderer = args.renderer_reference.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True)
    output = args.output.resolve()
    require(output.is_relative_to(REPO / '.build') and not output.exists(), 'Fresh private .build output required.')
    require(reference.parent == renderer.parent, 'Both references must belong to the same tool root.')
    verify(reference, QEMU_PINS)
    verify(reference, OVERLAY_PINS)
    verify(renderer, RENDERER_PINS)
    require(digest(runtime / 'runtime.json') == RUNTIME_MANIFEST_SHA, 'Different installed runtime manifest.')
    manifest = json.loads((runtime / 'runtime.json').read_text())
    # Bind this adapter to the packaged base, not merely compatible version numbers.
    require(manifest.get('source_receipt_sha256') == QEMU_PINS['build.json'], 'Different packaged QEMU base.')
    require((manifest.get('guest_wire_version'), manifest.get('host_transport_version'),
             manifest.get('native_descriptor_version')) == (1, 3, 2), 'Incompatible graphics protocols.')
    verify(runtime, manifest['files'])
    provenance = json.loads((runtime / 'Notices/provenance.json').read_text())
    for name, key in [('bin/qemu-system-aarch64', 'qemu-system-aarch64'),
                      ('bin/virgl_render_server', 'prefix/libexec/virgl_render_server'),
                      ('lib/libvirglrenderer.1.dylib', 'prefix/lib/libvirglrenderer.1.dylib')]:
        pins = QEMU_PINS if key == 'qemu-system-aarch64' else RENDERER_PINS
        require(provenance['origins'][name]['sha256'] == pins[key], 'Different runtime origin: ' + name)

    link_file = reference / 'logs/link-1792361609049126000.log'
    recipe = json.loads(link_file.read_text().splitlines()[0])
    original_root = recipe['cwd'].split('/.tools/', 1)[0]

    def relocate(value):
        return str(value).replace(original_root + '/.tools/', str(reference.parent) + '/')

    build = Path(relocate(recipe['cwd']))
    require(build.is_dir(), 'Matching QEMU object directory is missing.')
    protected = json.loads((reference / 'protected.json').read_text())
    link_inputs = {}
    for argument in recipe['argv']:
        if not argument.startswith('-') and argument.endswith(('.o', '.a')):
            original = argument if argument.startswith('/') else recipe['cwd'] + '/' + argument
            actual = Path(relocate(original))
            expected = protected.get(original)
            if expected is None and actual.is_relative_to(reference):
                expected = OVERLAY_PINS.get(str(actual.relative_to(reference)))
            require(expected is not None and digest(actual) == expected, 'Changed link input: ' + str(actual))
            link_inputs[original] = expected
    require(len(link_inputs) >= 1000, 'Incomplete QEMU object inventory.')
    source = renderer / 'src/virglrenderer'
    source_inventory = json.loads((renderer / 'source-files.json').read_text())
    verify(source, source_inventory)
    output.mkdir(parents=True)
    logs = output / 'logs'
    logs.mkdir()

    def run(label, argv, cwd=None):
        command = list(map(str, argv))
        (logs / (label + '.command.json')).write_text(json.dumps({'argv': command, 'cwd': str(cwd) if cwd else None}, indent=2) + '\n')
        result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (logs / (label + '.log')).write_bytes(result.stdout)
        require(result.returncode == 0, label + ' failed: ' + result.stdout.decode(errors='replace')[-2000:])
        return result.stdout

    baseline = output / 'qemu-baseline'
    # Preserve the original embedded rpaths for this non-executed comparison.
    # Relocating them changes load-command sizes and consequently code addresses.
    unchanged = [a if a.startswith('-Wl,-rpath,') else relocate(a) for a in recipe['argv']]
    unchanged[unchanged.index('-o') + 1] = str(baseline)
    run('link-unchanged-qemu', unchanged, build)
    def text_signature(path):
        lines = subprocess.check_output(['otool', '-s', '__TEXT', '__text', str(path)]).splitlines()
        require(len(lines) > 2 and b'(__TEXT,__text)' in lines[1], 'Cannot compare original QEMU code section.')
        return hashlib.sha256(b'\n'.join(lines[2:])).hexdigest()
    baseline_signature = text_signature(baseline)
    require(baseline_signature == text_signature(reference / 'qemu-system-aarch64'),
            'Unchanged relink differs from the original QEMU code section.')

    result = output / 'Native3D'
    shutil.copytree(runtime, result, symlinks=True)
    monitor_source = output / 'monitor-source'
    for name in ['ui/vnc.c', 'ui/vnc.h', 'include/ui/input.h', 'hw/display/virtio-gpu-base.c']:
        target = monitor_source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(reference / 'source/vm' / name, target)
    shutil.copy2(reference / 'source/perp-flexible-monitor.h', monitor_source)
    header = REPO / 'graphics/monitor/primary-monitor.h'
    monitor_patch = REPO / 'graphics/monitor/primary-monitor.patch'
    shutil.copy2(header, monitor_source)
    run('monitor-patch', ['patch', '-p1', '--batch', '--forward', '-i', monitor_patch], monitor_source)
    replacements = {}
    units = [('ui/vnc.c', 'compile-vm_ui_vnc.c-1792361601158706000.log'),
             ('hw/display/virtio-gpu-base.c', 'compile-vm_hw_display_virtio-gpu-base.c-1792361606825325000.log')]
    for name, log_name in units:
        record = json.loads((reference / 'logs' / log_name).read_text().splitlines()[0])
        command = [relocate(a) for a in record['argv']]
        command[1:1] = ['-I' + str(monitor_source), '-iquote', str(monitor_source / 'include')]
        obj = output / (name.replace('/', '_') + '.o')
        for flag, value in [('-c', monitor_source / name), ('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)]:
            command[command.index(flag) + 1] = str(value)
        run('compile-' + name.replace('/', '_'), command, build)
        matching = [a for a in recipe['argv'] if a.endswith('/vm/' + name + '.o')]
        require(len(matching) == 1, 'Cannot identify overlaid QEMU unit: ' + name)
        replacements[matching[0]] = str(obj)

    def packaged_library(dependency):
        direct = result / 'lib' / dependency.name
        if direct.is_file():
            return direct
        identifiers = subprocess.check_output(['otool', '-D', str(dependency)], text=True).splitlines()[1:]
        choices = [result / 'lib' / Path(value.strip()).name for value in identifiers]
        candidate = next((p for p in choices if p.is_file()), None)
        require(candidate is not None, 'Missing packaged dependency: ' + str(dependency))
        return candidate

    qemu_binary = result / 'bin/qemu-system-aarch64'
    command = []
    for argument in recipe['argv']:
        if argument.startswith('-Wl,-rpath,'):
            continue
        argument = replacements.get(argument, relocate(argument))
        if argument.startswith('/') and argument.endswith('.dylib'):
            argument = str(packaged_library(Path(argument)))
        command.append(argument)
    command[command.index('-o') + 1] = str(qemu_binary)
    command.append('-Wl,-rpath,@executable_path/../lib')
    run('link-qemu', command, build)

    private = output / 'renderer-source'
    names = ['src/proxy/proxy_context.c', 'src/proxy/proxy_client.c',
             'server/render_client.c', 'server/render_worker.c', 'server/render_worker.h',
             *['src/perp-sync/' + name for name in ('proxy-broker.c', 'live.h', 'broker.h',
                'wire.h', 'wire1-layout.h', 'snapshot-storage.h')]]
    for name in names:
        target = private / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(relocate((source / name).read_text()))
    retirement_patch = REPO / 'graphics/renderer/context-retirement.patch'
    run('retirement-patch', ['patch', '-p1', '--batch', '--forward', '-i', retirement_patch], private)
    admission_patch = REPO / 'graphics/renderer/context-admission.patch'
    run('admission-patch', ['patch', '-p1', '--batch', '--forward', '-i', admission_patch], private)
    records = json.loads((renderer / 'build/compile_commands.json').read_text())
    changed = ['src/perp-sync/proxy-broker.c', 'src/proxy/proxy_context.c', 'src/proxy/proxy_client.c',
               'server/render_client.c', 'server/render_worker.c']
    objects = {}
    for name in changed:
        record = next(r for r in records if r['file'].endswith('/' + name))
        command = [relocate(a) for a in shlex.split(record['command'])]
        obj = output / Path(record['output']).name
        command[1:1] = ['-I' + str(private / 'src/perp-sync'), '-I' + str(private / 'server'), '-I' + str(private / 'src/proxy')]
        for flag, value in [('-c', private / name), ('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)]:
            command[command.index(flag) + 1] = str(value)
        run('compile-' + name.replace('/', '_'), command, renderer / 'build')
        objects[record['output']] = obj
        if name == 'src/perp-sync/proxy-broker.c':
            admission_command = command.copy()
    archive = output / 'libvirgl.a'
    shutil.copy2(renderer / 'build/src/libvirgl.a', archive)
    run('archive-renderer', ['ar', '-r', archive, *[v for k, v in objects.items() if k.startswith('src/')]])
    ninja = shutil.which('ninja') or str(reference.parent / 'build-venv/bin/ninja')

    def link_renderer(target, destination, overrides):
        lines = subprocess.check_output([ninja, '-C', str(renderer / 'build'), '-t', 'commands', target], text=True)
        command = [relocate(a) for a in shlex.split(lines.splitlines()[-1])]
        command = [str(overrides.get(a, a)) for a in command]
        command[command.index('-o') + 1] = str(destination)
        run('link-' + target.replace('/', '_'), command, renderer / 'build')

    library = output / 'libvirglrenderer.1.dylib'
    server = output / 'virgl_render_server'
    link_renderer('src/libvirglrenderer.1.dylib', library, {'src/libvirgl.a': archive})
    link_renderer('server/virgl_render_server', server,
                  {**objects, 'src/libvirgl.a': archive, 'src/libvirglrenderer.1.dylib': library})
    shutil.copy2(library, result / 'lib/libvirglrenderer.1.dylib')
    shutil.copy2(server, result / 'bin/virgl_render_server')
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(runtime / 'bin/qemu-system-aarch64')],
                                 capture_output=True, check=True).stdout
    require(plistlib.loads(entitlements).get('com.apple.security.hypervisor') is True, 'Missing source Hypervisor entitlement.')
    entitlement_file = output / 'Hypervisor.entitlements'
    entitlement_file.write_bytes(entitlements)
    for name in ['bin/qemu-system-aarch64', 'lib/libvirglrenderer.1.dylib', 'bin/virgl_render_server']:
        binary = result / name
        imports = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
        changes = []
        for line in imports:
            dependency = line.strip().split(' (', 1)[0]
            if not dependency.startswith(('/System/', '/usr/lib/', '@')):
                member = packaged_library(Path(dependency))
                prefix = '@loader_path/../lib/' if name.startswith('bin/') else '@loader_path/'
                changes += ['-change', dependency, prefix + member.name]
        if name.startswith('lib/'):
            changes += ['-id', '@rpath/' + binary.name]
        if changes:
            run('relocate-' + binary.name, ['install_name_tool', *changes, binary])
        signing = ['codesign', '--force', '--sign', '-', '--timestamp=none']
        if name == 'bin/qemu-system-aarch64':
            signing += ['--entitlements', entitlement_file]
        run('sign-' + binary.name, [*signing, binary])
        run('verify-' + binary.name, ['codesign', '--verify', '--strict', binary])
        manifest['files'][name] = digest(binary)
    version = run('qemu-version', [qemu_binary, '--version']).decode()
    require('QEMU emulator version 10.0.12' in version, 'Unexpected QEMU version.')
    # One exact header check covers monitor metadata, without starting Windows.
    check = output / 'check-monitor.c'
    check.write_text('#include <assert.h>\n#include "primary-monitor.h"\nint main(void){\n'
                     'setenv("PERP_PRIMARY_MONITOR_WIDTH_MM","291",1);\n'
                     'setenv("PERP_PRIMARY_MONITOR_HEIGHT_MM","189",1);\n'
                     'setenv("PERP_PRIMARY_MONITOR_ID","01234567-89ab-cdef-0123-456789abcdef",1);\n'
                     'PerpPrimaryMonitor m; assert(perp_primary_monitor_read(&m));\n'
                     'assert(m.width_mm==291 && m.height_mm==189);\n'
                     'uint8_t edid[128]={0};perp_primary_monitor_edid_serial(edid,128,m.serial);\n'
                     'unsigned n=0;for(unsigned i=0;i<128;i++)n+=edid[i];assert(!(n&255));return 0;}\n')
    run('compile-monitor-check', ['cc', '-std=gnu11', '-I' + str(monitor_source), check, '-o', output / 'check-monitor'])
    run('monitor-check', [output / 'check-monitor'])
    run('compile-retirement-check', ['cc', '-std=gnu11', '-I' + str(private / 'src/perp-sync'),
                                    REPO / 'graphics/renderer/check-retirement.c', '-o', output / 'check-retirement'])
    run('retirement-check', [output / 'check-retirement'])
    # Compile the actual broker into one admission check, with its pinned flags.
    for flag in ['-c', '-o', '-MF', '-MQ']:
        index = admission_command.index(flag)
        del admission_command[index:index + 2]
    admission_command.remove('-MD')
    run('compile-admission-check', [*admission_command, '-UNDEBUG',
                                    REPO / 'graphics/renderer/check-admission.c',
                                    '-o', output / 'check-admission'], renderer / 'build')
    run('admission-check', [output / 'check-admission'])
    manifest.update(primary_monitor_metadata=1, renderer_control_version=2,
                    context_retirement=1, context_admission=1)
    notice = result / 'Notices/Perpendicular'
    notice.mkdir(parents=True, exist_ok=True)
    for path in [header, monitor_patch, retirement_patch, admission_patch]:
        shutil.copy2(path, notice / path.name)
    receipt = {'schema': 1, 'base_runtime_manifest_sha256': digest(runtime / 'runtime.json'),
               'qemu_reference_pins': QEMU_PINS, 'renderer_reference_pins': RENDERER_PINS,
               'qemu_overlay_pins': OVERLAY_PINS, 'unchanged_qemu_text_sha256': baseline_signature,
               'qemu_link_inputs_verified': len(link_inputs),
               'patches': {p.name: digest(p) for p in [header, monitor_patch, retirement_patch, admission_patch]},
               'compiled_qemu_units': [name for name, _ in units], 'compiled_renderer_units': changed,
               'guest_wire_version': 1, 'host_transport_version': 3, 'native_descriptor_version': 2,
               'renderer_control_version': 2, 'primary_monitor_metadata': 1,
               'VM_started': False, 'runtime_verified': False,
               'checks': ['pinned source and object identities', 'monitor header', 'context retirement header', 'context admission refusal',
                          'QEMU version', 'signatures', 'runtime file hashes']}
    receipt_file = notice / 'local-graphics.json'
    receipt_file.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    manifest['local_graphics_receipt_sha256'] = digest(receipt_file)
    (result / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    verify(result, manifest['files'])
    verify(reference, QEMU_PINS)
    verify(reference, OVERLAY_PINS)
    verify(renderer, RENDERER_PINS)
    total = sum(p.stat().st_size for p in output.rglob('*') if p.is_file())
    require(total < 1024 ** 3, 'Output unexpectedly exceeds 1 GiB; inspect before packaging.')
    print('Prepared:', result)
    print('Output bytes:', total)
    print('Seven C units rebuilt. Runtime and Windows compatibility still require the app/VM verification.')


if __name__ == '__main__':
    main()
