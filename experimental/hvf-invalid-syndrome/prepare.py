#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare one copied HVF diagnostic source and exact compile argv; never build/run QEMU."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE = ROOT / '.tools/graphics-experiment/src/qemu'
BUILD = ROOT / '.tools/graphics-experiment/build/qemu'
OUTPUT_ROOT = ROOT / '.tools/hvf-invalid-syndrome'
PIN = '88e5ee7ec6703662fec7b638cca74c4769e683d6'
SOURCE_SHA = '004a3865590a1bb834b7bc8f20169cce3da872d6a7b5cc3184973fe8c0d5357e'
NINJA_SHA = '3d7c980892aab9b8f4a26018fc84fd58c0cfd41b7084762e23bc11c810b2bfe4'
OBJECT = 'libqemu-aarch64-softmmu.a.p/target_arm_hvf_hvf.c.o'
ANCHOR = '        assert(isv);\n'
MARKER = 'perpendicular-hvf-isv0-v1'


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def block(text, prefix):
    found = [part for part in text.split('\n\n') if part.startswith(prefix)]
    require(len(found) == 1, 'Missing/ambiguous Ninja block: ' + prefix)
    return found[0]


def patch(text, fragment):
    require(text.count(ANCHOR) == 1 and MARKER not in text,
            'Original assert anchor changed, is ambiguous, or is already instrumented')
    require(fragment.count(MARKER) == 1 and fragment.startswith('/* SPDX-License-Identifier:'),
            'Diagnostic fragment identity changed')
    # The original assert is still the next executed statement on this path.
    return text.replace(ANCHOR, fragment + ANCHOR, 1)


def source_check():
    result = subprocess.run(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'],
                            capture_output=True, text=True, check=True)
    require(result.stdout.strip() == PIN, 'QEMU source base pin changed')
    source = SOURCE / 'target/arm/hvf/hvf.c'
    ninja = BUILD / 'build.ninja'
    require(sha(source) == SOURCE_SHA, 'Full HVF preimage SHA-256 changed')
    require(sha(ninja) == NINJA_SHA, 'Pinned Ninja recipes changed')
    text = ninja.read_text()
    recipe = block(text, 'build ' + OBJECT + ':')
    require(recipe.splitlines()[0].startswith(
        'build ' + OBJECT + ': c_COMPILER ../../src/qemu/target/arm/hvf/hvf.c || '),
        'HVF compile edge changed')
    args = [line[len(' ARGS = '):] for line in recipe.splitlines() if line.startswith(' ARGS = ')]
    require(len(args) == 1 and '$' not in args[0], 'Unexpected compile variables')
    rule = block(text, 'rule c_COMPILER\n')
    require(' command = cc $ARGS -MD -MQ $out -MF $DEPFILE -o $out -c $in' in rule,
            'Compiler rule changed')
    flags = shlex.split(args[0])
    require(not any(flag.startswith('-DNDEBUG') for flag in flags), 'Original assertions are disabled')
    link = block(text, 'build qemu-system-aarch64-unsigned:')
    require(link.splitlines()[0].split().count(OBJECT) == 1,
            'Expected exactly one HVF object in original link edge')
    original = source.read_text()
    fragment = (HERE / 'diagnostic.inc.c').read_text()
    return source, flags, original, patch(original, fragment)


def self_test(original, patched):
    fragment = (HERE / 'diagnostic.inc.c').read_text()
    require(patched.replace(fragment, '', 1) == original,
            'Diagnostic changed bytes outside its insertion')
    require(patched.count(ANCHOR) == original.count(ANCHOR) == 1,
            'Original assert was removed or duplicated')
    require(patched.index(MARKER) < patched.index(ANCHOR), 'Diagnostic is after the assert')
    for invalid in (patched, original + ANCHOR, original.replace(ANCHOR, '        assert(false);\n')):
        try:
            patch(invalid, fragment)
        except ValueError:
            pass
        else:
            raise ValueError('Modified/ambiguous/already-patched source was accepted')
    for forbidden in ('address_space_read(', 'address_space_write(', 'cpu_memory_rw_debug(',
                      'hv_vcpu_set_', 'advance_pc =', 'hv_vm_map(', 'hv_vm_unmap(',
                      'arm_emul_', 'hvf_raise_exception(', 'abort(', 'assert('):
        require(forbidden not in fragment, 'Diagnostic includes a forbidden execution change')
    require(fragment.count('memory_region_find(') == fragment.count('memory_region_unref(') == 1,
            'Metadata lookup reference is not balanced')
    require('char diag_name[97]' in fragment and 'sizeof(diag_name) - 1' in fragment,
            'Region-name output is not bounded')


