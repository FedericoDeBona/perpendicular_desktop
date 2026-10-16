#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare insertion-only copied QEMU sources and compile plans; never compile/run QEMU."""
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
OUTPUT_ROOT = ROOT / '.tools/gpu-map-diagnostics'
PIN = '88e5ee7ec6703662fec7b638cca74c4769e683d6'
NINJA_SHA = '3d7c980892aab9b8f4a26018fc84fd58c0cfd41b7084762e23bc11c810b2bfe4'
INPUTS = {
    'gpu': ('hw/display/virtio-gpu-virgl.c',
            '.tools/graphics-experiment/build/gpu-command-diagnostics-3/source/hw/display/virtio-gpu-virgl.c',
            '024ef0302c67ae1ca9ac8e06af54a3227b05b302d8c23fd4a5740da5bea7d9d6',
            'libcommon.a.p/hw_display_virtio-gpu-virgl.c.o',
            '.tools/graphics-experiment/build/gpu-command-diagnostics-3/virtio-gpu-virgl.c.o'),
    'pci': ('hw/pci/pci.c', '.tools/graphics-experiment/src/qemu/hw/pci/pci.c',
            'ab42707b4ddaefacb96229aa7081e726ef7a0bc42ac7a96c05d773b0d2edbc0e',
            'libcommon.a.p/hw_pci_pci.c.o', None),
    'reset': ('hw/display/virtio-gpu.c', '.tools/graphics-experiment/src/qemu/hw/display/virtio-gpu.c',
              '43cfda3265d99bf3bca1a11f7718c63af89e5b0acd544181a975f43ee2fc922a',
              'libcommon.a.p/hw_display_virtio-gpu.c.o', None),
    'hvf': ('target/arm/hvf/hvf.c', '.tools/hvf-invalid-syndrome/prepare2/source/hvf.c',
            '0c53b98aad106e793439e4523918c55bc7d537086c677fe0441311670ac3b11f',
            'libqemu-aarch64-softmmu.a.p/target_arm_hvf_hvf.c.o',
            '.tools/hvf-invalid-syndrome/prepare2/hvf.c.o'),
}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Insertions:
    def __init__(self, original):
        self.original = self.text = original
        self.insertions = []

    def add(self, anchor, insertion, after=False):
        require(self.text.count(anchor) == 1, 'Missing/ambiguous insertion anchor: ' + anchor[:100])
        require(insertion not in self.original, 'Source is already instrumented')
        self.text = self.text.replace(anchor, anchor + insertion if after else insertion + anchor, 1)
        self.insertions.append(insertion)

    def finish(self):
        restored = self.text
        for insertion in reversed(self.insertions):
            require(restored.count(insertion) == 1, 'Insertion is ambiguous')
            restored = restored.replace(insertion, '', 1)
        require(restored == self.original, 'Original source bytes changed')
        return self.text


