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
    assert consumer['frames'] == 40 and consumer['exact_pixels_including_immutability_recheck'] == 20196019
    assert producer['gpu_gate'] and producer['immutable'] and producer['bounded_slots'] == 2
    assert producer['stats']['occupied'] == 0
    assert producer['stats']['backing_allocations'] == producer['stats']['backing_releases'] == 4
    assert producer['stats']['backing_reuses'] == 36 and producer['stats']['cached_backings'] == 0
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
    def pool_negative(name, changed, expected):
        variant = OUTPUT / (name + '.m')
        executable = OUTPUT / name
        variant.write_text(changed)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        '-I' + str(TRANSPORT), '-I' + str(SOURCE), str(variant),
                        str(SOURCE / 'test-publisher.m'), str(obj), '-framework', 'Foundation',
                        '-framework', 'Metal', '-o', str(executable)], check=True)
        with tempfile.TemporaryDirectory(prefix='pnpool-', dir='/tmp') as runtime:
            env = dict(os.environ, PERP_PUBLISHER_TEST_RUNTIME=runtime + '/r-XXXXXX')
            failure = subprocess.run([str(executable)], text=True, capture_output=True, timeout=30, env=env)
        (OUTPUT / (name + '.log')).write_text(failure.stdout + failure.stderr)
        assert failure.returncode != 0 and expected in failure.stderr
        return {'exit_code': failure.returncode, 'failed_at': expected}
    ack_cache = '                cache_backing(capture.storage, capture.generation);'
    assert source.count(ack_cache) == 1
    no_pool = pool_negative('publisher-no-pool', source.replace(ack_cache,
        '                cache_backing(nil, capture.generation);', 1), 'steady frames did not reuse backing')
    eviction = '''        retired = pool.firstObject;
        [pool removeObjectAtIndex:0];
        atomic_fetch_sub(&cached_backings, 1);'''
    assert source.count(eviction) == 1
    no_eviction = pool_negative('publisher-no-pool-eviction', source.replace(eviction,
        '        /* negative control: retain mismatched idle storage */', 1),
        'resize cache did not replace idle mismatch')
    # Deliberately unsafe PRIVATE mutant: give unacknowledged storage to the
    # next connection. The independent old consumer must detect its overwrite.
    clear = '    clear_pool();'
    assert source.count(clear) == 1
    unsafe = source.replace(clear, clear + '''
    for (PNDCapture *capture in _captures) {
        capture.storage.generation = self->_generation + 1;
        cache_backing(capture.storage, 0);
    }''', 1)
    unsafe_pool = pool_negative('publisher-unsafe-reconnect-pool', unsafe,
        'unacknowledged old snapshot changed after reconnect')
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
    external = OUTPUT / 'publisher-external-check'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(TRANSPORT), '-I' + str(SOURCE), str(SOURCE / 'publisher.m'),
                    str(SOURCE / 'test-publisher-external.m'), str(obj), '-framework', 'Foundation',
                    '-framework', 'Metal', '-o', str(external)], check=True)
    external_result = subprocess.run([str(external)], text=True, capture_output=True, timeout=30)
    (OUTPUT / 'external.log').write_text(external_result.stdout + external_result.stderr)
    if external_result.returncode:
        raise RuntimeError((OUTPUT / 'external.log').read_text())
    external_rows = [json.loads(line) for line in external_result.stdout.splitlines()]
    reader, provider = external_rows
    assert reader['external_consumer'] == provider['external_producer'] == 'pass'
    assert reader['exact_pixels'] == 8192 and reader['connections'] == 2
    assert (provider['provider_acked'], provider['provider_abandoned'], provider['provider_released']) == (2, 1, 3)
    assert provider['stats']['external_submissions'] == 3 and provider['stats']['external_acked'] == 2
    assert provider['stats']['external_abandoned'] == 1 and provider['stats']['occupied'] == 0
    assert provider['stats']['backing_allocations'] == provider['stats']['mappings'] == 0
    assert provider['stats']['allocations'] == provider['stats']['releases'] == 3
    with tempfile.TemporaryDirectory(prefix='pnext-negative-', dir='/tmp') as runtime:
        external_negative = subprocess.run([str(external)], text=True, capture_output=True, timeout=30,
            env=dict(os.environ, PERP_EXTERNAL_UNSAFE_REUSE='1', PERP_EXTERNAL_TEST_RUNTIME=runtime + '/r-XXXXXX'))
    (OUTPUT / 'external-unsafe-reuse.log').write_text(external_negative.stdout + external_negative.stderr)
    assert external_negative.returncode != 0 and 'external abandoned backing was rewritten' in external_negative.stderr
    paths = [SOURCE / name for name in ('publisher.h', 'publisher.m', 'test-publisher.m', 'test-publisher-refresh.m', 'test-publisher-region.m', 'test-publisher-external.m', 'test-publisher.py')]
    paths += [TRANSPORT / name for name in ('ndt.h', 'ndt.c')]
    receipt = {'result': 'pass', 'actual_gpu': True, 'processes': 2, 'guest_or_disks': False,
               'observations': rows,
               'pool_causal_negatives': {'no_reuse': no_pool, 'no_resize_eviction': no_eviction,
                                        'reuse_without_ack_after_disconnect': unsafe_pool},
               'reconnect_observations': refresh_rows,
               'region_observations': region_rows, 'direct_opt_in': opt_in,
               'external_ready_lease_observations': external_rows,
               'external_causal_negative': {'unsafe_provider_reuse': True, 'exit_code': external_negative.returncode,
                   'failed_at': 'external abandoned backing was rewritten'},
               'crop_causal_negative': {'zero_origin': True, 'exit_code': bad_region.returncode,
                                        'failed_at': 'exact nonzero crop pixel mismatch'},
               'causal_negative': {'accept_signal_removed': True, 'exit_code': negative_result.returncode,
                                   'failed_at': 'initial refresh was not requested'},
               'inputs': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    (OUTPUT / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