def write_private(path, value):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(value)


def prepare(output, source, flags, original, patched):
    if not OUTPUT_ROOT.exists():
        OUTPUT_ROOT.mkdir(mode=0o700)
    root_meta = OUTPUT_ROOT.lstat()
    require(stat.S_ISDIR(root_meta.st_mode) and root_meta.st_uid == os.geteuid()
            and stat.S_IMODE(root_meta.st_mode) == 0o700, 'Unsafe private output root')
    output = Path(os.path.abspath(output))
    require(output.parent == OUTPUT_ROOT and output.name not in ('.', '..'),
            'Output must be a fresh immediate child of ' + str(OUTPUT_ROOT))
    require(not output.exists() and not output.is_symlink(), 'Output already exists')
    output.mkdir(mode=0o700)
    copied = output / 'source'
    copied.mkdir(mode=0o700)
    copied_source = copied / 'hvf.c'
    write_private(copied_source, patched)
    # Preserve quoted-source include lookup without changing any pinned flags.
    # trace.h is the sole local quoted header in this exact preimage.
    trace = source.parent / 'trace.h'
    write_private(copied / 'trace.h', trace.read_text())
    obj = output / 'hvf.c.o'
    argv = ['cc', *flags, '-MD', '-MQ', str(obj), '-MF', str(obj) + '.d',
            '-o', str(obj), '-c', str(copied_source)]
    command = {'cwd': str(BUILD), 'argv': argv, 'executed': False}
    write_private(output / 'compile-command.json', json.dumps(command, indent=2) + '\n')
    write_private(output / 'compile.sh', '#!/bin/sh\nset -eu\ncd ' + shlex.quote(str(BUILD))
                  + '\nexec ' + shlex.join(argv) + '\n')
    diff = ''.join(difflib.unified_diff(original.splitlines(True), patched.splitlines(True),
                                       fromfile='a/target/arm/hvf/hvf.c',
                                       tofile='b/target/arm/hvf/hvf.c'))
    write_private(output / 'diagnostic.patch', diff)
    protected = [source, trace, BUILD / 'build.ninja', BUILD / OBJECT,
                 HERE / 'diagnostic.inc.c', Path(__file__).resolve()]
    manifest = {
        'schema': 1, 'source_base_pin': PIN,
        'preimage_includes_existing_private_changes': True,
        'source_preimage_sha256': SOURCE_SHA,
        'patched_source_sha256': sha(copied_source),
        'ninja_sha256': NINJA_SHA,
        'inputs': {str(p): sha(p) for p in protected},
        'compile_command': command,
        'link_substitution': {'old_token': OBJECT, 'new_token': str(obj), 'required_count': 1},
        'original_assert_retained': True, 'guest_memory_read': False,
        'guest_memory_write': False, 'mmio_dispatch': False,
        'compiled': False, 'linked': False, 'signed': False,
        'installed': False, 'vm_started': False,
    }
    write_private(output / 'prepare.json', json.dumps(manifest, indent=2) + '\n')
    require(sha(source) == SOURCE_SHA and sha(BUILD / 'build.ninja') == NINJA_SHA,
            'Original source or Ninja recipes changed during preparation')
    print(json.dumps({'result': 'PASS', 'output': str(output), 'compile_command': str(output / 'compile.sh'),
                      'object': str(obj), 'compiled': False, 'vm_started': False}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    source, flags, original, patched = source_check()
    if args.self_test:
        self_test(original, patched)
    if args.prepare:
        require(args.output is not None, '--prepare requires --output')
        prepare(args.output, source, flags, original, patched)
    else:
        require(args.output is None, '--output requires --prepare')
        print(json.dumps({'result': 'PASS', 'source_base_pin': PIN,
                          'preimage_sha256': SOURCE_SHA, 'self_test': args.self_test,
                          'compiled': False, 'vm_started': False}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Preparation refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
