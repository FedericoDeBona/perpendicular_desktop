#!/usr/bin/env python3
"""Paused diskless HVF blob mapping; optional default-granule negative control."""
import argparse
import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'experimental/neptune-wire1/probe.py'
BACKEND = ROOT / '.tools/graphics-wire1-backend'
BINARY = BACKEND / 'prefix/lib/libdxmt-native.dylib'
EXPECTED = '4fade33095e08b341ceae2a35ee5dcebb0c452eb6fcc52f562df6f0d223b0da9'

MAPPING = '''
            # VirtIO commands only: generic anonymous Neptune blob_id=0
            # resource creation. No SUBMIT_3D, COM, ring or decoder packets.
            gpu.send(0x200, struct.pack('<II', 9, 7) + b'ipa-check' + b'\\0' * 55)
            report['control_opcodes_sent'].append(0x200)
            report['host_visible_regions'] = []
            def create_map(resource, size, offset):
                gpu.send(0x10c, struct.pack('<IIIIQQ', resource, 2, 1, 0, 0, size))
                gpu.send(0x208, struct.pack('<IIQ', resource, 0, offset))
                report['control_opcodes_sent'].extend((0x10c, 0x208))
                address = gpu.bar[4] + offset
                report['host_visible_regions'].append({'resource': resource, 'size': size, 'offset': offset, 'guest_address': address})
                return address
            small = create_map(41, 0x1000, 0x4001000)
            gpu.t.store(small, 0x11223344)
            gpu.t.store(small + 0xffc, 0x55667788)
            assert gpu.t.load(small) == 0x11223344 and gpu.t.load(small + 0xffc) == 0x55667788
            first = create_map(42, 0x201000, 0)
            second = create_map(43, 0x100000, 0x201000)
            gpu.t.store(first + 0x200ffc, 0x13579bdf)
            gpu.t.store(second, 0x2468ace0)
            gpu.t.store(second + 0xffffc, 0x0badc0de)
            assert gpu.t.load(first + 0x200ffc) == 0x13579bdf
            assert gpu.t.load(second) == 0x2468ace0 and gpu.t.load(second + 0xffffc) == 0x0badc0de
            report['separate_backings_boundary_values_verified_via_qtest'] = True
            report['memory_tree_before_unmap'] = q.call('human-monitor-command', {'command-line': 'info mtree -f'})
            # Keep the three regions live until QMP quit. Explicit guest
            # UNREF after UNMAP stalled in the first paused probe; that
            # failure is retained separately, not hidden as successful cleanup.
            assert q.call('query-status')['status'] == 'prelaunch'
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control-default', action='store_true', help='Owned paused negative control: expect HVF alignment rejection warnings')
    args = parser.parse_args()
    assert sha(BINARY) == EXPECTED
    label = 'ipa-check-default-maponly' if args.control_default else 'ipa-check-4k-maponly'
    source = FIXTURE.read_text()
    marker = "            report['control_opcodes_sent'] = [0x108, 0x108, 0x108, 0x109]\n"
    replacements = [
        ("output = BASE / 'probe'", "output = ROOT / '.tools/graphics-wire1-backend/" + label + "'"),
        ("(BASE / 'prefix/lib', OLD / 'prefix/lib', OLD / 'prefix/ANGLE.xcarchive/Products/usr/local/lib')",
         "(BASE / 'prefix/lib', ROOT / '.tools/graphics-wire1-backend/prefix/lib', OLD / 'prefix/lib', OLD / 'prefix/ANGLE.xcarchive/Products/usr/local/lib')"),
        ("selected[key] = str(OLD / 'prefix/lib/libdxmt-native.dylib')",
         "selected[key] = str(ROOT / '.tools/graphics-wire1-backend/prefix/lib/libdxmt-native.dylib')"),
        (marker, marker + MAPPING),
    ]
    if not args.control_default:
        replacements.append(("'-accel', 'hvf', '-cpu'", "'-accel', 'hvf,ipa-granule-size=4096', '-cpu'"))
    for before, after in replacements:
        assert source.count(before) == 1, 'Frozen fixture structure changed'
        source = source.replace(before, after, 1)
    scope = {'__file__': str(FIXTURE), '__name__': 'owned_wire1_ipa_fixture'}
    exec(compile(source, str(FIXTURE), 'exec'), scope)
    with contextlib.redirect_stdout(io.StringIO()):
        scope['main']()
    output = BACKEND / label
    report = json.loads((output / 'result.json').read_text())
    loaded = report['loaded_library_lines']
    old = str(ROOT / '.tools/graphics-experiment/prefix/lib/libdxmt-native.dylib')
    alignment = [line for line in (output / 'qemu.log').read_text(errors='replace').splitlines()
        if 'Cannot add ' in line and 'not aligned to page size' in line]
    report.update({'fixture_source_sha256': sha(FIXTURE),
        'in_memory_fixture_sha256': hashlib.sha256(source.encode()).hexdigest(),
        'backend_sha256': EXPECTED, 'alignment_warnings': alignment,
        'explicit_ipa_granule_bytes': None if args.control_default else 4096,
        'control_default_expected_rejection': args.control_default,
        'HVF_mapping_proved_by_guest_CPU': False,
        'actual_compatible_backend_loaded': any(str(BINARY) in line for line in loaded),
        'actual_original_backend_loaded': any(old in line for line in loaded)})
    report['result'] = 'validation_pending'
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    assert report['actual_compatible_backend_loaded'] and not report['actual_original_backend_loaded']
    assert sha(BINARY) == EXPECTED
    assert bool(alignment) == args.control_default, 'Unexpected HVF mapping alignment result'
    report['result'] = 'pass'
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'memory_tree_before_unmap'}, indent=2))


if __name__ == '__main__':
    main()