def gpu_patch(original):
    p = Insertions(original)
    p.add('#define NATIVE_HANDLE_SUPPORT_VERSION (1)\n', '\n#include "gpu-hooks.inc.c"\n', True)
    p.add('    vmr = g_new0(struct virtio_gpu_virgl_hostmem_region, 1);\n',
          '    perp_gpu_map_diag_gpu(PMD_MAP_ADD_BEGIN, g, res->base.resource_id,\n'
          '                           offset, size, NULL);\n')
    p.add('    res->mr = mr;\n',
          '    perp_gpu_map_diag_gpu(PMD_MAP_ADD_DONE, g, res->base.resource_id,\n'
          '                           offset, size, NULL);\n', True)
    p.add('    QTAILQ_REMOVE(&gl->unmap_done_list, vmr, done_next);\n    res->mr = NULL;',
          '    perp_gpu_map_diag_gpu(PMD_UNMAP_FINISH, g, res->base.resource_id,\n'
          '                           0, 0, NULL);\n')
    p.add('        /* memory region owns self res->mr object and frees it by itself */\n',
          '        perp_gpu_map_diag_gpu(PMD_UNMAP_DETACH_BEGIN, g, res->base.resource_id,\n'
          '                               mr->addr, memory_region_size(mr), NULL);\n')
    p.add('        memory_region_del_subregion(&b->hostmem, mr);\n',
          '        perp_gpu_map_diag_gpu(PMD_UNMAP_DETACH_DONE, g, res->base.resource_id,\n'
          '                               mr->addr, memory_region_size(mr), NULL);\n', True)
    p.add('    /*\n     * Reset drops queued commands without a response',
          '    perp_gpu_map_diag_gpu(PMD_RESOURCE_DESTROY, g, res->base.resource_id,\n'
          '                           0, 0, NULL);\n\n')
    p.add('    VIRTIO_GPU_FILL_CMD(unref);\n',
          '    perp_gpu_map_diag_gpu(PMD_UNREF_REQUEST, g, unref.resource_id, 0, 0, cmd);\n', True)
    p.add('    virtio_gpu_map_blob_bswap(&mblob);\n',
          '    perp_gpu_map_diag_gpu(PMD_MAP_REQUEST, g, mblob.resource_id,\n'
          '                           mblob.offset, 0, cmd);\n', True)
    p.add('    virtio_gpu_unmap_blob_bswap(&ublob);\n',
          '    perp_gpu_map_diag_gpu(PMD_UNMAP_REQUEST, g, ublob.resource_id, 0, 0, cmd);\n', True)
    return p.finish()


def pci_patch(original):
    p = Insertions(original)
    p.add('//#define DEBUG_PCI\n', '#include "pci-hooks.inc.c"\n\n')
    p.add('    pci_device_deassert_intx(dev);\n',
          '    perp_gpu_map_diag_pci(PMD_PCI_RESET_BEGIN, dev, dev->io_regions[4].addr,\n'
          '                           dev->io_regions[4].addr, 0, 0, 0);\n')
    p.add('    pcie_sriov_pf_reset(dev);\n',
          '    perp_gpu_map_diag_pci(PMD_PCI_RESET_DONE, dev, dev->io_regions[4].addr,\n'
          '                           dev->io_regions[4].addr, 0, 0, 0);\n', True)
    p.add('        /* now do the real mapping */\n',
          '        pcibus_t perp_diag_old_bar = r->addr;\n'
          '        if (i == 4) {\n'
          '            perp_gpu_map_diag_pci(PMD_PCI_BAR_BEGIN, d, r->addr, new_addr, 0, 0, 0);\n'
          '        }\n')
    p.add('    }\n\n    pci_update_vga(d);\n',
          '        if (i == 4) {\n'
          '            perp_gpu_map_diag_pci(PMD_PCI_BAR_DONE, d, perp_diag_old_bar, new_addr, 0, 0, 0);\n'
          '        }\n')
    p.add('    new_pm_state = pci_pm_update(d, addr, l, old_pm_state);\n',
          '    perp_gpu_map_diag_pci(PMD_PCI_CONFIG, d, d->io_regions[4].addr,\n'
          '                           d->io_regions[4].addr, addr, val_in, l);\n', True)
    return p.finish()


def reset_patch(original):
    p = Insertions(original)
    p.add('#include "qemu/osdep.h"\n', '#include "diagnostic.h"\n', True)
    p.add('    QTAILQ_FOREACH_SAFE(res, &g->reslist, next, tmp) {\n',
          '    perp_gpu_map_diag_gpu(PMD_GPU_RESET_BEGIN, g, 0, 0, 0, NULL);\n')
    p.add('    g->reset_finished = true;\n',
          '    perp_gpu_map_diag_gpu(PMD_GPU_RESET_DONE, g, 0, 0, 0, NULL);\n')
    return p.finish()


def hvf_patch(original, observe=False):
    p = Insertions(original)
    p.add('#include "qemu/osdep.h"\n', '#include "diagnostic.h"\n', True)
    p.add('        if (!isv) {\n',
          '            perp_gpu_map_diag_dump(hvf_exit->exception.physical_address);\n', True)
    if observe:
        p.add('#include "gdbstub/enums.h"\n', '#include "instruction-observer.h"\n', True)
        p.add('            if (diag_mr) {\n                memory_region_unref(diag_mr);\n            }\n',
              '            perp_hvf_observe_instruction(cpu, syndrome);\n', True)
    return p.finish()


