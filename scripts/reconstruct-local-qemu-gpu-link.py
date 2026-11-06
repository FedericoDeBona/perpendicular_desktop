#!/usr/bin/env python3
"""Recompile restored GPU header users into a private local QEMU link graph.

For retained caches whose objects still contain a retired GPU experiment.
This is source reconstruction only: rebuild-hvf-idle.py must subsequently
prove exact baseline code/data and dependencies against the installed app.
No cache object, source, installed application or VM is changed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'build', 'link-command', 'ninja', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    source, build, ninja = (p.resolve(strict=True) for p in
                             (args.source, args.build, args.ninja))
    out = args.output.resolve()
    repo = Path(__file__).resolve().parents[1]
    if out.exists() or out.is_relative_to(repo):
        raise ValueError('Use a new private output outside the repository')
    link = json.loads(args.link_command.read_text())
    inputs = {name: hashlib.sha256((Path(name) if Path(name).is_absolute()
                                    else build / name).read_bytes()).hexdigest()
              for name in link if name.endswith(('.o', '.a')) and not name.startswith('-')}
    deps = subprocess.check_output([str(ninja), '-C', str(build), '-t', 'deps'], text=True)
    affected = {chunk.splitlines()[0].split(': #deps', 1)[0]
                for chunk in deps.split('\n\n')
                if chunk and '/include/hw/virtio/virtio-gpu.h' in chunk}
    unit = 'libqemu-aarch64-softmmu.a.p/hw_display_virtio-gpu.c.o'
    if unit not in affected or unit not in link:
        raise ValueError('Missing GPU header dependency graph')
    out.mkdir(parents=True, mode=0o700)
    rows = json.loads((build / 'compile_commands.json').read_text())
    used = []
    for index, old in enumerate(sorted(affected)):
        if old not in link:
            continue
        if link.count(old) != 1:
            raise ValueError('Ambiguous GPU link input')
        row = next(r for r in rows if (lambda c: c[c.index('-o') + 1])(
                    shlex.split(r['command'])) == old)
        file = (build / row['file']).resolve(strict=True)
        if not file.is_relative_to(source):
            raise ValueError('GPU source escapes selected local source')
        command = shlex.split(row['command'])
        obj = out / ('unit-' + str(index) + '.o')
        for flag, value in (('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)):
            if flag in command:
                command[command.index(flag) + 1] = str(value)
        (out / ('compile-' + str(index) + '.json')).write_text(json.dumps(command))
        result = subprocess.run(command, cwd=build, capture_output=True, text=True)
        (out / ('compile-' + str(index) + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError('GPU reconstruction failed; see private log')
        link[link.index(old)] = str(obj)
        used.append(old)
    for name, expected in inputs.items():
        file = Path(name) if Path(name).is_absolute() else build / name
        if hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            raise ValueError('Retained link input changed during compilation')
    (out / 'link.command.json').write_text(json.dumps(link, indent=2) + '\n')
    (out / 'receipt.json').write_text(json.dumps({
        'recompiledHeaderUsers': used, 'linkInputs': inputs,
        'qualification': 'source reconstruction only; exact installed baseline check still required'
    }, indent=2) + '\n')
    print(out / 'link.command.json')


if __name__ == '__main__':
    main()
