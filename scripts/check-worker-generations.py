#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check generation ownership using the matched real native backend and GPU."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', type=Path, required=True)
    args = parser.parse_args()
    backend = args.backend.resolve()
    receipt = json.loads((backend / 'build.json').read_text())
    assert receipt['plan']['component'] == 'backend'
    assert receipt['plan']['source']['pin'] == '917b721c0f915c6524b416169fdce4427a39524f'
    library = backend / 'prefix/lib/libdxmt-native.dylib'
    assert receipt['binaries'][str(library)]['sha256'] == sha(library)
    source = ROOT / 'experimental/neptune-live'
    output = ROOT / '.build/checks/worker-generations'; output.mkdir(parents=True, exist_ok=True)
    executable = output / 'check'
    inputs = [source / 'worker-generations.inc', source / 'test-generations.cpp', Path(__file__), library,
              backend / 'prefix/include/dxmt-native/dxmt_native.h']
    protected = {str(p): sha(p) for p in inputs}
    command = ['xcrun', 'clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
        '-I'+str(backend / 'prefix/include'),
        '-isystem', str(backend / 'src/dxmt/include/native/windows'),
        '-isystem', str(backend / 'src/dxmt/include/native/directx'), str(source / 'test-generations.cpp'),
        '-L'+str(library.parent), '-ldxmt-native', '-Wl,-rpath,'+str(library.parent), '-o', str(executable)]
    subprocess.run(command, check=True)
    results = []
    for label, arguments in [('positive', []), ('negative', ['--cancel-as-ack'])]:
        result = subprocess.run([str(executable), *arguments], capture_output=True, text=True, timeout=30)
        (output / (label+'.log')).write_text(result.stdout + result.stderr)
        if label == 'positive':
            assert result.returncode == 0, result.stderr[-2000:]
            row = json.loads(result.stdout.splitlines()[-1])
            assert row['result'] == 'pass' and row['actual_native_GPU'] and row['exact_pixels'] == 14336
            assert row['backing_reuses'] == row['abandoned_allocations'] == 1
            assert row['byte_budget'] == 67108864 and row['bytes_after_cleanup'] == 0
            results.append(row)
        else:
            assert result.returncode != 0 and 'generation fixture: abandoned backing changed' in result.stderr
            results.append({'negative_control': 'cancel-as-ack', 'exit_code': result.returncode,
                            'detected': 'abandoned backing changed'})
    assert all(sha(Path(p)) == expected for p, expected in protected.items())
    report = {'result': 'pass', 'inputs': protected, 'compiler': command, 'binary_sha256': sha(executable),
              'checks': results, 'Windows_tested': False, 'decoder_tested': False}
    (output / 'result.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'result': 'pass', 'checks': results}))


if __name__ == '__main__':
    main()