PATCHERS = {'gpu': gpu_patch, 'pci': pci_patch, 'reset': reset_patch, 'hvf': hvf_patch}


def ninja_block(text, prefix):
    found = [s for s in text.split('\n\n') if s.startswith(prefix)]
    require(len(found) == 1, 'Missing/ambiguous Ninja block: ' + prefix)
    return found[0]


def inspect(observe=False):
    head = subprocess.run(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'],
                          capture_output=True, text=True, check=True).stdout.strip()
    require(head == PIN, 'QEMU base pin changed')
    require(sha(BUILD / 'build.ninja') == NINJA_SHA, 'Ninja preimage changed')
    ninja = (BUILD / 'build.ninja').read_text()
    require(' command = cc $ARGS -MD -MQ $out -MF $DEPFILE -o $out -c $in' in
            ninja_block(ninja, 'rule c_COMPILER\n'), 'Compiler rule changed')
    records = {}
    for kind, (logical, relative, digest, token, current) in INPUTS.items():
        source = ROOT / relative
        require(sha(source) == digest, 'Source preimage changed: ' + str(source))
        original = source.read_text()
        patcher = (lambda text: hvf_patch(text, observe)) if kind == 'hvf' else PATCHERS[kind]
        patched = patcher(original)
        edge = ninja_block(ninja, 'build ' + token + ':')
        args = [s[len(' ARGS = '):] for s in edge.splitlines() if s.startswith(' ARGS = ')]
        require(len(args) == 1 and '$' not in args[0], 'Unexpected compiler variables')
        flags = shlex.split(args[0])
        require(not any(s.startswith('-DNDEBUG') for s in flags), 'Assertions disabled')
        records[kind] = dict(logical=logical, source=source, original=original,
                             patched=patched, flags=flags, token=token,
                             patcher=patcher,
                             current=ROOT / current if current else BUILD / token)
    return records


def self_test(records):
    for kind, r in records.items():
        try:
            r['patcher'](r['patched'])
        except ValueError:
            pass
        else:
            raise ValueError('Already patched source accepted: ' + kind)
    require(records['hvf']['patched'].count('        assert(isv);\n') == 1,
            'Original fatal assert changed')
    require('perp_gpu_map_diag_dump' in records['hvf']['patched'], 'Missing fatal dump')
    ring = (HERE / 'ring.inc.c').read_text()
    for forbidden in ('address_space_read(', 'address_space_write(', 'cpu_memory_rw_debug(',
                      'hv_vm_map(', 'hv_vm_unmap(', 'malloc(', 'g_malloc(', 'abort(', 'assert('):
        require(forbidden not in ring, 'Diagnostic includes execution/allocation primitive')
    require('#define PERP_GPU_MAP_RING_CAPACITY 512u' in ring and
            'perp_gpu_map_sequence - count' in ring, 'Missing bounded/overwrite accounting')


def write_private(path, text):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'w') as f:
        f.write(text)


