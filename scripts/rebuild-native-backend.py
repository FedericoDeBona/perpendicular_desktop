#!/usr/bin/env python3
"""Name existing backend errors using a matching private build, without changing behavior."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess

REPO = Path(__file__).resolve().parent.parent
PINS = {
    'prefix/lib/libdxmt-native.dylib': 'f9c5f278b7f704489a90b1e9b5505f0a8e4246d86ee9c49a196432ce08178933',
    'build/src/d3d11/libd3d11.a': '6584ac13c3f67a786833adf1314473e581402b4395b2e5e7f9231a1d92bc3660',
    'build/compile_commands.json': '0b0d6153b64ae6198a46ef95462a14a7e382cd1a6e1a9d18517e6f2ede392ce2',
    'build/build.ninja': 'a5f81c362a215a9de7653d86b2ddb3f8eb252bc5261d28b3ddce0548bf22e419',
    'source-files.json': '7c7310222687aebec79b7d6b922996b0530c7d06fcd91aaa0df1a22f44d9ee0c',
}
PACKAGED_BACKEND = '40c8639327236146c520a79a6308c1f305ce0084463c21904404e00e701d37b0'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, cwd=None):
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    reference = args.reference.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True)
    output = args.output.resolve()
    if output.exists():
        raise ValueError('Fresh output required; existing runtimes are preserved.')
    for name, expected in PINS.items():
        if digest(reference / name) != expected:
            raise ValueError('Different backend build: ' + name)
    manifest = json.loads((runtime / 'runtime.json').read_text())
    if (manifest.get('guest_wire_version'), manifest.get('host_transport_version'),
            manifest.get('native_descriptor_version')) != (1, 3, 2):
        raise ValueError('Incompatible graphics runtime.')
    for name, expected in manifest['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or digest(runtime / relative) != expected:
            raise ValueError('Runtime input mismatch: ' + name)
    if manifest['files'].get('lib/libdxmt-native.dylib') != PACKAGED_BACKEND:
        raise ValueError('The runtime must contain the matching unchanged backend.')
    provenance = json.loads((runtime / 'Notices/provenance.json').read_text())
    if provenance['origins']['lib/libdxmt-native.dylib']['sha256'] != PINS['prefix/lib/libdxmt-native.dylib']:
        raise ValueError('Backend provenance differs from the reference build.')

    records = json.loads((reference / 'build/compile_commands.json').read_text())
    original_root = records[0]['directory'].split('/.tools/')[0]
    reference_root = reference.parent.parent

    def relocate(value):
        return value.replace(original_root + '/.tools/', str(reference_root) + '/.tools/')

    source = reference / 'src/dxmt'
    inventory = json.loads((reference / 'source-files.json').read_text())['repository']
    names = ['src/d3d11/d3d11_' + name + '.cpp'
             for name in ('context_impl', 'context_imm', 'context_def', 'device', 'swapchain')]
    work = output / 'build'
    copied = work / 'source'
    for name in names:
        if digest(source / name) != inventory[name]:
            raise ValueError('Different backend source: ' + name)
        target = copied / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    patch = REPO / 'graphics/backend/named-errors.patch'
    run(['patch', '-p1', '--forward', '--batch', '-i', patch], copied)
    objects = []
    for name in names:
        if name.endswith('context_impl.cpp'):
            continue  # Included by the immediate and deferred context units.
        record = next(row for row in records if row['file'].endswith('/' + name))
        command = [relocate(a) for a in shlex.split(record['command'])]
        obj = work / Path(record['output']).name
        for flag, value in (('-c', copied / name), ('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)):
            command[command.index(flag) + 1] = str(value)
        run(command, reference / 'build')
        objects.append(obj)
    archive = work / 'libd3d11.a'
    shutil.copy2(reference / 'build/src/d3d11/libd3d11.a', archive)
    run(['ar', '-r', archive, *objects])
    ninja = shutil.which('ninja') or str(reference_root / '.tools/build-venv/bin/ninja')
    recipe = subprocess.check_output([ninja, '-C', str(reference / 'build'), '-t', 'commands',
                                      'src/dxmt-native/libdxmt-native.dylib'], text=True)
    command = [relocate(a) for a in shlex.split(recipe.splitlines()[-1])]
    library = work / 'libdxmt-native.dylib'
    command[command.index('-o') + 1] = str(library)
    command = [str(archive) if a == 'src/d3d11/libd3d11.a' else a for a in command]
    run(command, reference / 'build')

    result = output / 'Native3D'
    shutil.copytree(runtime, result, symlinks=True)
    target = result / 'lib/libdxmt-native.dylib'
    shutil.copy2(library, target)
    changes = []
    for line in subprocess.check_output(['otool', '-L', str(target)], text=True).splitlines()[1:]:
        dep = line.strip().split(' (', 1)[0]
        if dep.startswith(('/System/', '/usr/lib/', '@')):
            continue
        if not (result / 'lib' / Path(dep).name).is_file():
            raise ValueError('Missing packaged dependency: ' + dep)
        changes += ['-change', dep, '@loader_path/' + Path(dep).name]
    run(['install_name_tool', *changes, '-id', '@rpath/' + target.name, target])
    run(['codesign', '--force', '--sign', '-', target])
    run(['codesign', '--verify', '--strict', target])
    manifest['files']['lib/libdxmt-native.dylib'] = digest(target)
    manifest['backend_named_errors'] = 1
    (result / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    notices = result / 'Notices/Perpendicular'
    notices.mkdir(exist_ok=True)
    shutil.copy2(patch, notices / patch.name)
    (notices / 'backend-named-errors.json').write_text(json.dumps({
        'schema': 1, 'runtime_verified': False, 'input_backend_sha256': PACKAGED_BACKEND,
        'output_backend_sha256': digest(target), 'reference_pins': PINS,
        'patch_sha256': digest(patch), 'source_inputs': {n: inventory[n] for n in names},
        'changed_behavior': 'Names only; existing error frequency and HRESULTs preserved.',
    }, indent=2) + '\n')
    print(result)


if __name__ == '__main__':
    main()
