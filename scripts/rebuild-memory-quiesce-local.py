#!/usr/bin/env python3
"""Apply the shared RAM fix to a retained local link recipe, without cache mutation.

The installed QEMU pin and every code/data section of a fresh baseline must
match before compiling. This supports later monitor overlays whose unsigned
base is no longer the one recorded by the older memory-runtime receipt.
"""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ['scripts/patch-qemu-memory-quiesce.py', 'memory/qemu/perp-hvf-quiesce.h']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'build', 'link-receipt', 'reference-app', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--ninja', type=Path, required=True)
    args = parser.parse_args()
    source, build, reference, receipt_path = [p.resolve(strict=True) for p in
        (args.source, args.build, args.reference_app, args.link_receipt)]
    out = args.output.resolve()
    if out.exists() or any(p.is_relative_to(ROOT) for p in (source, build, out)):
        raise ValueError('Use retained external inputs and a fresh private output')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(reference)], check=True)
    native = reference / 'Contents/Resources/Native3D'
    manifest = json.loads((native / 'runtime.json').read_text())
    for name, expected in manifest['files'].items():
        file = native / name
        if not file.resolve().is_relative_to(native) or sha(file) != expected:
            raise ValueError('Installed native runtime differs: ' + name)
    receipt = json.loads(receipt_path.read_text())
    installed = native / 'bin/qemu-system-aarch64'
    if receipt['qemu'] != sha(installed):
        raise ValueError('Link receipt does not belong to the installed QEMU')
    base = json.loads((ROOT / 'memory/releases/0.1.0-darwin-arm64-m1.json').read_text())
    # These four shared memory sources are identical on the qualified M1/M4
    # bases. The host link graph and binaries remain specific to this Mac.
    for name, expected in base['sourceBefore'].items():
        if sha(source / name) != expected:
            raise ValueError('Shared memory source base differs: ' + name)
    for name in ('perp-balloon-reclaim.h', 'perp-virtio-mem-hvf.h'):
        if sha(source / 'hw/virtio' / name) != sha(ROOT / 'memory/qemu' / name):
            raise ValueError('Memory ownership helper differs: ' + name)
    link = list(receipt['link'])
    inputs = {name: sha(Path(name) if Path(name).is_absolute() else build / name)
              for name in link if name.endswith(('.o', '.a')) and not name.startswith('-')}
    if len(inputs) < 1000:
        raise ValueError('Incomplete local link graph')
    out.mkdir(parents=True)

    def run(command, label):
        command = list(map(str, command))
        (out / (label + '.command.json')).write_text(json.dumps(command, indent=2) + '\n')
        result = subprocess.run(command, cwd=build, capture_output=True, text=True)
        (out / (label + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError('Failed ' + label + '; see its private log')
        return result.stdout

    baseline = out / 'qemu-system-aarch64'
    baseline_link = list(link)
    baseline_link[baseline_link.index('-o') + 1] = str(baseline)
    run(baseline_link, 'baseline-link')
    for line in run(['otool', '-L', baseline], 'baseline-dependencies').splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith(('/System/', '/usr/lib/', '@executable_path/')):
            continue
        name = Path(dependency).name
        if (native / 'lib' / name).is_file():
            replacement = '@loader_path/../lib/' + name
        elif (reference / 'Contents/Frameworks/Runtime/lib' / name).is_file():
            replacement = '@loader_path/../../../Frameworks/Runtime/lib/' + name
        else:
            raise ValueError('Unpackaged dependency: ' + dependency)
        run(['install_name_tool', '-change', dependency, replacement, baseline], 'baseline-relocate-' + name)
    sections = runpy.run_path(str(ROOT / 'scripts/rebuild-hvf-erridr.py'))['sections']
    if sections(baseline) != sections(installed):
        raise ValueError('Baseline code/data differs; no candidate compiled')
    # Also preserve dependency identities, versions and ordering, not just code.
    actual = run(['otool', '-L', baseline], 'baseline-relocated-dependencies').splitlines()[1:]
    expected = subprocess.check_output(['otool', '-L', str(installed)], text=True).splitlines()[1:]
    if actual != expected:
        raise ValueError('Baseline dependency closure differs')
    overlay = out / 'source'
    for name in base['sourceBefore']:
        target = overlay / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    run(['python3', ROOT / PATCHES[0], overlay], 'patch')
    rows = json.loads((build / 'compile_commands.json').read_text())
    candidate_link = list(link)
    dependencies = subprocess.check_output([str(args.ninja.resolve(strict=True)), '-C',
                                            str(build), '-t', 'deps'], text=True)
    affected = {chunk.splitlines()[0].split(': #deps', 1)[0]
                for chunk in dependencies.split('\n\n') if chunk and any(
                    '/include/hw/virtio/virtio-' + d + '.h' in chunk
                    for d in ('balloon', 'mem'))}
    required = {'libqemu-aarch64-softmmu.a.p/hw_virtio_virtio-' + d + '.c.o'
                for d in ('balloon', 'mem', 'balloon-pci', 'mem-pci')}
    if not required.issubset(affected):
        raise ValueError('Incomplete recorded memory header dependency graph')
    for index, old_object in enumerate(sorted(affected)):
        row = next(r for r in rows if shlex.split(r['command'])[
                   shlex.split(r['command']).index('-o') + 1] == old_object)
        command = shlex.split(row['command'])
        name = str(Path(row['file']).resolve().relative_to(source)) if Path(row['file']).is_absolute() else str((build / row['file']).resolve().relative_to(source))
        if candidate_link.count(old_object) != 1:
            raise ValueError('Memory unit is not a unique link input: ' + name)
        if name in base['sourceBefore']:
            command[command.index(row['file'])] = str(overlay / name)
        command[1:1] = ['-iquote', str(overlay / 'include'),
                        '-I' + str(overlay / 'hw/virtio'),
                        '-iquote', str(source / 'hw/virtio')]
        obj = out / ('memory-unit-%d.o' % index)
        for flag, value in (('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)):
            if flag in command:
                command[command.index(flag) + 1] = str(value)
        run(command, 'compile-%d' % index)
        candidate_link[candidate_link.index(old_object)] = str(obj)
    target = out / 'qemu-system-aarch64-unsigned'
    candidate_link[candidate_link.index('-o') + 1] = str(target)
    run(candidate_link, 'candidate-link')
    if any(sha(Path(n) if Path(n).is_absolute() else build / n) != v for n, v in inputs.items()):
        raise ValueError('Retained link inputs changed during compilation')
    result = {'schema': 1, 'version': 1, 'basePackagedSHA256': sha(installed),
              'baselineSections': sections(baseline), 'localLinkReceiptSHA256': sha(receipt_path),
              'linkInputs': inputs, 'recompiledHeaderUsers': sorted(affected), 'outputSHA256': sha(target),
              'patches': {name: sha(ROOT / name) for name in PATCHES},
              'builderSHA256': sha(Path(__file__)), 'sourceBefore': base['sourceBefore'],
              'sourceAfter': {name: sha(overlay / name) for name in base['sourceBefore']},
              'runtimeQualified': False}
    (out / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Baseline code/data and dependencies match; RAM candidate built; cache untouched.')


if __name__ == '__main__':
    main()
