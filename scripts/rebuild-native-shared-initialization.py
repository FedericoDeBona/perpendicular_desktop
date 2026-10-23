#!/usr/bin/env python3
"""Rebuild the pinned local backend with shared initialization before export.

Produces a separate private runtime. Never starts Windows or updates an app.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess

REPO = Path(__file__).resolve().parent.parent
PINS = {
    'source-files.json': '7c7310222687aebec79b7d6b922996b0530c7d06fcd91aaa0df1a22f44d9ee0c',
    'build/compile_commands.json': '1ae44d76426f86b77080bbc8a7df2c8aa2758cf4278038a57715192a84b735fb',
    'build/src/d3d11/libd3d11.a': '253518414893ddd3fef0b58091ed0d470b9a1665647afbcb865b61bdf7898dea',
    'build/src/dxmt/libdxmt.a': '25f44fe74e778c85ca95d16c8293528de7f4ceff2d9171abc01354de641f12d4',
    'build/src/nativemetal/libwinemetal.a': '6a2793cb35b5da8a8db2d862478b1464d35071d75975c87f5fdf7c63129aa858',
    'build/build.ninja': 'f6e2bc5af4705c2ddad84659fa8f237b30d6e25ef36b41d8131211d70012a4c4',
    'prefix/lib/libdxmt-native.dylib': 'ee4249f15cfb6ce61a8f54e4a1e73452aa4e8eb02cfbc12a00a8045c27fb5766',
}
BASE_BACKEND = 'e041d265e64b395bfeeefe9ec7df0f9a8d75258f9b7dd7ec797a5d385315d947'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args, cwd=None):
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    reference, runtime = args.reference.resolve(strict=True), args.runtime.resolve(strict=True)
    output = args.output.resolve()
    require(not output.exists(), 'Fresh private output required')
    require(not output.is_relative_to(REPO) or output.is_relative_to(REPO / '.build'), 'Private output required')
    for name, expected in PINS.items():
        require(digest(reference / name) == expected, 'Different backend input: ' + name)
    inventory = json.loads((reference / 'source-files.json').read_text())
    for group, root in [('repository', reference / 'src/dxmt'),
                        ('directx_headers', reference / 'src/dxmt/include/native/directx')]:
        for name, expected in inventory[group].items():
            require(digest(root / name) == expected, 'Different source: ' + name)
    manifest = json.loads((runtime / 'runtime.json').read_text())
    require(manifest.get('guest_wire_version') == 2 and manifest.get('host_transport_version') == 3
            and manifest.get('native_descriptor_version') == 2
            and manifest.get('protocol_source_pin') == 'f510a6e41ea89a6d626de4da9d9b02978a770e37', 'Different runtime protocol')
    require(manifest['files'].get('lib/libdxmt-native.dylib') == BASE_BACKEND, 'Different baseline backend')
    for name, expected in manifest['files'].items():
        relative = Path(name)
        require(not relative.is_absolute() and '..' not in relative.parts, 'Unsafe runtime path')
        require(digest(runtime / relative) == expected, 'Runtime mismatch: ' + name)
    records = json.loads((reference / 'build/compile_commands.json').read_text())
    original_tools = records[0]['directory'].split('/.tools/')[0] + '/.tools/'

    def relocate(value):
        return value.replace(original_tools, str(reference.parent) + '/')

    name = 'src/d3d11/d3d11_texture_device.cpp'
    source = output / 'source' / name
    source.parent.mkdir(parents=True)
    shutil.copy2(reference / 'src/dxmt' / name, source)
    patch = REPO / 'graphics/backend/shared-initialization.patch'
    run(['patch', '-p1', '--forward', '--batch', '-i', patch], output / 'source')
    row = next(row for row in records if row['file'].endswith('/' + name))
    command = [relocate(arg) for arg in shlex.split(row['command'])]
    obj = output / 'd3d11_texture_device.cpp.o'
    for flag, value in [('-c', source), ('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)]:
        command[command.index(flag) + 1] = str(value)
    run(command, reference / 'build')
    archive = output / 'libd3d11.a'
    shutil.copy2(reference / 'build/src/d3d11/libd3d11.a', archive)
    run(['ar', '-r', archive, obj])
    ninja = reference.parent / 'build-venv/bin/ninja'
    recipe = subprocess.check_output([str(ninja), '-C', str(reference / 'build'), '-t', 'commands',
                                      'src/dxmt-native/libdxmt-native.dylib'], text=True)
    command = [relocate(arg) for arg in shlex.split(recipe.splitlines()[-1])]
    library = output / 'libdxmt-native.dylib'
    command[command.index('-o') + 1] = str(library)
    command = [str(archive) if arg == 'src/d3d11/libd3d11.a' else arg for arg in command]
    run(command, reference / 'build')
    result = output / 'Native3D'
    shutil.copytree(runtime, result, symlinks=True)
    target = result / 'lib/libdxmt-native.dylib'
    shutil.copy2(library, target)
    changes = []
    for line in subprocess.check_output(['otool', '-L', str(target)], text=True).splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith(('/System/', '/usr/lib/', '@')):
            continue
        require((result / 'lib' / Path(dependency).name).is_file(), 'Missing dependency: ' + dependency)
        changes += ['-change', dependency, '@loader_path/' + Path(dependency).name]
    run(['install_name_tool', *changes, '-id', '@rpath/libdxmt-native.dylib', target])
    run(['codesign', '--force', '--sign', '-', '--timestamp=none', target])
    run(['codesign', '--verify', '--strict', target])
    manifest['files']['lib/libdxmt-native.dylib'] = digest(target)
    manifest['shared_texture_initialization_before_export'] = 1
    (result / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for name, expected in manifest['files'].items():
        require(digest(result / name) == expected, 'Packaged runtime mismatch: ' + name)
    receipt = {'reference': str(reference), 'base_backend': BASE_BACKEND,
               'patch_sha256': digest(patch), 'source_sha256': digest(source),
               'raw_backend_sha256': digest(library), 'backend_sha256': digest(target),
               'compiled_units': ['d3d11_texture_device.cpp'], 'runtime_verified': False}
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    notices = result / 'Notices/Perpendicular'
    notices.mkdir(exist_ok=True)
    shutil.copy2(patch, notices / patch.name)
    notice = notices / 'shared-initialization.json'
    notice.write_text(json.dumps(receipt, indent=2) + '\n')
    manifest['shared_texture_initialization_receipt_sha256'] = digest(notice)
    (result / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(result)


if __name__ == '__main__':
    main()
