#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Paused, diskless capset probe for a fresh native-display QEMU build."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
COMMON = ROOT / '.tools/graphics-experiment'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


fixture = load('cocoa_capset_fixture', ROOT / 'experimental/cocoa-neptune/probe.py')
recipe = load('fresh_wire1_recipe', ROOT / 'scripts/graphics-wire1-rebuild.py')
sha, require = recipe.sha, recipe.require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', required=True, type=Path)
    parser.add_argument('--com', action='store_true', help='Also exercise the real Wire1 decoder, shared textures and GPU fences')
    parser.add_argument('--label', default=None, help='Fresh receipt name; preserves previous attempts')
    args = parser.parse_args()
    base = args.profile.absolute()
    require(base.parent.resolve() == (ROOT / '.tools').resolve() and not base.is_symlink() and
            re.fullmatch(r'graphics-rebuild-[a-z0-9-]{1,64}', base.name), 'Expected fresh-build profile')
    base = base.parent.resolve() / base.name
    manifest = json.loads((base / 'build.json').read_text())
    require(manifest['plan']['output'] == str(base) and manifest['plan']['qemu_pin'] ==
            '88e5ee7ec6703662fec7b638cca74c4769e683d6', 'QEMU build profile mismatch')
    binary = base / 'candidate/qemu-system-aarch64'
    require(manifest['candidate'] == str(binary) and sha(binary) == manifest['candidate_sha256'], 'QEMU identity changed')
    renderer = Path(manifest['plan']['renderer'])
    backend = Path(manifest['plan']['backend'])
    protected = {**manifest['plan']['dependencies'], **json.loads((base / 'protected.json').read_text()),
                 str(binary): sha(binary), str(base / 'build.json'): sha(base / 'build.json')}

    def verify():
        for name, expected in protected.items():
            require(sha(Path(name)) == expected, 'Protected artifact changed: ' + name)

    verify()
    label = args.label or ('com-probe' if args.com else 'capset-probe')
    require(re.fullmatch(r'[a-z0-9-]{1,64}', label), 'Invalid receipt name')
    output = base / label; output.mkdir(mode=0o700, exist_ok=False)
    angle = COMMON / 'prefix/ANGLE.xcarchive/Products/usr/local/lib'
    libraries = ':'.join(map(str, (renderer / 'prefix/lib', backend / 'prefix/lib', base / 'prefix/lib', COMMON / 'prefix/lib', angle)))
    selected = {'DYLD_LIBRARY_PATH': libraries, 'DYLD_FALLBACK_LIBRARY_PATH': libraries,
        'DYLD_PRINT_LIBRARIES': '1', 'ANGLE_DEFAULT_PLATFORM': 'metal', 'NPT_BACKEND': 'dxmt',
        'RENDER_SERVER_EXEC_PATH': str(renderer / 'prefix/libexec/virgl_render_server'),
        'PERP_NATIVE_DISPLAY_DIRECT': '1'}
    for key in ('NPT_D3D11_LIBRARY_PATH', 'NPT_DXGI_LIBRARY_PATH', 'NPT_D3D12_LIBRARY_PATH'):
        selected[key] = str(backend / 'prefix/lib/libdxmt-native.dylib')
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('DYLD_', 'QEMU_', 'VIRGL_', 'NPT_', 'ANGLE_', 'PERP_')) and
           key not in ('RENDER_SERVER_EXEC_PATH', 'DXMT_LOG_PATH', 'LD_LIBRARY_PATH', 'LD_PRELOAD')}
    env.update(selected)
    report = {'environment': selected, 'protected_sha256': protected,
              'guest_CPU_executed': False, 'guest_disks': False, 'COM_commands_sent': False,
              'rendering_verified': False, 'source': str(Path(__file__).relative_to(ROOT)),
              'source_sha256': sha(Path(__file__))}
    peers = []; process = None; q = None
    try:
        with tempfile.TemporaryDirectory(prefix='perp-fresh-cap-', dir='/tmp') as temp, (output / 'qemu.log').open('w') as log:
            runtime = Path(temp)
            command = [str(binary), '-L', str(base / 'src/qemu/pc-bios'), '-no-user-config', '-nodefaults',
                '-name', 'Perpendicular owned fresh capset fixture', '-machine', 'virt,gic-version=3,highmem=off',
                '-accel', 'hvf,ipa-granule-size=4096' if args.com else 'hvf', '-cpu', 'host', '-m', '128M', '-smp', '1', '-S', '-nic', 'none',
                '-vga', 'none', '-display', 'cocoa,gl=es',
                '-device', 'virtio-ramfb-gl,id=freshprobe,addr=7,disable-legacy=on,neptune=on,blob=on,hostmem=256M',
                '-qmp', 'unix:' + str(runtime / 'qmp.sock') + ',server=on,wait=off',
                '-qtest', 'unix:' + str(runtime / 'qtest.sock') + ',server=on,wait=off',
                '-qtest-log', '/dev/null', '-monitor', 'none', '-serial', 'none']
            report['command'] = command
            try:
                process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                peer = fixture.headless.connect(runtime / 'qmp.sock', process); peers.append(peer)
                # QMP greeting can precede the first Cocoa/Metal initialization.
                # Allow bounded startup while preserving timeout failures.
                peer.settimeout(30)
                q = fixture.headless.QMP(peer)
                report['status'] = q.call('query-status')
                require(report['status']['status'] == 'prelaunch' and q.call('query-block') == [], 'Expected paused diskless machine')
                peer = fixture.headless.connect(runtime / 'qtest.sock', process); peers.append(peer)
                gpu = fixture.GPU(fixture.live.QTest(peer))
                info = [struct.unpack_from('<IIII', gpu.send(0x108, struct.pack('<II', i, 0)), 24) for i in range(3)]
                report['capset_info'] = info
                require([row[0] for row in info] == [1, 2, 7], 'Unexpected capset IDs')
                wire, flags = struct.unpack_from('<II', gpu.send(0x109, struct.pack('<II', 7, 0)), 24)
                report['actual_neptune_capset'] = {'wire_format_version': wire, 'flags': flags}
                require(wire == 1 and flags == 0xb6, 'Unexpected Wire1 capset')
                report['control_opcodes_sent'] = [0x108, 0x108, 0x108, 0x109]
                def owned_processes():
                    rows = []
                    for line in subprocess.check_output(['/bin/ps', '-ww', '-axo', 'pid=,ppid=,comm='], text=True).splitlines():
                        fields = line.strip().split(None, 2)
                        if len(fields) == 3:
                            rows.append({'pid': int(fields[0]), 'ppid': int(fields[1]), 'executable': fields[2]})
                    owned = {process.pid}
                    while True:
                        grown = owned | {row['pid'] for row in rows if row['ppid'] in owned}
                        if grown == owned: break
                        owned = grown
                    return [row for row in rows if row['pid'] in owned]
                report['owned_processes'] = owned_processes()
                if args.com:
                    # Reuse the existing real-virtqueue/ring fixture, selecting
                    # constants from this whole renderer's generated protocol.
                    # No renderer bootstrap/test entry point or scanout is used.
                    definitions = renderer / 'src/virglrenderer/src/neptune/neptune-protocol/npt_protocol_defs.h'
                    fixture.live.DEFS = definitions.read_text()
                    report['protocol_definitions_sha256'] = sha(definitions)
                    report['COM_commands_sent'] = True
                    # Wire1 QueryInterface registers the caller's chosen ID
                    # and replies with HRESULT only. The newer fixture expects
                    # a returned canonical ID; that field is absent here.
                    transport = renderer / 'src/virglrenderer/src/neptune/npt_transport_defs.h'
                    reply_layout = re.search(r'struct npt_cmd_com_query_interface_reply\s*\{(.*?)\};', transport.read_text(), re.S)
                    require(reply_layout and reply_layout[1].strip() == 'struct npt_reply_header header;',
                            'Expected HRESULT-only Wire1 QueryInterface reply')
                    class Wire1Neptune(fixture.live.Neptune):
                        def query(self, object_id, interface, guest_id):
                            self.call(0x20001, object_id, fixture.live.iid(interface) + struct.pack('<Q', guest_id))
                            return guest_id
                    neptune = Wire1Neptune(gpu)
                    width, height = neptune.create(64, 32)
                    for index, color in enumerate(((1, 0, 0, 1), (0, 1, 0, 1))):
                        neptune.clear(index, color, width, height)
                    neptune.signal(1)
                    deadline = time.monotonic() + 10
                    while True:
                        reply = neptune.call(fixture.live.method('ID3D11Fence', 'GetCompletedValue'), 2)
                        value = struct.unpack_from('<Q', reply, 8)[0]
                        if value >= 1: break
                        require(time.monotonic() < deadline, 'GPU fence did not complete')
                        time.sleep(.005)
                    for index, (address, pitch) in enumerate(neptune.originals):
                        pixels = gpu.t.read(address, pitch * height)
                        expected = bytes((0, 0, 255, 255) if index == 0 else (0, 255, 0, 255)) * width
                        require(all(pixels[y * pitch:y * pitch + width * 4] == expected for y in range(height)),
                                'Actual Wire1 GPU texture pixels differ')
                    neptune.overwrite(width, height)
                    report['COM_result'] = {'dimensions': [width, height], 'textures': 2,
                        'pixels_verified': 4 * width * height, 'GPU_fence_completed_value': value,
                        'actual_decoder_used': True, 'scanout_tested': False, 'Windows_tested': False}
                    report['owned_processes_after_COM'] = owned_processes()
                    require(q.call('query-status')['status'] == 'prelaunch', 'Guest CPU must remain paused')
                q.call('quit'); process.wait(timeout=5)
                require(process.returncode == 0, 'QEMU failed during quit')
                report['exit_code'] = process.returncode
            finally:
                if process is not None:
                    if process.poll() is None and q is not None:
                        try: q.call('quit'); process.wait(timeout=3)
                        except (AssertionError, OSError, subprocess.TimeoutExpired): pass
                    fixture.stop_group(process)
                for peer in peers: peer.close()
        lines = (output / 'qemu.log').read_text(errors='replace').splitlines()
        loaded = [line for line in lines if 'dyld[' in line and any(name in line for name in
                  ('libvirglrenderer', 'virgl_render_server', 'libdxmt-native', 'libEGL.dylib', 'libGLESv2.dylib'))]
        report['loaded_library_lines'] = loaded
        for name in (renderer / 'prefix/lib/libvirglrenderer.1.dylib', backend / 'prefix/lib/libdxmt-native.dylib'):
            require(any(str(name) in line for line in loaded), 'Expected loaded library absent: ' + str(name))
        require(not any(str(COMMON / 'prefix/lib/libvirglrenderer') in line or
                        str(COMMON / 'prefix/lib/libdxmt-native') in line for line in loaded), 'Different ABI library loaded')
        report['matching_server_observed'] = any(row['executable'] == str(renderer / 'prefix/libexec/virgl_render_server')
            for row in report['owned_processes'] + report.get('owned_processes_after_COM', []))
        if args.com:
            require(report['matching_server_observed'], 'Matching renderer server was not observed')
        verify(); report['result'] = 'pass'
    except BaseException as error:
        report.update(result='fail', error=str(error))
        raise
    finally:
        recipe.save(output / 'result.json', report)
    print(json.dumps({key: report[key] for key in ('result', 'actual_neptune_capset', 'matching_server_observed')} |
                     {'COM_result': report.get('COM_result'), 'receipt': str(output / 'result.json')}, indent=2))


if __name__ == '__main__':
    main()
