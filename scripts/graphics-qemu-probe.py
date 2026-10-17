#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Paused, diskless capset probe for a fresh native-display QEMU build."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import select
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
    parser.add_argument('--native', action='store_true', help='Also verify real scanout snapshots with a Metal receiver')
    parser.add_argument('--swift-receiver', action='store_true', help='Use the app production Swift receiver/renderer; implies --native')
    parser.add_argument('--sync-renderer', type=Path, help='Private matched synchronization renderer; capture remains disabled in this probe')
    parser.add_argument('--sync-qemu', type=Path, help='Matched private QEMU overlay; enables actual automatic producer synchronization')
    parser.add_argument('--headless', action='store_true', help='Use the opt-in native Metal pbuffer backend instead of Cocoa')
    parser.add_argument('--packaged-runtime', type=Path, help='Verify the app Native3D binaries/libraries after relocation; requires --headless')
    parser.add_argument('--withhold-native-update', action='store_true', help='Negative control: omit the green update; --native must fail')
    parser.add_argument('--withhold-producer-token', action='store_true', help='Negative control: real GPU work finishes but the worker ready token is withheld')
    parser.add_argument('--source-pressure', action='store_true', help='Keep twelve additional unselected shared sources alive during native presentation')
    parser.add_argument('--import-input', action='store_true', help='Read a texture from a second renderer worker into the selected output')
    parser.add_argument('--boot-flush', action='store_true', help='Flush a real legacy 2D scanout before the first native selection')
    parser.add_argument('--owned-input', action='store_true', help='Reopen a never-granted owned source as input while an independent output is presented')
    parser.add_argument('--import-selected-output', action='store_true', help='Negative control: import the selected output while its old image is retained')
    parser.add_argument('--import-owned-output', action='store_true', help='Negative control: reject an owned output reopen without the proxy denial handshake')
    parser.add_argument('--reexport-input', action='store_true', help='Negative control: an imported texture reexport must not become an exclusive output')
    parser.add_argument('--label', default=None, help='Fresh receipt name; preserves previous attempts')
    args = parser.parse_args()
    args.import_input = args.import_input or args.reexport_input
    args.native = args.native or args.swift_receiver
    require(not args.withhold_native_update or args.native, 'Withheld-update control requires --native')
    require(not args.withhold_producer_token or args.sync_qemu, 'Withheld producer token requires automatic synchronization')
    require(not args.headless or args.sync_qemu,'Native headless requires the synchronization QEMU overlay')
    require(not args.packaged_runtime or args.headless,'Packaged runtime qualification requires --headless')
    require(not (args.withhold_native_update and args.withhold_producer_token), 'Select one causal negative control')
    args.com = args.com or args.native
    require(not args.source_pressure or args.sync_qemu, 'Source pressure requires the synchronization path')
    require(not (args.import_input or args.owned_input or args.import_selected_output or args.import_owned_output) or args.sync_qemu, 'Shared imports require the synchronization path')
    require(not args.import_owned_output or not (args.import_selected_output or args.withhold_native_update or args.withhold_producer_token),
        'Select one causal negative control')
    require(not args.reexport_input or not (args.import_selected_output or args.import_owned_output or args.withhold_native_update or args.withhold_producer_token),
        'Select one causal negative control')
    require(not args.import_selected_output or not (args.withhold_native_update or args.withhold_producer_token),
        'Select one causal negative control')
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
    host_version=2
    if args.sync_qemu:
        require(args.native, 'Automatic synchronization probe requires a native receiver')
        profile = args.sync_qemu.absolute()
        require(profile.parent.resolve() == (ROOT / '.tools').resolve() and not profile.is_symlink() and
                re.fullmatch(r'graphics-rebuild-[a-z0-9-]{1,64}', profile.name), 'Expected private QEMU sync profile')
        profile = profile.parent.resolve() / profile.name
        overlay = json.loads((profile / 'build.json').read_text())
        require(not args.headless or overlay.get('native_headless_available'),'QEMU overlay has no native headless backend')
        require(overlay['qemu_profile'] == str(base), 'QEMU overlay base mismatch')
        if args.sync_renderer:
            require(str(args.sync_renderer.resolve()) == overlay['sync_renderer'], 'Synchronization renderer mismatch')
        else: args.sync_renderer = Path(overlay['sync_renderer'])
        binary = profile / 'qemu-system-aarch64'
        require(overlay['candidate'] == str(binary) and sha(binary) == overlay['candidate_sha256'], 'QEMU overlay identity changed')
        protected.update(json.loads((profile / 'protected.json').read_text()))
        protected[str(binary)] = sha(binary); protected[str(profile / 'build.json')] = sha(profile / 'build.json')
    if args.sync_renderer:
        sync = args.sync_renderer.absolute()
        require(sync.parent.resolve() == (ROOT / '.tools').resolve() and not sync.is_symlink() and
                re.fullmatch(r'graphics-rebuild-[a-z0-9-]{1,64}', sync.name), 'Expected private synchronization profile')
        sync = sync.parent.resolve() / sync.name
        receipt = json.loads((sync / 'build.json').read_text())
        plan = json.loads((sync / 'plan.json').read_text())
        require(sha(sync / 'plan.json') == receipt['plan_sha256'] and
                sha(sync / 'source-files.json') == receipt['source_inventory_sha256'], 'Synchronization build identity changed')
        require(plan['renderer'] == str(renderer) and plan['backend'] == str(backend) and
                plan['source_pin'] == recipe.PINS['renderer']['pin'] and plan['backend_pin'] == recipe.PINS['backend']['pin'] and
                plan['host_transport_version'] in (2,3) and plan['guest_wire_version'] == 1, 'Matched synchronization pair required')
        host_version=plan['host_transport_version']
        if args.sync_qemu: require(overlay.get('host_transport_version',2)==host_version,'QEMU host transport mismatch')
        for path in (sync / 'prefix/lib/libvirglrenderer.1.dylib', sync / 'prefix/libexec/virgl_render_server'):
            require(sha(path) == receipt['binaries'][str(path)], 'Synchronization binary changed')
            protected[str(path)] = sha(path)
        protected.update(json.loads((sync / 'protected.json').read_text()))
        protected[str(sync / 'build.json')] = sha(sync / 'build.json')
        renderer = sync

    expected_renderer=renderer / 'prefix/lib/libvirglrenderer.1.dylib'
    expected_backend=backend / 'prefix/lib/libdxmt-native.dylib'
    expected_server=renderer / 'prefix/libexec/virgl_render_server'
    packaged=None
    if args.packaged_runtime:
        packaged=args.packaged_runtime.resolve(strict=True)
        require(packaged.is_relative_to(ROOT) and packaged.name=='Native3D','Expected a private app Native3D directory')
        metadata=json.loads((packaged / 'runtime.json').read_text())
        require(metadata['schema']==1 and metadata['source_receipt_sha256']==sha(profile / 'build.json') and
            metadata['host_transport_version']==3 and metadata['guest_wire_version']==1,'Packaged source/ABI mismatch')
        for name,digest in metadata['files'].items():
            path=packaged / name
            require(path.resolve().is_relative_to(packaged) and sha(path)==digest,'Packaged code changed: '+name)
            protected[str(path)]=digest
        protected[str(packaged / 'runtime.json')]=sha(packaged / 'runtime.json')
        binary=packaged / 'bin/qemu-system-aarch64'
        expected_renderer=packaged / 'lib/libvirglrenderer.1.dylib'
        expected_backend=packaged / 'lib/libdxmt-native.dylib'
        expected_server=packaged / 'bin/virgl_render_server'

    def verify():
        for name, expected in protected.items():
            require(sha(Path(name)) == expected, 'Protected artifact changed: ' + name)

    verify()
    label = args.label or ('native-probe' if args.native else 'com-probe' if args.com else 'capset-probe')
    require(re.fullmatch(r'[a-z0-9-]{1,64}', label), 'Invalid receipt name')
    output = base / label; output.mkdir(mode=0o700, exist_ok=False)
    angle = COMMON / 'prefix/ANGLE.xcarchive/Products/usr/local/lib'
    libraries = ':'.join(map(str, (renderer / 'prefix/lib', backend / 'prefix/lib', base / 'prefix/lib', COMMON / 'prefix/lib', angle)))
    if packaged:libraries=str(packaged / 'lib')
    selected = {'DYLD_LIBRARY_PATH': libraries, 'DYLD_FALLBACK_LIBRARY_PATH': libraries,
        'DYLD_PRINT_LIBRARIES': '1', 'ANGLE_DEFAULT_PLATFORM': 'metal', 'NPT_BACKEND': 'dxmt',
        'RENDER_SERVER_EXEC_PATH': str(expected_server),
        'PERP_NATIVE_DISPLAY_DIRECT': '1'}
    if args.sync_qemu: selected['PERP_NEPTUNE_SCANOUT_BROKER'] = '1'
    if args.withhold_producer_token: selected['PERP_LIVE_TEST_WITHHOLD'] = '1'
    for key in ('NPT_D3D11_LIBRARY_PATH', 'NPT_DXGI_LIBRARY_PATH', 'NPT_D3D12_LIBRARY_PATH'):
        selected[key] = str(expected_backend)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('DYLD_', 'QEMU_', 'VIRGL_', 'NPT_', 'ANGLE_', 'PERP_')) and
           key not in ('RENDER_SERVER_EXEC_PATH', 'DXMT_LOG_PATH', 'LD_LIBRARY_PATH', 'LD_PRELOAD')}
    env.update(selected)
    report = {'environment': selected, 'protected_sha256': protected,
              'guest_CPU_executed': False, 'guest_disks': False, 'COM_commands_sent': False,
              'rendering_verified': False, 'source': str(Path(__file__).relative_to(ROOT)),
              'source_sha256': sha(Path(__file__))}
    if args.sync_renderer:
        report['synchronization_extension'] = {'renderer': str(renderer), 'capture_enabled': bool(args.sync_qemu),
            'scope': 'Actual worker copy-before-Signal and QEMU broker' if args.sync_qemu else
                     'Ordinary decoder/backend regression only; copy-before-Signal is not exercised'}
    peers = []; process = None; q = None; receiver = None; receiver_log = None
    if args.native:
        source = ROOT / 'experimental/cocoa-native-display/qemu-receiver.m'
        transport = ROOT / 'experimental/native-display-transport'
        compiler_env = dict(env, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
        with (output / 'receiver-compile.log').open('w') as log:
            subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-macosx14.0', '-std=c17', '-Wall', '-Wextra', '-Werror', '-c', str(transport / 'ndt.c'),
                '-o', str(output / 'ndt.o')], env=compiler_env, stdout=log, stderr=subprocess.STDOUT, check=True)
            if args.swift_receiver:
                receiver_sources = [ROOT / 'macos/PerpendicularDesktop' / name for name in
                    ('NativeDisplayEndpoint.swift', 'VMDisplayPresenter.swift', 'NativeDisplayConnection.swift')]
                receiver_sources.append(ROOT / 'macos/Tests/QEMUNativeReceiverCheck.swift')
                subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors',
                    '-target', 'arm64-apple-macosx14.0', '-D', 'PERPENDICULAR_NATIVE_DISPLAY', '-import-objc-header',
                    str(transport / 'ndt.h'), *map(str, receiver_sources), str(output / 'ndt.o'),
                    '-o', str(output / 'metal-receiver')], env=compiler_env, stdout=log, stderr=subprocess.STDOUT, check=True)
            else:
                receiver_sources = [source]
                subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(transport), str(source), str(output / 'ndt.o'), '-framework', 'Foundation',
                    '-framework', 'Metal', '-o', str(output / 'metal-receiver')], env=compiler_env, stdout=log,
                    stderr=subprocess.STDOUT, check=True)
        report['receiver_inputs'] = {str(p.relative_to(ROOT)): sha(p) for p in (*receiver_sources, transport / 'ndt.h', transport / 'ndt.c')}
        report['receiver_sha256'] = sha(output / 'metal-receiver')
    try:
        with tempfile.TemporaryDirectory(prefix='perp-fresh-cap-', dir='/tmp') as temp, (output / 'qemu.log').open('w') as log:
            runtime = Path(temp)
            if args.native:
                env.update(PERP_NATIVE_DISPLAY_DIR=str(runtime),
                           PERP_NATIVE_DISPLAY_SESSION='f123456789abcdef123456789abcdef1')
            command = [str(binary), '-L', str(base / 'src/qemu/pc-bios'), '-no-user-config', '-nodefaults',
                '-name', 'Perpendicular owned fresh capset fixture', '-machine', 'virt,gic-version=3,highmem=off',
                '-accel', 'hvf,ipa-granule-size=4096' if args.com else 'hvf', '-cpu', 'host', '-m', '128M', '-smp', '1', '-S', '-nic', 'none',
                '-vga', 'none', '-display', 'egl-headless,gl=es' if args.headless else 'cocoa,gl=es',
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
                def headless_stats():
                    return json.loads(q.call('qom-get',{'path':'/machine/peripheral/freshprobe/virtio-backend','property':'perp-headless-stats'}))
                if args.headless:
                    state=headless_stats();report['headless_start']=state
                    require(state['initialized'] and not state['cocoa_application'] and state['cocoa_windows']==0 and
                        state['init_context_released'] and state['pbuffer_width']==state['pbuffer_height']==1 and
                        state['root_ES_version']==3 and not state['CPU_readback_supported'],'Native headless initialization differs')
                peer = fixture.headless.connect(runtime / 'qtest.sock', process); peers.append(peer)
                gpu = fixture.GPU(fixture.live.QTest(peer))
                info = [struct.unpack_from('<IIII', gpu.send(0x108, struct.pack('<II', i, 0)), 24) for i in range(3)]
                report['capset_info'] = info
                require([row[0] for row in info] == [1, 2, 7], 'Unexpected capset IDs')
                wire, flags = struct.unpack_from('<II', gpu.send(0x109, struct.pack('<II', 7, 0)), 24)
                report['actual_neptune_capset'] = {'wire_format_version': wire, 'flags': flags}
                require(wire == 1 and flags == 0xb6, 'Unexpected Wire1 capset')
                report['control_opcodes_sent'] = [0x108, 0x108, 0x108, 0x109]
                if args.boot_flush:
                    require(args.sync_qemu, 'Boot flush requires automatic synchronization')
                    gpu.send(0x101, struct.pack('<4I', 2, 1, 64, 32), context=0)
                    gpu.send(0x103, struct.pack('<6I', 0, 0, 64, 32, 0, 2), context=0)
                    gpu.flush(2, 64, 32)
                    report['legacy_boot_flush'] = {'resource': 2, 'actual_2D_scanout': True}

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
                        view_base = 30
                        resource_base = 200
                        def query(self, object_id, interface, guest_id):
                            self.call(0x20001, object_id, fixture.live.iid(interface) + struct.pack('<Q', guest_id))
                            return guest_id
                        def clear(self, index, rgba, width, height, rect=None):
                            body = fixture.live.pack('QQ4fQ4iI', self.view_base + index, 4, *rgba, 1,
                                *(rect or (0, 0, width, height)), 1)
                            self.emit(fixture.live.command(fixture.live.method('ID3D11DeviceContext1', 'ClearView'), self.writer, body))
                        def resized_textures(self, width, height):
                            self.originals = []; self.view_base = 50; self.resource_base = 220
                            for index in range(2):
                                description = fixture.live.pack('11I', width, height, 1, 1, 87, 1, 0, 0, 0x28, 0, 0x2 | 0x40000000)
                                self.call(fixture.live.method('ID3D11Device', 'CreateTexture2D'), 10,
                                    fixture.live.pack('Q', 1) + description + fixture.live.pack('QQ', 0, 40 + index))
                                self.call(fixture.live.method('ID3D11Device', 'CreateRenderTargetView'), 10,
                                    fixture.live.pack('QQQ', 40 + index, 0, 50 + index))
                                self.call(0x40000, 40 + index, fixture.live.pack('QII', 120 + index, 9, 8192))
                                metadata = self.t.read(self.memory + 8192, 88)
                                allocation = struct.unpack_from('<Q', metadata, 8)[0]
                                require(0 < allocation <= 64 * 1024 * 1024, 'Resized texture allocation')
                                self.gpu.create_blob(220 + index, 120 + index, allocation)
                                address = self.gpu.map_blob(220 + index, 0x4000000 + 0x1000000 * index)
                                offset, pitch = struct.unpack_from('<QQ', metadata, 24)
                                require(pitch >= width * 4 and offset + (height - 1) * pitch + width * 4 <= allocation,
                                        'Resized texture layout')
                                self.originals.append((address + offset, pitch))
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
                    if args.native:
                        foreign=None
                        if args.import_input or args.import_selected_output:
                            class ScopedGPU:
                                t=gpu.t;bar=gpu.bar
                                def send(self,kind,body=b'',context=2):return gpu.send(kind,body,context=context)
                                def submit(self,data):return self.send(0x207,fixture.live.pack('II',len(data),0)+data)
                                create_blob=fixture.live.GPU.create_blob
                                map_blob=fixture.live.GPU.map_blob
                            foreign=Wire1Neptune(ScopedGPU(),data_resource=409,ring_resource=410,
                                map_offset=0x7000000,resource_base=500)
                            foreign.create(64,32)
                        if args.import_input:
                            foreign.clear(0,(1,0,0,1),64,32);foreign.signal(1)
                            deadline=time.monotonic()+10
                            while struct.unpack_from('<Q',foreign.call(fixture.live.method('ID3D11Fence','GetCompletedValue'),2),8)[0]<1:
                                require(time.monotonic()<deadline,'Foreign input GPU completion timeout')
                                time.sleep(.005)
                            gpu.send(0x202,fixture.live.pack('II',500,0))
                            body=fixture.live.pack('Q12I',3000,500,64,32,1,1,87,1,0,0x28,0,0x2|0x40000000,0)+foreign.export_metadata[0]
                            neptune.call(0x40001,10,body)
                            report['shared_input']={'exporter_context':2,'consumer_context':1,'resource':500,
                                'imported_object':3000,'producer_completion_wait':'fixture only',
                                'actual_decoder_import_succeeded':True}
                            report['owned_processes_after_import']=owned_processes()
                        if args.owned_input:
                            description=fixture.live.pack('11I',64,32,1,1,87,1,0,0,0x28,0,0x2|0x40000000)
                            neptune.call(fixture.live.method('ID3D11Device','CreateTexture2D'),10,
                                fixture.live.pack('Q',1)+description+fixture.live.pack('QQ',0,4000))
                            neptune.call(fixture.live.method('ID3D11Device','CreateRenderTargetView'),10,
                                fixture.live.pack('QQQ',4000,0,4001))
                            neptune.emit(fixture.live.command(fixture.live.method('ID3D11DeviceContext1','ClearView'),
                                neptune.writer,fixture.live.pack('QQ4fQ4iI',4001,4,1,0,0,1,1,0,0,64,32,1)))
                            neptune.call(0x40000,4000,fixture.live.pack('QII',4000,9,8192))
                            metadata=neptune.t.read(neptune.memory+8192,88)
                            allocation=struct.unpack_from('<Q',metadata,8)[0]
                            require(0<allocation<=64*1024*1024,'Owned input allocation')
                            gpu.create_blob(4000,4000,allocation)
                            body=fixture.live.pack('Q12I',4003,4000,64,32,1,1,87,1,0,0x28,0,0x2|0x40000000,0)+metadata
                            neptune.call(0x40001,10,body)
                            report['owned_input']={'resource':4000,'imported_object':4003,
                                'never_selected_before_import':True,'actual_decoder_import_succeeded':True}
                        if args.source_pressure:
                            # Real decoded COM exports and virtio blobs, not a
                            # direct registry fixture. These sources stay alive
                            # throughout resize, held reads and reconnection.
                            for index in range(12):
                                object_id=1000+index; blob_id=1000+index
                                description=fixture.live.pack('11I',64,32,1,1,87,1,0,0,0x28,0,0x2|0x40000000)
                                neptune.call(fixture.live.method('ID3D11Device','CreateTexture2D'),10,
                                    fixture.live.pack('Q',1)+description+fixture.live.pack('QQ',0,object_id))
                                neptune.call(0x40000,object_id,fixture.live.pack('QII',blob_id,9,8192))
                                metadata=neptune.t.read(neptune.memory+8192,88)
                                allocation=struct.unpack_from('<Q',metadata,8)[0]
                                require(0<allocation<=64*1024*1024,'Additional shared source allocation')
                                gpu.create_blob(1000+index,blob_id,allocation)
                            report['unselected_live_sources']=12
                        endpoint = runtime / 'native-display.sock'
                        def sync_stats():
                            return json.loads(q.call('qom-get', {'path': '/machine/peripheral/freshprobe/virtio-backend',
                                'property': 'perp-live-stats'}))
                        def wait_sync(predicate):
                            end = time.monotonic() + 5
                            while True:
                                state = sync_stats()
                                require(not state['failed'] and not state['renderer']['closed'], 'Automatic synchronization path closed: ' + json.dumps(state))
                                if predicate(state): return state
                                require(time.monotonic() < end, 'Automatic synchronization admission timeout: ' + json.dumps(state))
                                time.sleep(.005)
                        def paint(index, color, token):
                            if args.sync_qemu:
                                gpu.scanout(neptune.resource_base + index, width, height)
                                gpu.flush(neptune.resource_base + index, width, height)
                                wait_sync(lambda state: state['renderer']['active_context'] == 1 and
                                    (host_version==3 or state['renderer']['pending'] == 0))
                                # A decoder/control round trip orders earlier
                                # worker ACKs before the next fixture commands.
                                # GetType is not a GPU wait or fence-value poll.
                                neptune.call(fixture.live.method('ID3D11DeviceContext', 'GetType'), 11)
                            if (args.import_input or args.owned_input) and token==2:
                                neptune.emit(fixture.live.command(fixture.live.method('ID3D11DeviceContext','CopyResource'),
                                    neptune.writer,fixture.live.pack('QQ',20+index,4003 if args.owned_input else 3000)))
                            else:neptune.clear(index, color, width, height)
                            neptune.signal(token)
                            if not args.sync_qemu:
                                end = time.monotonic() + 10
                                while True:
                                    reply = neptune.call(fixture.live.method('ID3D11Fence', 'GetCompletedValue'), 2)
                                    if struct.unpack_from('<Q', reply, 8)[0] >= token: break
                                    require(time.monotonic() < end, 'Native test producer GPU fence timeout')
                                    time.sleep(.005)
                            gpu.scanout(neptune.resource_base + index, width, height)
                            gpu.flush(neptune.resource_base + index, width, height)
                        # This fixture explicitly proves its writer completed
                        # before FLUSH; it does not establish that contract for
                        # arbitrary Windows/multicontext producer submissions.
                        paint(0, (1, 0, 0, 1), 2)
                        if args.sync_qemu:
                            # No consumer is connected yet, so QEMU cannot have
                            # copied the worker snapshot. Overwrite and verify
                            # BOTH original resources first. The later red
                            # result must therefore come from the immutable
                            # copy queued by the actual Signal override.
                            neptune.overwrite(width, height)
                            report['automatic_snapshot_challenge'] = {
                                'originals_overwritten_before_consumer_connected': True,
                                'original_pixels_verified_magenta': 2 * width * height,
                                'publication_fence_wait_supplied_by_fixture': False}
                            if args.withhold_producer_token:
                                reply = neptune.call(fixture.live.method('ID3D11Fence', 'GetCompletedValue'), 2)
                                value = struct.unpack_from('<Q', reply, 8)[0]
                                require(value >= 2, 'Negative control did not finish actual GPU work')
                                report['withheld_token_proof'] = {'actual_GPU_completed_value': value,
                                    'snapshot_not_ready': True, 'before_consumer': sync_stats()}
                        end = time.monotonic() + 10
                        while not endpoint.exists():
                            require(process.poll() is None and time.monotonic() < end, 'Native listener unavailable')
                            time.sleep(.01)
                        receiver_log = (output / 'receiver.log').open('w')
                        receiver = subprocess.Popen([str(output / 'metal-receiver'), str(endpoint), str(process.pid),
                            env['PERP_NATIVE_DISPLAY_SESSION']], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=receiver_log, text=True, bufsize=1)
                        actions = []
                        report['native_snapshot'] = {'result': 'running', 'actions': actions,
                            'scanout_tested': True, 'visible_presentation_tested': False,
                            'producer_fence_wait_supplied_by_fixture': not bool(args.sync_qemu), 'Windows_tested': False}
                        def control(text):
                            action = {'command': text}; actions.append(action)
                            receiver.stdin.write(text + '\n'); receiver.stdin.flush()
                            require(select.select([receiver.stdout], [], [], 25)[0], 'Metal receiver control timeout')
                            line = receiver.stdout.readline()
                            require(line, 'Metal receiver exited; see receiver.log')
                            response = json.loads(line); require(response['ok'], 'Metal receiver rejected command')
                            action['response'] = response
                            return response
                        control('connect')
                        control('frame 0 R 64 32')
                        require(not args.withhold_producer_token, 'Withheld producer token was incorrectly published')
                        if args.reexport_input:
                            alias=neptune.query(3000,'ID3D11Texture2D',3004)
                            neptune.call(0x40000,alias,fixture.live.pack('QII',1200,9,8192))
                            allocation=struct.unpack_from('<Q',neptune.t.read(neptune.memory+8192,88),8)[0]
                            require(0<allocation<=64*1024*1024,'Reexported input allocation')
                            gpu.create_blob(1200,1200,allocation)
                            foreign.clear(0,(0,1,0,1),64,32);foreign.signal(2)
                            deadline=time.monotonic()+10
                            while struct.unpack_from('<Q',foreign.call(fixture.live.method('ID3D11Fence','GetCompletedValue'),2),8)[0]<2:
                                require(time.monotonic()<deadline,'Foreign reexport producer completion timeout')
                                time.sleep(.005)
                            gpu.scanout(1200,64,32);gpu.flush(1200,64,32)
                            neptune.signal(3)
                            control('recheck 0 R 64 32')
                            report['reexported_input_denial']={'actual_reexport_succeeded':True,
                                'queried_interface_alias':alias,
                                'new_resource':1200,'foreign_producer_repaint_completed':True,
                                'retained_red_image_intact':True,'before_rejected_frame':sync_stats()}
                            control('frame 1 G 64 32')
                            raise RuntimeError('Reexported input was incorrectly admitted as an exclusive output')
                        if args.import_owned_output:
                            # Selection clears the old claim's granted bit, but
                            # its earlier epoch and held image still exist.
                            gpu.scanout(201,64,32);gpu.flush(201,64,32)
                            neptune.call(fixture.live.method('ID3D11DeviceContext','GetType'),11)
                            body=fixture.live.pack('Q12I',3002,200,64,32,1,1,87,1,0,0x28,0,0x2|0x40000000,0)+neptune.export_metadata[0]
                            try:neptune.call(0x40001,10,body)
                            except AssertionError as error:
                                require(error.args==(('Actual Neptune reply','0x40001','0x40001','0x80070057'),),
                                    'Unexpected owned import failure: '+str(error))
                            else:raise RuntimeError('Owned output reopen unexpectedly succeeded')
                            control('recheck 0 R 64 32')
                            report['owned_output_denial']={'HRESULT':'E_INVALIDARG','resource':200,
                                'previously_selected_but_not_current':True,
                                'proxy_denial_bypassed':True,'retained_red_image_intact':True}
                            control('frame 1 G 64 32')
                            raise RuntimeError('Output reopened without denial was incorrectly published')
                        if args.import_selected_output:
                            gpu.send(0x202,fixture.live.pack('II',200,0),context=2)
                            body=fixture.live.pack('Q12I',3001,200,64,32,1,1,87,1,0,0x28,0,0x2|0x40000000,0)+neptune.export_metadata[0]
                            foreign.call(0x40001,10,body)
                            # The same-context fast path must require the
                            # completed DENY too, not only a tainted flag.
                            neptune.call(0x40001,10,body)
                            paint(0,(0,1,0,1),3)
                            control('recheck 0 R 64 32')
                            report['shared_output_denial']={'actual_foreign_import_succeeded':True,
                                'owned_reopen_after_completed_denial_succeeded':True,
                                'resource':200,'retained_red_image_intact':True,'before_rejected_frame':sync_stats()}
                            control('frame 1 G 64 32')
                            raise RuntimeError('Imported output source was incorrectly published')
                        if not args.withhold_native_update:
                            paint(1, (0, 1, 0, 1), 3)
                        control('frame 1 G 64 32')
                        control('recheck 0 R 64 32')
                        control('ack 0'); control('ack 1')
                        for index in range(12):
                            green = bool(index % 2)
                            paint(index % 2, (0, 1, 0, 1) if green else (1, 0, 0, 1), 4 + index)
                            control('frame 0 ' + ('G' if green else 'R') + ' 64 32')
                            control('ack 0')
                        paint(0, (1, 0, 0, 1), 16)
                        control('frame 0 R 64 32')
                        original_textures = neptune.originals
                        width, height = 803, 607
                        neptune.resized_textures(width, height)
                        paint(1, (0, 1, 0, 1), 17)
                        control('frame 1 G 803 607')
                        control('recheck 0 R 64 32')
                        control('ack 0'); control('ack 1')
                        paint(0, (1, 0, 0, 1), 18)
                        control('frame 0 R 803 607'); control('ack 0')
                        width, height = 64, 32
                        neptune.originals = original_textures
                        neptune.view_base = 30; neptune.resource_base = 200
                        paint(0, (0, 0, 1, 1), 19)
                        control('frame 0 B 64 32')
                        control('disconnect')
                        if args.sync_qemu:
                            wait_sync(lambda state: not state['publisher_can_capture'])
                            if host_version==3:
                                wait_sync(lambda state: state['renderer']['worker_abandoned']>=1)
                                # Challenge the original resource of the held
                                # blue snapshot, too. Reusing it after a mere
                                # disconnect would turn the old blue FD green.
                                neptune.clear(0,(0,1,0,1),width,height)
                        # Retain the old unacknowledged mapping while a new
                        # connection receives a different image with no new
                        # guest update after connect.
                        paint(1, (1, 0, 1, 1), 20)
                        time.sleep(.05)
                        control('connect')
                        control('frame 1 M 64 32')
                        control('recheck 0 B 64 32')
                        control('ack 1'); control('drop 0')
                        if args.sync_qemu and host_version==3:
                            # ACK production is asynchronous. Closing the reader
                            # immediately after enqueueing its final ACK would
                            # correctly abandon that last allocation instead.
                            wait_sync(lambda state: state['publisher']['occupied']==0 and state['renderer']['pending']==0 and
                                state['renderer']['worker_retirements']==state['renderer']['received'])
                        summary = control('quit'); receiver.wait(timeout=5)
                        require(receiver.returncode == 0, 'Metal receiver failed')
                        report['native_snapshot'] = {'result': 'pass', 'reader': summary, 'actions': actions,
                            'scanout_tested': True, 'visible_presentation_tested': False,
                            'producer_fence_wait_supplied_by_fixture': not bool(args.sync_qemu), 'Windows_tested': False}
                        if args.sync_qemu:
                            report['native_snapshot']['sync_stats'] = wait_sync(lambda state:
                                state['renderer']['pending'] == 0 and state['publisher']['occupied'] == 0 and
                                not state['publisher_can_capture'] and
                                state['publisher']['cached_backings'] == 0 and
                                state['publisher']['backing_allocations'] == state['publisher']['backing_releases'] and
                                state['publisher']['mappings'] == state['publisher']['unmappings'])
                            if host_version==3:
                                state=report['native_snapshot']['sync_stats']
                                skipped=sum(action['response'].get('skipped',0) for action in actions if action['command'].startswith('frame '))
                                require(state['copies']==0 and state['mappings_released']==0 and state['external_submitted']==19+skipped and
                                    state['external_acked']==18+skipped and state['external_abandoned']==1,'Direct lease accounting differs')
                                require(state['publisher']['backing_allocations']==0 and state['publisher']['mappings']==0 and
                                    0<state['renderer']['worker_allocations']<state['renderer']['worker_retirements'] and
                                    state['renderer']['worker_abandoned']==1,
                                    'Direct worker leases were not reused/abandoned correctly')
                                if args.source_pressure:
                                    require(state['renderer']['received']==19+skipped and state['renderer']['cancelled']==0,
                                        'Unselected sources consumed GPU snapshots')
                            # A valid anonymous blob has no checked export or
                            # writer identity. Its scanout/flush must be consumed
                            # as a rejection, never resume the unfenced path.
                            gpu.create_blob(250, 0, 16384)
                            gpu.scanout(250, width, height); gpu.flush(250, width, height)
                            rejected = sync_stats()
                            require(rejected['failed'] and rejected['blocked_flushes'] > 0,
                                    'Unknown scanout resumed the unfenced fallback')
                            require(rejected['publisher']['published'] == report['native_snapshot']['sync_stats']['publisher']['published'],
                                    'Unknown writer supplied an extra snapshot')
                            report['native_snapshot']['unknown_writer_rejected'] = rejected
                    require(q.call('query-status')['status'] == 'prelaunch', 'Guest CPU must remain paused')
                if args.headless:
                    state=headless_stats();report['headless_final']=state
                    require(state['initialized'] and not state['closed'] and not state['cocoa_application'] and state['cocoa_windows']==0 and
                        state['thread_handoff_checked'] and state['unproven_scanouts']==(1 if args.boot_flush else 0) and
                        state['unproven_updates']==0,
                        'Native headless unexpectedly entered the unfenced/window path')
                q.call('quit'); process.wait(timeout=5)
                require(process.returncode == 0, 'QEMU failed during quit')
                report['exit_code'] = process.returncode
            finally:
                if receiver is not None and receiver.poll() is None:
                    receiver.terminate()
                    try: receiver.wait(timeout=3)
                    except subprocess.TimeoutExpired: receiver.kill(); receiver.wait(timeout=3)
                if receiver_log is not None: receiver_log.close()
                if process is not None:
                    if process.poll() is None and q is not None:
                        try: q.call('quit'); process.wait(timeout=3)
                        except (AssertionError, OSError, subprocess.TimeoutExpired): pass
                    fixture.stop_group(process)
                for peer in peers: peer.close()
        lines = (output / 'qemu.log').read_text(errors='replace').splitlines()
        if args.headless:
            shutdowns=[json.loads(line.split('perp-native-headless: shutdown ',1)[1]) for line in lines if 'perp-native-headless: shutdown ' in line]
            require(len(shutdowns)==1 and shutdowns[0]['closed'] and shutdowns[0]['client_contexts']==0 and
                shutdowns[0]['context_creates']==shutdowns[0]['context_destroys'],'Headless EGL shutdown did not drain contexts')
            report['headless_shutdown']=shutdowns[0]
        loaded = [line for line in lines if 'dyld[' in line and any(name in line for name in
                  ('libvirglrenderer', 'virgl_render_server', 'libdxmt-native', 'libEGL.dylib', 'libGLESv2.dylib'))]
        report['loaded_library_lines'] = loaded
        for name in (expected_renderer,expected_backend):
            require(any(str(name) in line for line in loaded), 'Expected loaded library absent: ' + str(name))
        require(not any(str(COMMON / 'prefix/lib/libvirglrenderer') in line or
                        str(COMMON / 'prefix/lib/libdxmt-native') in line for line in loaded), 'Different ABI library loaded')
        if packaged:
            require(not any(str(ROOT / '.tools') in line for line in loaded),'Packaged runtime loaded a research graphics library')
        report['matching_server_observed'] = any(row['executable'] == str(expected_server)
            for row in report['owned_processes'] + report.get('owned_processes_after_COM', []))
        if args.com:
            require(report['matching_server_observed'], 'Matching renderer server was not observed')
        verify(); report['result'] = 'pass'
    except BaseException as error:
        report.update(result='fail', error=str(error))
        if report.get('native_snapshot', {}).get('result') == 'running':
            report['native_snapshot']['result'] = 'fail'
        raise
    finally:
        recipe.save(output / 'result.json', report)
    print(json.dumps({key: report[key] for key in ('result', 'actual_neptune_capset', 'matching_server_observed')} |
                     {'COM_result': report.get('COM_result'), 'native_snapshot': report.get('native_snapshot', {}).get('reader'),
                      'receipt': str(output / 'result.json')}, indent=2))


if __name__ == '__main__':
    main()
