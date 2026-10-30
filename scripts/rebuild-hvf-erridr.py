#!/usr/bin/env python3
"""Build an isolated HVF ERRIDR candidate from the actual local link recipe.

Requires retained local QEMU source/build and the receipt that produced the
reference QEMU. Never changes that source, installed app, or a VM. Baseline
code/data sections must match the installed executable before patching.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import struct
import subprocess

REPO = Path(__file__).resolve().parent.parent
SOURCE_SHA = 'f593768ea0fad5ad427b8ad62cc87f48fbc834ee1a3b29764d023ab14b1ac8d8'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sections(path):
    data = path.read_bytes()
    if struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('Expected a thin ARM64 Mach-O')
    result = {}
    offset = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x19:
            for index in range(struct.unpack_from('<I', data, offset + 64)[0]):
                item = offset + 72 + 80 * index
                name = data[item:item + 16].split(b'\0')[0].decode()
                segment = data[item + 16:item + 32].split(b'\0')[0].decode()
                length, position = struct.unpack_from('<QI', data, item + 40)
                if position:
                    result[segment + ',' + name] = hashlib.sha256(data[position:position + length]).hexdigest()
        offset += size
    if '__TEXT,__text' not in result:
        raise ValueError('Missing executable code')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('source', 'build', 'link-receipt', 'reference-app', 'output'):
        parser.add_argument('--' + option, type=Path, required=True)
    args = parser.parse_args()
    source, build, reference, out = map(Path.resolve, (args.source, args.build, args.reference_app, args.output))
    if out.exists():
        raise ValueError('Output must be a new directory')
    original = source / 'target/arm/hvf/hvf.c'
    if digest(original) != SOURCE_SHA:
        raise ValueError('Different HVF source; adapt and qualify this actual profile first')
    native = reference / 'Contents/Resources/Native3D'
    manifest = json.loads((native / 'runtime.json').read_text())
    if any(digest(native / name) != expected for name, expected in manifest['files'].items()):
        raise ValueError('Reference runtime differs from its manifest')
    receipt = json.loads(args.link_receipt.read_text())
    if receipt['qemu'] != digest(native / 'bin/qemu-system-aarch64'):
        raise ValueError('The link receipt belongs to another QEMU')
    out.mkdir(parents=True)

    def run(command):
        result = subprocess.run(list(map(str, command)), cwd=build, capture_output=True, text=True)
        with (out / 'build.log').open('a') as log:
            log.write(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError('Build failed; see ' + str(out / 'build.log'))
        return result.stdout

    def package(link, target, app):
        link = list(link)
        link[link.index('-o') + 1] = str(target)
        run(link)
        for line in run(['otool', '-L', target]).splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(('/System/', '/usr/lib/', '@executable_path/')):
                continue
            name = Path(dependency).name
            if (app / 'Contents/Resources/Native3D/lib' / name).is_file():
                replacement = '@loader_path/../lib/' + name
            elif (app / 'Contents/Frameworks/Runtime/lib' / name).is_file():
                replacement = '@loader_path/../../../Frameworks/Runtime/lib/' + name
            else:
                raise ValueError('Unpackaged dependency: ' + dependency)
            run(['install_name_tool', '-change', dependency, replacement, target])
        run(['codesign', '--force', '--sign', '-', '--entitlements', REPO / 'macos/Hypervisor.entitlements', target])

    baseline = out / 'qemu-system-aarch64'
    package(receipt['link'], baseline, reference)
    if sections(baseline) != sections(native / 'bin/qemu-system-aarch64'):
        raise ValueError('Baseline code/data differs; candidate not built')
    patched = out / 'hvf.c'
    shutil.copy2(original, patched)
    patch = REPO / 'memory/qemu/hvf-erridr.patch'
    run(['patch', '--batch', '--forward', str(patched), str(patch)])
    rows = json.loads((build / 'compile_commands.json').read_text())
    row = next(row for row in rows if row['file'].endswith('target/arm/hvf/hvf.c'))
    compile_args = shlex.split(row['command'])
    compile_args[compile_args.index(row['file'])] = str(patched)
    compile_args[1:1] = ['-I' + str(original.parent)]
    obj = out / 'hvf.c.o'
    for flag, value in (('-o', obj), ('-MF', out / 'hvf.c.o.d')):
        if flag in compile_args:
            compile_args[compile_args.index(flag) + 1] = str(value)
    run(compile_args)
    link = list(receipt['link'])
    old_object = 'libqemu-aarch64-softmmu.a.p/target_arm_hvf_hvf.c.o'
    if link.count(old_object) != 1:
        raise ValueError('Unexpected HVF link graph')
    link[link.index(old_object)] = str(obj)
    app = out / 'Perpendicular.app'
    shutil.copytree(reference, app, symlinks=True)
    runtime = app / 'Contents/Resources/Native3D'
    target = runtime / 'bin/qemu-system-aarch64'
    target.unlink()
    package(link, target, app)
    manifest['files']['bin/qemu-system-aarch64'] = digest(target)
    manifest['hvf_erridr_el1_version'] = 1
    manifest['hvf_erridr_patch_sha256'] = digest(patch)
    (runtime / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run(['codesign', '--force', '--sign', '-', app])
    run(['codesign', '--verify', '--deep', '--strict', app])
    (out / 'receipt.json').write_text(json.dumps(dict(sourceSHA=SOURCE_SHA, patchSHA=digest(patch),
        baselineSections=sections(baseline), qemu=digest(target), compile=compile_args, link=link), indent=2))
    print(app)


if __name__ == '__main__':
    main()
