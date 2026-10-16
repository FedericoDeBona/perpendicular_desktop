#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prepare one isolated HVF source/object recipe; never compile or launch."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex

ROOT = Path(__file__).resolve().parents[2]
BASE_SHA = '0e23c5aeb68f12b9b4ab698782e1bb09c38c6012cf0581359adc8ed2932114e8'
SOURCE_SHA = '47808a2fb4a53db3257f4e4ffa2d84de40a5c743f4cd05218623b9a117999699'
ANCHOR = '        assert(isv);'
HOOK = '''        if (!isv && perp_hvf_stp_q_pci_hole(cpu, syndrome,
                hvf_exit->exception.virtual_address,
                hvf_exit->exception.physical_address)) {
            advance_pc = true;
            break;
        }

'''

def digest(path):
    assert path.is_file() and not path.is_symlink(), str(path)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    base = ROOT / '.tools/gpu-map-diagnostics/prepare3/prepare.json'
    assert digest(base) == BASE_SHA, 'Exact combined diagnostic manifest required'
    data = json.loads(base.read_text())
    for path, expected in data['inputs'].items():
        assert digest(Path(path)) == expected, path
    for plan in data['plans'].values():
        assert digest(Path(plan['source'])) == plan['source_sha256']
    source = Path(data['plans']['hvf']['source'])
    assert digest(source) == SOURCE_SHA
    before = source.read_text()
    include = '#include "gdbstub/enums.h"'
    assert before.count(include) == before.count(ANCHOR) == 1
    after = before.replace(include, include + '\n#include "emulate.h"', 1)
    after = after.replace(ANCHOR, HOOK + ANCHOR, 1)
    assert after.replace('\n#include "emulate.h"', '', 1).replace(HOOK, '', 1) == before
    out = Path(os.path.abspath(args.output))
    parent = ROOT / '.tools/hvf-stp-hole'
    assert out.parent == parent and out.name.startswith('prepare')
    assert not os.path.lexists(out), 'Fresh output required'
    parent.mkdir(mode=0o700, exist_ok=True)
    assert parent.resolve() == parent and parent.stat().st_uid == os.geteuid()
    assert parent.stat().st_mode & 0o777 == 0o700
    out.mkdir(mode=0o700)
    (out / 'common').mkdir(mode=0o700)
    for name in ('decode.h', 'emulate.h'):
        header = Path(__file__).parent / name
        assert not header.is_symlink()
        (out / 'common' / name).write_bytes(header.read_bytes())
    prepared = out / 'hvf.c'
    prepared.write_text(after)
    plan = data['plans']['hvf']
    old_object = plan['object']
    argv = [x.replace(str(source), str(prepared)).replace(old_object, str(out / 'hvf.c.o'))
            for x in plan['argv']]
    argv.insert(1, '-I' + str(out / 'common'))
    plan.update(source=str(prepared), source_sha256=digest(prepared),
                object=str(out / 'hvf.c.o'), argv=argv)
    data['stp_hole_emulation'] = {
        'default_off_environment': 'PERP_HVF_STP_Q_PCI_HOLE=1',
        'header_sha256': {p.name: digest(p) for p in (out / 'common').iterdir()},
        'unknown_isv_assert_retained': True,
        'instruction_debug_walk_may_dispatch_mmio': True,
        'guest_operand_debug_translation': False,
    }
    (out / 'prepare.json').write_text(json.dumps(data, indent=2) + '\n')
    (out / 'compile.sh').write_text('#!/bin/sh\nset -eu\ncd ' + shlex.quote(plan['cwd']) +
                                  '\n' + shlex.join(argv) + '\n')
    print(json.dumps({'prepared': str(out), 'source_sha256': digest(prepared),
                      'compiled': False, 'linked': False, 'vm_started': False}))

if __name__ == '__main__':
    main()
