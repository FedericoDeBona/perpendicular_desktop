#!/usr/bin/env python3
"""Reuse the frozen diskless capset fixture with both private library dirs first."""
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


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert sha(BINARY) == EXPECTED
    source = FIXTURE.read_text()
    # Change only receipt destination and dependency selection in memory.
    # The frozen source and all existing receipts/artifacts stay untouched.
    replacements = [
        ("output = BASE / 'probe'", "output = ROOT / '.tools/graphics-wire1-backend/loader-check'"),
        ("(BASE / 'prefix/lib', OLD / 'prefix/lib', OLD / 'prefix/ANGLE.xcarchive/Products/usr/local/lib')",
         "(BASE / 'prefix/lib', ROOT / '.tools/graphics-wire1-backend/prefix/lib', OLD / 'prefix/lib', OLD / 'prefix/ANGLE.xcarchive/Products/usr/local/lib')"),
        ("selected[key] = str(OLD / 'prefix/lib/libdxmt-native.dylib')",
         "selected[key] = str(ROOT / '.tools/graphics-wire1-backend/prefix/lib/libdxmt-native.dylib')"),
    ]
    for before, after in replacements:
        assert source.count(before) == 1, 'Frozen fixture structure changed'
        source = source.replace(before, after, 1)
    scope = {'__file__': str(FIXTURE), '__name__': 'owned_wire1_loader_fixture'}
    exec(compile(source, str(FIXTURE), 'exec'), scope)
    with contextlib.redirect_stdout(io.StringIO()):
        scope['main']()
    output = BACKEND / 'loader-check'
    report = json.loads((output / 'result.json').read_text())
    loaded = report['loaded_library_lines']
    assert any(str(BINARY) in line for line in loaded), 'Actual compatible backend was not loaded'
    original = str(ROOT / '.tools/graphics-experiment/prefix/lib/libdxmt-native.dylib')
    assert not any(original in line for line in loaded), 'Original incompatible backend loaded'
    assert sha(BINARY) == EXPECTED
    report.update({'fixture_source_sha256': sha(FIXTURE), 'fixture_adjustments': replacements,
        'in_memory_fixture_sha256': hashlib.sha256(source.encode()).hexdigest(),
        'backend_sha256': EXPECTED, 'actual_compatible_backend_loaded': True,
        'actual_original_backend_loaded': False})
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
