#!/usr/bin/env python3
"""Package the qualified private v0.4 renderer build as a separate runtime.

Reads pinned build outputs and a hash-verified runtime. Preserves QEMU/backend,
does not install a driver, change an app, start Windows or qualify a runtime.
Source preparation and compilation are documented in graphics/renderer/README.md.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

REPO = Path(__file__).resolve().parent.parent
INPUTS = {
    'source-receipt.json': 'a23e9eb2dc691e4bf3e7b20b809258574897b73dcfda19b759fe55e9afc2d4df',
    'build/src/libvirglrenderer.1.dylib': 'b0000b51cfbdd4fde8e9a0de217ed895753b72f9bab4cc631645d8f8e9eeedf1',
    'build/server/virgl_render_server': 'b010839f30c8e2b21c98040c45994f5c0142b6fc4214a14bb21d00cd9cd9e2a6',
}
PRESERVED = {
    'bin/qemu-system-aarch64': '69c236476db89974ecdbb85d0d543efb0a4e126f40cbb5fa58da83782515349a',
    'lib/libdxmt-native.dylib': '1a704afafdb17439ea1fbf90371498e34b94a8d932914778850a8ea19cf32e01',
}
PACKAGED = {
    'lib/libvirglrenderer.1.dylib': 'a93c2e5e34a8b1680673ea5fb08761559797c34d446e1657bb23986ffaa5e209',
    'bin/virgl_render_server': '0869b34035ace7e2992bb2d1b61cd6521b39d4de9839e3ecfaed808a57f8ff90',
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True, help='Matching prepared-source and Meson output root')
    parser.add_argument('--runtime', type=Path, required=True, help='Current complete Native3D runtime to preserve')
    parser.add_argument('--output', type=Path, required=True, help='Fresh private runtime directory')
    args = parser.parse_args()
    build, runtime, output = args.build.resolve(strict=True), args.runtime.resolve(strict=True), args.output.resolve()
    require(not output.exists(), 'Fresh output required')
    require(REPO not in output.parents or REPO / '.build' in output.parents, 'Private output required')
    for name, expected in INPUTS.items():
        path = build / name
        require(path.is_file() and not path.is_symlink() and digest(path) == expected,
                'Different qualified build input: ' + name)
    manifest = json.loads((runtime / 'runtime.json').read_text())
    require(manifest.get('schema') == 1 and manifest.get('guest_wire_version') in [1, 2]
            and manifest.get('host_transport_version') == 3 and manifest.get('native_descriptor_version') == 2,
            'Different runtime protocols')
    for flag in ['context_retirement', 'context_admission', 'resource_retirement',
                 'import_lifetime', 'scanout_selection_retirement', 'scanout_consumer_demand']:
        require(manifest.get(flag) == 1, 'Missing required runtime behavior: ' + flag)
    for name, expected in manifest['files'].items():
        path = Path(name)
        require(not path.is_absolute() and '..' not in path.parts, 'Unsafe runtime path')
        require((runtime / path).is_file() and digest(runtime / path) == expected, 'Runtime hash mismatch: ' + name)
    for name, expected in PRESERVED.items():
        require(manifest['files'].get(name) == expected, 'Different preserved runtime component: ' + name)
    source_receipt = json.loads((build / 'source-receipt.json').read_text())
    for name, expected in source_receipt['patches'].items():
        require(digest(REPO / 'graphics/renderer' / name) == expected, 'Source patch changed: ' + name)
    require(source_receipt['decode_failure_diagnostics'] is False, 'Temporary diagnostics must be absent')
    shutil.copytree(runtime, output, symlinks=True)
    for name, origin in [('lib/libvirglrenderer.1.dylib', 'build/src/libvirglrenderer.1.dylib'),
                         ('bin/virgl_render_server', 'build/server/virgl_render_server')]:
        target = output / name
        shutil.copy2(build / origin, target)
        changes = []
        for line in subprocess.check_output(['otool', '-L', str(target)], text=True).splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(('/System/', '/usr/lib/', '@')):
                continue
            packaged = output / 'lib' / Path(dependency).name
            require(packaged.is_file(), 'Missing packaged dependency: ' + dependency)
            relative = '@loader_path/../lib/' if name.startswith('bin/') else '@loader_path/'
            changes += ['-change', dependency, relative + packaged.name]
        if name.startswith('lib/'):
            changes += ['-id', '@rpath/' + target.name]
        if changes:
            subprocess.run(['install_name_tool', *changes, str(target)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(target)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
        actual = digest(target)
        require(actual == PACKAGED[name], 'Packaged binary differs from the qualified candidate: ' + name)
        manifest['files'][name] = actual
    manifest.update(guest_wire_version=2, renderer_source_pin=source_receipt['renderer_pin'],
                    protocol_source_pin=source_receipt['protocol_pin'], paired_guest_protocol_files=311,
                    query_feedback_end_generation=1, resource_update_context=1)
    manifest.pop('decode_failure_diagnostics', None)
    # These are build properties. Runtime evidence belongs in VERIFICATION.md.
    receipt = dict(source_receipt, build_completed=True, runtime_verified=False,
                   files={name: manifest['files'][name] for name in PACKAGED})
    notices = output / 'Notices/Perpendicular'
    notices.mkdir(exist_ok=True)
    for name in source_receipt['patches']:
        shutil.copy2(REPO / 'graphics/renderer' / name, notices / name)
    (notices / 'wire2-pair.json').write_text(json.dumps(receipt, indent=2) + '\n')
    manifest['wire2_pair_receipt_sha256'] = digest(notices / 'wire2-pair.json')
    (output / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for name, expected in manifest['files'].items():
        require(digest(output / name) == expected, 'Final runtime hash mismatch: ' + name)
    print('Packaged matching Wire2 pair; not installed: ' + str(output))


if __name__ == '__main__':
    main()
