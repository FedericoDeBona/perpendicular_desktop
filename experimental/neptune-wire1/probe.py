#!/usr/bin/env python3
"""Owned paused HVF GET_CAPSET handshake. No Neptune COM commands or guest disk."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / '.tools/graphics-wire1'
OLD = ROOT / '.tools/graphics-experiment'
spec = importlib.util.spec_from_file_location('common_virtio_fixture', ROOT / 'experimental/cocoa-neptune/probe.py')
common = importlib.util.module_from_spec(spec);spec.loader.exec_module(common)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, default=BASE)
    args = parser.parse_args()
    base = args.profile.absolute()
    assert base.parent == ROOT / '.tools' and re.fullmatch(r'graphics-wire1(?:-[a-z0-9-]{1,48})?', base.name)
    output = base / 'probe'
    output.mkdir(mode=0o700, exist_ok=False)
    libraries = ':'.join(map(str, (base / 'prefix/lib', OLD / 'prefix/lib', OLD / 'prefix/ANGLE.xcarchive/Products/usr/local/lib')))
    selected = {'DYLD_LIBRARY_PATH': libraries, 'DYLD_FALLBACK_LIBRARY_PATH': libraries,
        'DYLD_PRINT_LIBRARIES': '1', 'ANGLE_DEFAULT_PLATFORM': 'metal', 'NPT_BACKEND': 'dxmt',
        'RENDER_SERVER_EXEC_PATH': str(base / 'prefix/libexec/virgl_render_server')}
    for key in ('NPT_D3D11_LIBRARY_PATH', 'NPT_DXGI_LIBRARY_PATH', 'NPT_D3D12_LIBRARY_PATH'):
        selected[key] = str(OLD / 'prefix/lib/libdxmt-native.dylib')
    env = {key: value for key, value in os.environ.items() if not key.startswith(('DYLD_', 'NPT_', 'ANGLE_', 'PERP_', 'VIRGL_', 'QEMU_'))}
    env.pop('PERPENDICULAR_GPU_COMMAND_DIAGNOSTICS', None)
    env.update(selected)
    before = {str(p.relative_to(ROOT)): sha(p) for p in (OLD / 'prefix/bin/qemu-system-aarch64',
        OLD / 'prefix/lib/libvirglrenderer.1.dylib', OLD / 'prefix/libexec/virgl_render_server',
        OLD / 'prefix/lib/libdxmt-native.dylib', base / 'prefix/lib/libvirglrenderer.1.dylib',
        base / 'prefix/libexec/virgl_render_server')}
    report = {'environment': selected, 'protected_sha256': before, 'guest_disks': False,
        'guest_CPU_executed': False, 'COM_commands_sent': False, 'rendering_verified': False}
    peers = [];process = None;q = None
    with tempfile.TemporaryDirectory(prefix='perp-wire1-', dir='/tmp') as temp, (output / 'qemu.log').open('w') as log:
        runtime = Path(temp)
        command = [str(OLD / 'prefix/bin/qemu-system-aarch64'), '-L', str(OLD / 'prefix/share/qemu'),
            '-no-user-config', '-nodefaults', '-name', 'Perpendicular owned Wire1 handshake',
            '-machine', 'virt,gic-version=3,highmem=off', '-accel', 'hvf', '-cpu', 'host', '-m', '128M', '-smp', '1',
            '-S', '-nic', 'none', '-vga', 'none', '-display', 'cocoa,gl=es',
            '-device', 'virtio-ramfb-gl,id=wire1probe,addr=7,disable-legacy=on,neptune=on,blob=on,hostmem=256M',
            '-qmp', 'unix:' + str(runtime / 'qmp.sock') + ',server=on,wait=off',
            '-qtest', 'unix:' + str(runtime / 'qtest.sock') + ',server=on,wait=off', '-qtest-log', '/dev/null',
            '-monitor', 'none', '-serial', 'none']
        report['command'] = command
        try:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            peer = common.headless.connect(runtime / 'qmp.sock', process);peers.append(peer);q = common.headless.QMP(peer)
            report['status'] = q.call('query-status')
            assert report['status']['status'] == 'prelaunch' and q.call('query-block') == []
            peer = common.headless.connect(runtime / 'qtest.sock', process);peers.append(peer)
            gpu = common.GPU(common.live.QTest(peer))
            info = []
            for index in range(3):
                response = gpu.send(0x108, struct.pack('<II', index, 0))
                info.append(struct.unpack_from('<IIII', response, 24))
            report['capset_info'] = info
            assert [item[0] for item in info] == [1, 2, 7]
            capset = gpu.send(0x109, struct.pack('<II', 7, 0))
            wire, flags = struct.unpack_from('<II', capset, 24)
            report['actual_neptune_capset'] = {'wire_format_version': wire, 'flags': flags}
            assert wire == 1 and flags == 0xb6
            report['control_opcodes_sent'] = [0x108, 0x108, 0x108, 0x109]
            q.call('quit');process.wait(timeout=5)
            assert process.returncode == 0
            report['exit_code'] = process.returncode
        finally:
            if process is not None:
                if process.poll() is None and q is not None:
                    try:q.call('quit');process.wait(timeout=3)
                    except BaseException:pass
                common.stop_group(process)
            for peer in peers:peer.close()
    lines = (output / 'qemu.log').read_text(errors='replace').splitlines()
    expected = str(base / 'prefix/lib/libvirglrenderer.1.dylib')
    report['loaded_library_lines'] = [line for line in lines if 'dyld[' in line and any(s in line for s in ('libvirglrenderer', 'virgl_render_server', 'libdxmt-native', 'libEGL.dylib', 'libGLESv2.dylib'))]
    assert any(expected in line for line in report['loaded_library_lines']), 'Actual Wire1 dylib was not observed'
    old = str(OLD / 'prefix/lib/libvirglrenderer.1.dylib')
    assert not any(old in line for line in report['loaded_library_lines']), 'Wire2 library unexpectedly loaded'
    report['matching_server_observed'] = any(str(base / 'prefix/libexec/virgl_render_server') in line for line in report['loaded_library_lines'])
    for name, value in before.items():assert sha(ROOT / name) == value, name
    report['result'] = 'pass'
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
