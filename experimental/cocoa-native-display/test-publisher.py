#!/usr/bin/env python3
"""Build/run only the two-process Metal publisher fixture; no VM or app launch."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent
TRANSPORT = ROOT / 'experimental/native-display-transport'
OUTPUT = ROOT / '.build/checks/native-publisher'


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    obj = OUTPUT / 'ndt.o'
    binary = OUTPUT / 'publisher-check'
    subprocess.run(['xcrun', 'clang', '-std=c17', '-Wall', '-Wextra', '-Werror',
                    '-c', str(TRANSPORT / 'ndt.c'), '-o', str(obj)], check=True)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(TRANSPORT), '-I' + str(SOURCE), str(SOURCE / 'publisher.m'),
                    str(SOURCE / 'test-publisher.m'), str(obj), '-framework', 'Foundation',
                    '-framework', 'Metal', '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
    log = OUTPUT / 'result.log'
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(log.read_text())
    rows = [json.loads(line) for line in result.stdout.splitlines()]
    consumer, producer = rows
    assert consumer['consumer'] == producer['producer'] == 'pass'
    assert consumer['exact_pixels_including_immutability_recheck'] == 1927421
    assert producer['gpu_gate'] and producer['immutable'] and producer['bounded_slots'] == 2
    assert producer['stats']['occupied'] == 0
    refresh = OUTPUT / 'publisher-refresh-check'
    def compile_refresh(publisher, destination):
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        '-I' + str(TRANSPORT), '-I' + str(SOURCE), str(publisher),
                        str(SOURCE / 'test-publisher-refresh.m'), str(obj), '-framework', 'Foundation',
                        '-framework', 'Metal', '-o', str(destination)], check=True)
    compile_refresh(SOURCE / 'publisher.m', refresh)
    refresh_result = subprocess.run([str(refresh)], text=True, capture_output=True, timeout=30)
    (OUTPUT / 'refresh.log').write_text(refresh_result.stdout + refresh_result.stderr)
    if refresh_result.returncode:
        raise RuntimeError((OUTPUT / 'refresh.log').read_text())
    refresh_rows = [json.loads(line) for line in refresh_result.stdout.splitlines()]
    assert refresh_rows[0]['refresh_consumer'] == refresh_rows[1]['refresh_producer'] == 'pass'
    assert refresh_rows[0]['connections'] == 3 and refresh_rows[0]['static_pixels'] == 4096
    assert refresh_rows[1]['guest_updates_after_connect'] == 0
    assert refresh_rows[1]['stats']['occupied'] == 0
    # Remove exactly the production accept signal in a PRIVATE source copy.
    # The same real connection/GPU fixture must fail its first-refresh assertion.
    source = (SOURCE / 'publisher.m').read_text()
    signal = '        atomic_store(&refresh_generation, _generation);'
    assert source.count(signal) == 1
    negative_source = OUTPUT / 'publisher-no-accept-refresh.m'
    negative_source.write_text(source.replace(signal, '        /* negative control: old accept behavior */', 1))
    negative = OUTPUT / 'publisher-refresh-negative'
    compile_refresh(negative_source, negative)
    with tempfile.TemporaryDirectory(prefix='pnref-', dir='/tmp') as runtime:
        env = dict(os.environ, PERP_REFRESH_TEST_RUNTIME=runtime + '/r-XXXXXX')
        negative_result = subprocess.run([str(negative)], text=True, capture_output=True, timeout=30, env=env)
    (OUTPUT / 'refresh-negative.log').write_text(negative_result.stdout + negative_result.stderr)
    assert negative_result.returncode != 0 and 'initial refresh was not requested' in negative_result.stderr
    region = OUTPUT / 'publisher-region-check'
    def compile_region(publisher, destination):
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        '-I' + str(TRANSPORT), '-I' + str(SOURCE), str(publisher),
                        str(SOURCE / 'test-publisher-region.m'), str(obj), '-framework', 'Foundation',
                        '-framework', 'Metal', '-o', str(destination)], check=True)
    compile_region(SOURCE / 'publisher.m', region)
    region_result = subprocess.run([str(region)], text=True, capture_output=True, timeout=30)
    (OUTPUT / 'region.log').write_text(region_result.stdout + region_result.stderr)
    if region_result.returncode:
        raise RuntimeError((OUTPUT / 'region.log').read_text())
    region_rows = [json.loads(line) for line in region_result.stdout.splitlines()]
    assert region_rows[0]['region_consumer'] == region_rows[1]['region_producer'] == 'pass'
    assert region_rows[0]['exact_crop_pixels'] == 56 and region_rows[1]['gpu_gate'] and region_rows[1]['immutable']
    assert region_rows[1]['stats']['occupied'] == 0
    # Causal crop negative: copying from (0,0) must fail the exact pixel check.
    origin = 'sourceLevel:0 sourceOrigin:origin\n'
    assert source.count(origin) == 1
    bad_crop = OUTPUT / 'publisher-zero-origin.m'
    bad_crop.write_text(source.replace(origin, 'sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)\n', 1))
    region_negative = OUTPUT / 'publisher-region-negative'
    compile_region(bad_crop, region_negative)
    with tempfile.TemporaryDirectory(prefix='pnreg-', dir='/tmp') as runtime:
        env = dict(os.environ, PERP_REGION_TEST_RUNTIME=runtime + '/r-XXXXXX')
        bad_region = subprocess.run([str(region_negative)], text=True, capture_output=True, timeout=30, env=env)
    (OUTPUT / 'region-negative.log').write_text(bad_region.stdout + bad_region.stderr)
    assert bad_region.returncode != 0 and 'exact nonzero crop pixel mismatch' in bad_region.stderr
    opt_in = []
    for value in (None, '0', 'true', '1'):
        env = dict(os.environ)
        env.pop('PERP_NATIVE_DISPLAY_DIRECT', None)
        if value is not None:
            env['PERP_NATIVE_DISPLAY_DIRECT'] = value
        flag = subprocess.run([str(region), '--direct-flag'], env=env, text=True, capture_output=True, check=True, timeout=5)
        assert json.loads(flag.stdout)['direct'] == (value == '1')
        opt_in.append({'value': value, 'direct': value == '1'})
    paths = [SOURCE / name for name in ('publisher.h', 'publisher.m', 'test-publisher.m', 'test-publisher-refresh.m', 'test-publisher-region.m', 'test-publisher.py')]
    paths += [TRANSPORT / name for name in ('ndt.h', 'ndt.c')]
    receipt = {'result': 'pass', 'actual_gpu': True, 'processes': 2, 'guest_or_disks': False,
               'observations': rows,
               'reconnect_observations': refresh_rows,
               'region_observations': region_rows, 'direct_opt_in': opt_in,
               'crop_causal_negative': {'zero_origin': True, 'exit_code': bad_region.returncode,
                                        'failed_at': 'exact nonzero crop pixel mismatch'},
               'causal_negative': {'accept_signal_removed': True, 'exit_code': negative_result.returncode,
                                   'failed_at': 'initial refresh was not requested'},
               'inputs': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    (OUTPUT / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