def prepare(output, records, observer=None):
    OUTPUT_ROOT.mkdir(mode=0o700, exist_ok=True)
    meta = OUTPUT_ROOT.lstat()
    require(stat.S_ISDIR(meta.st_mode) and meta.st_uid == os.geteuid() and
            stat.S_IMODE(meta.st_mode) == 0o700, 'Unsafe output root')
    output = Path(os.path.abspath(output))
    require(output.parent == OUTPUT_ROOT and not output.exists() and not output.is_symlink(),
            'Output must be a fresh immediate child of ' + str(OUTPUT_ROOT))
    output.mkdir(mode=0o700)
    common = output / 'common'
    common.mkdir(mode=0o700)
    inputs = {str(BUILD / 'build.ninja'): NINJA_SHA, str(Path(__file__).resolve()): sha(Path(__file__))}
    for name in ('diagnostic.h', 'ring.inc.c', 'gpu-hooks.inc.c', 'pci-hooks.inc.c', 'pci-fields.inc.c'):
        fragment = HERE / name
        inputs[str(fragment)] = sha(fragment)
        write_private(common / name, fragment.read_text())
    if observer:
        inputs[str(observer)] = sha(observer)
        write_private(common / 'instruction-observer.h', observer.read_text())
    plans = {}
    commands = ['#!/bin/sh', 'set -eu', 'cd ' + shlex.quote(str(BUILD))]
    for kind, r in records.items():
        folder = output / 'source' / kind
        folder.mkdir(parents=True, mode=0o700)
        copied = folder / Path(r['logical']).name
        write_private(copied, r['patched'])
        obj = output / (kind + '.c.o')
        argv = ['cc', *r['flags'], '-I' + str(common), '-iquote', str(r['source'].parent),
                '-iquote', str((SOURCE / r['logical']).parent), '-MD', '-MQ', str(obj),
                '-MF', str(obj) + '.d', '-o', str(obj), '-c', str(copied)]
        inputs[str(r['source'])] = sha(r['source'])
        inputs[str(r['current'])] = sha(r['current'])
        diff = ''.join(difflib.unified_diff(r['original'].splitlines(True), r['patched'].splitlines(True),
                                           fromfile='a/' + r['logical'], tofile='b/' + r['logical']))
        write_private(output / (kind + '.patch'), diff)
        plans[kind] = {'source': str(copied), 'source_sha256': sha(copied),
                       'preimage': str(r['source']), 'preimage_sha256': sha(r['source']),
                       'cwd': str(BUILD), 'argv': argv, 'executed': False,
                       'original_object_token': r['token'],
                       'current_replaced_object': str(r['current']),
                       'object': str(obj)}
        commands.append(shlex.join(argv))
    write_private(output / 'compile.sh', '\n'.join(commands) + '\n')
    manifest = {'schema': 1, 'source_base_pin': PIN, 'ring_capacity': 512,
                'default_off_environment': 'PERPENDICULAR_GPU_MAP_DIAGNOSTICS=1',
                'preimages_include_existing_private_changes': True,
                'insertion_only': True, 'fatal_assert_retained': True,
                'mapping_diagnostic_no_guest_reads_writes_mmio_or_host_pointers': True,
                'optional_instruction_observer': None if not observer else {
                    'source': str(observer), 'sha256': sha(observer),
                    'call': 'perp_hvf_observe_instruction(cpu, syndrome)',
                    'default_off_environment': 'PERP_HVF_OBSERVE_INSN=1',
                    'possible_ptw_mmio_during_debug_translation': True,
                    'debug_translation_deadline': None,
                    'not_a_zero_side_effects_claim': True},
                'plans': plans, 'inputs': inputs,
                'compiled': False, 'linked': False, 'signed': False, 'vm_started': False}
    write_private(output / 'prepare.json', json.dumps(manifest, indent=2) + '\n')
    for name, digest in inputs.items():
        require(sha(Path(name)) == digest, 'Input changed during preparation: ' + name)
    print(json.dumps({'result': 'PASS', 'output': str(output), 'compile_plan': str(output / 'compile.sh'),
                      'sources': len(plans), 'compiled': False, 'vm_started': False}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--instruction-header', type=Path)
    parser.add_argument('--instruction-sha256')
    args = parser.parse_args()
    require(bool(args.instruction_header) == bool(args.instruction_sha256),
            'Optional instruction header requires an explicit SHA256 and vice versa')
    observer = None
    if args.instruction_header:
        observer = args.instruction_header.absolute()
        require(observer.is_file() and not observer.is_symlink() and
                sha(observer) == args.instruction_sha256,
                'Optional instruction header missing, symlinked, or SHA256 mismatch')
        text = observer.read_text()
        require('perp_hvf_observe_instruction(' in text,
                'Optional instruction header does not declare expected helper')
    records = inspect(observer is not None)
    if args.self_test:
        self_test(records)
    if args.prepare:
        require(args.output is not None, '--prepare requires --output')
        prepare(args.output, records, observer)
    else:
        require(args.output is None, '--output requires --prepare')
        print(json.dumps({'result': 'PASS', 'source_base_pin': PIN, 'self_test': args.self_test,
                          'sources': len(records), 'compiled': False, 'vm_started': False}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Preparation refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
