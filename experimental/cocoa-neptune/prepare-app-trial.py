#!/usr/bin/env python3
"""Prepare one explicitly allowlisted, stopped Cocoa/Neptune 3D clone.

The generated wrapper is invoked only by an explicitly selected engine launch.
Preparation never starts QEMU/swtpm, opens QMP or alters VM state. This helper
is independent of the earlier 2D trial wrapper and its private manifest.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import sys
import uuid

SOURCE_ID = '7fc97463-74e6-478c-ba3d-a8e21afc7433'
CLONE_ID = '12755108-83c6-4790-b477-58ca87b1a00e'
FORK_SHA256 = '3707f441f6d593add3dd0a60a7033cc7672b68dab840292cea131172c5fffbc9'
REPO = Path(__file__).absolute().parents[2]
PREFIX = REPO / '.tools/graphics-experiment/prefix'
APP = REPO / '.tools/cocoa-neptune-app/Perpendicular 3D Trial.app'
FORK = APP / 'Contents/MacOS/qemu-system-aarch64'
APP_INFO_SHA256 = '84bece71fda436a19940a931b0cd9c0d21a1245ca94bb2f99725170c105ce907'
PINNED_ARTIFACTS = {
    'bin/qemu-system-aarch64': '8d4d5ec3f94f7f8117568a2fbf426499e71636c2b0af3f5854adf19a33e94981',
    'lib/libvirglrenderer.1.dylib': 'ef7607dc1c25927e8e5d5c23040109aee77e45190a7cf5dee769bc43e340c98a',
    'libexec/virgl_render_server': 'd8a3e00d78b7d61e0412bcb035304e142ae7c78f54528d54ee50bd2a34ab9f9f',
    'lib/libdxmt-native.dylib': 'f01c20fd4fe4cd5d8a0a1ad8d93922f5c8045f325244bfbbe0ad27ebbf443e1c',
    'ANGLE.xcarchive/Products/usr/local/lib/libEGL.dylib': '598ede0ef76705f8737462400696ea1869d24ac83508f1827b4737e305eefa38',
    'ANGLE.xcarchive/Products/usr/local/lib/libGLESv2.dylib': '0d51cbc5cb1f52597ae35ac3847f215e1f0e46ad038ff4a0fa004e95da6007c0',
    'share/qemu/efi-virtio.rom': '26be36901db7f8181c306cc62bd74891d8646528965a78e40cceadba5dd7c8e7',
}
MAX_JSON = 4 * 1024 * 1024
CONFIG_KEYS = set('format_version id name cpus memory_mib disk_gib iso_path guest_tools_iso_path created_at firmware_code_path tpm_enabled secure_boot_state mac_address keyboard_layout audio_output display_adapter'.split())


class Refused(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def canonical_id(value):
    require(isinstance(value, str) and str(uuid.UUID(value)) == value, 'Canonical lowercase UUID required')
    return value


def engine_mac(vm_id):
    canonical_id(vm_id)
    return '52:' + ':'.join('{:02x}'.format(value) for value in uuid.UUID(vm_id).bytes[11:16])


def ordinary_path(value):
    require(isinstance(value, str) and value.startswith('/') and '\x00' not in value and '\n' not in value and ',' not in value, 'Ordinary absolute path required (no commas/newlines)')
    path = Path(value)
    require(str(path) == value and '..' not in path.parts, 'Noncanonical path refused')
    return path


def checked(path, *, directory=False, private=False):
    """No symlink component, current owner, ordinary final object."""
    path = ordinary_path(str(path))
    for part in [*reversed(path.parents), path]:
        meta = part.lstat()
        # The engine intentionally spells its sockets /tmp/... on macOS.
        # Permit only Apple's fixed system alias, never a user-created link.
        system_tmp_alias = (part == Path('/tmp') and part != path and sys.platform == 'darwin' and
                            meta.st_uid == 0 and os.readlink(part) == 'private/tmp') if stat.S_ISLNK(meta.st_mode) else False
        require(not stat.S_ISLNK(meta.st_mode) or system_tmp_alias, 'Symlink path refused')
    meta = path.lstat()
    require(meta.st_uid == os.geteuid(), 'Object is not owned by current user')
    require(stat.S_ISDIR(meta.st_mode) if directory else stat.S_ISREG(meta.st_mode), 'Unexpected object type')
    if private:
        require(meta.st_mode & 0o077 == 0, 'Private object has group/other permissions')
    return meta


def read_bytes(path, limit):
    checked(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        require(os.fstat(stream.fileno()).st_size <= limit, 'Bounded file limit exceeded')
        data = stream.read(limit + 1)
    require(len(data) <= limit, 'File grew beyond bounded limit')
    return data


def no_duplicates(items):
    result = {}
    for key, value in items:
        require(key not in result, 'Duplicate JSON field refused')
        result[key] = value
    return result


def read_json(path):
    return json.loads(read_bytes(path, MAX_JSON), object_pairs_hook=no_duplicates)


def digest(path):
    checked(path)
    result = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def identity(path):
    meta = checked(path)
    return {'device': meta.st_dev, 'inode': meta.st_ino, 'size': meta.st_size, 'mtime_ns': meta.st_mtime_ns}


def runtime_root(owner):
    return Path('/tmp') / ('perp-' + str(os.geteuid()) + '-' + uuid.UUID(owner['instance_id']).hex[:12])


@contextlib.contextmanager
def file_lock(path):
    checked(path, private=True)
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused('An engine or VM supervisor still owns this state')
        yield
    finally:
        os.close(descriptor)


def pid_alive(pid):
    require(type(pid) is int and 0 < pid < 2**31, 'Invalid runtime PID')
    try:
        os.kill(pid, 0)  # Existence only: never signals/kills any process.
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # Uncertainty always blocks preparation.


@contextlib.contextmanager
def stopped(runtime, vm_id, probe=None, *, allow_reaped_failure=False):
    probe = probe or pid_alive
    if not runtime.exists():
        require(not runtime.is_symlink(), 'Symlink runtime refused')
        yield None
        return
    checked(runtime, directory=True, private=True)
    with file_lock(runtime / 'supervisor.lock'):
        launch = read_json(runtime / 'launch.json')
        exit_record = read_json(runtime / 'exit.json')
        name = launch['launch_name']
        require(re.fullmatch('perpendicular-' + re.escape(vm_id) + '-[0-9a-f]{32}', name) is not None, 'Launch identity mismatch')
        require(launch['config']['id'] == vm_id and launch['runtime_dir'] == str(runtime), 'Launch path/VM mismatch')
        require(exit_record['launch_name'] == name, 'Reaped launch identity mismatch')
        successful = exit_record['success'] is True and exit_record['exit_code'] == 0
        failed = (allow_reaped_failure and vm_id == CLONE_ID and exit_record['success'] is False
            and type(exit_record['exit_code']) is int and 0 < exit_record['exit_code'] < 256)
        require(successful or failed, 'A reaped launch is required; failures need the explicit clone-only preflight gate')
        require(not failed or (runtime / 'runtime.json').is_file(), 'Failed launch requires a recorded child PID')
        if (runtime / 'runtime.json').exists():
            record = read_json(runtime / 'runtime.json')
            require(record['launch_name'] == name and not probe(record['pid']), 'Source/clone still live or PID ownership uncertain')
        # An exit record is written only after the supervisor reaps QEMU+swtpm.
        # Stale socket filenames are not opened and cannot establish liveness.
        yield exit_record


def qcow2_header(path):
    checked(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        header = stream.read(104)
    require(len(header) >= 72 and header[:4] == b'QFI\xfb', 'Expected a qcow2 image')
    version = struct.unpack_from('>I', header, 4)[0]
    require(version in (2, 3), 'Unsupported qcow2 version')
    backing_offset, backing_size, cluster_bits, capacity, encryption = struct.unpack_from('>QIIQI', header, 8)
    require(backing_offset == 0 and backing_size == 0, 'Backing chain refused')
    require(9 <= cluster_bits <= 21 and capacity > 0 and encryption == 0, 'Unexpected qcow2 layout/encryption')
    snapshots = struct.unpack_from('>I', header, 60)[0]
    require(snapshots == 0, 'Internal snapshots are outside this clone trial')
    if version == 3:
        require(len(header) == 104, 'Truncated qcow2 v3 header')
        incompatible = struct.unpack_from('>Q', header, 72)[0]
        require(incompatible == 0, 'Dirty/corrupt/external-data/unknown qcow2 feature refused')
        length = struct.unpack_from('>I', header, 100)[0]
        require(104 <= length <= (1 << cluster_bits), 'Invalid qcow2 header length')
    return {'format': 'qcow2', 'version': version, 'virtual_size': capacity, 'backing_file': None, 'external_data_file': False}


def config_at(data, vm_id):
    canonical_id(vm_id)
    directory = data / 'VMs' / vm_id
    checked(directory, directory=True, private=True)
    config = read_json(directory / 'config.json')
    require(set(config) == CONFIG_KEYS and config['format_version'] == 1 and config['id'] == vm_id, 'Config schema/identity differs from frozen engine')
    require(config['firmware_code_path'] == str(directory / 'efi-code.fd'), 'Firmware must be the independent VM-owned code file')
    require(type(config['cpus']) is int and 1 <= config['cpus'] <= 256, 'Invalid CPU config')
    require(type(config['memory_mib']) is int and 4096 <= config['memory_mib'] <= 1048576, 'Invalid memory config')
    require(type(config['disk_gib']) is int and 64 <= config['disk_gib'] <= 16384, 'Invalid disk config')
    require(config['tpm_enabled'] is True and config['audio_output'] is True, 'This PCI7 trial requires the existing TPM and HDA output enabled')
    require(config['keyboard_layout'] in ('en-us', 'it'), 'Unsupported keyboard layout')
    require(vm_id in (SOURCE_ID, CLONE_ID), 'Only the exact source/3D clone pair is allowlisted')
    require(config['display_adapter'] == 'virtio-ramfb', 'Saved engine configuration must remain hybrid 2D')
    require(config['mac_address'] == engine_mac(vm_id), 'MAC differs from the UUID-derived engine identity')
    for key in ('iso_path', 'guest_tools_iso_path'):
        if config[key] is not None:
            ordinary_path(config[key])
            checked(Path(config[key]))
    return directory, config


def tree_files(directory):
    checked(directory, directory=True, private=True)
    files = {}
    for base, directories, names in os.walk(directory, followlinks=False):
        require(len(Path(base).relative_to(directory).parts) <= 8, 'TPM tree too deep')
        for name in directories:
            checked(Path(base) / name, directory=True, private=True)
        for name in names:
            path = Path(base) / name
            meta = checked(path)
            require(meta.st_size <= 64 * 1024 * 1024 and meta.st_nlink == 1, 'Unexpected/shared TPM file')
            files[str(path.relative_to(directory))] = path
            require(len(files) <= 128, 'TPM tree too large')
    require('tpm2-00.permall' in files, 'Existing persistent TPM2 state required')
    return files


def independence(source_dir, clone_dir, *, allow_runtime_lock=False):
    source = {name: source_dir / name for name in ('system.qcow2', 'efi-code.fd', 'efi-vars.fd')}
    clone = {name: clone_dir / name for name in source}
    source.update({'tpm/' + name: path for name, path in tree_files(source_dir / 'tpm').items()})
    clone.update({'tpm/' + name: path for name, path in tree_files(clone_dir / 'tpm').items()})
    if allow_runtime_lock and 'tpm/.lock' in clone and 'tpm/.lock' not in source:
        # swtpm's directory backend creates/truncates this empty regular lock
        # before QEMU is spawned. It is not persistent TPM cryptographic state.
        require(checked(clone['tpm/.lock']).st_size == 0, 'Unexpected TPM lock content')
        del clone['tpm/.lock']
    source_inodes = set()
    clone_inodes = set()
    bindings = {}
    for side, files, inodes in (('source', source, source_inodes), ('clone', clone, clone_inodes)):
        for name, path in files.items():
            meta = checked(path)
            require(meta.st_nlink == 1, 'Hardlinked VM state refused')
            inodes.add((meta.st_dev, meta.st_ino))
            bindings.setdefault(name, {})[side] = identity(path)
    require(len(source_inodes) == len(source) and len(clone_inodes) == len(clone) and source_inodes.isdisjoint(clone_inodes), 'VM state aliases another state file')
    require(checked(clone['efi-vars.fd']).st_size == checked(source['efi-vars.fd']).st_size == 64 * 1024 * 1024, 'Expected 64 MiB raw EFI variable stores')
    firmware_hash = digest(source['efi-code.fd'])
    require(digest(clone['efi-code.fd']) == firmware_hash, 'Firmware code differs from stopped source')
    return bindings, firmware_hash


def block_nodes(config, vm):
    result = []
    for node, path, readonly, driver in (
        ('ueficode', config['firmware_code_path'], True, 'raw'),
        ('uefivars', str(vm / 'efi-vars.fd'), False, 'raw'),
        ('system', str(vm / 'system.qcow2'), False, 'qcow2')):
        result += [('-blockdev', {'driver': 'file', 'node-name': node + '-file', 'filename': path, 'read-only': readonly}),
                   ('-blockdev', {'driver': driver, 'node-name': node, 'file': node + '-file', 'read-only': readonly})]
    return result


def expected_pairs(config, vm, runtime, launch_name):
    """Exact frozen engine/src/command.rs contract, JSON compared structurally."""
    pairs = [('-name', launch_name), ('-uuid', config['id']),
        ('-machine', 'virt,gic-version=3,highmem=on,pflash0=ueficode,pflash1=uefivars'),
        ('-accel', 'hvf'), ('-cpu', 'host'),
        ('-smp', 'cpus={0},sockets=1,cores={0},threads=1'.format(config['cpus'])),
        ('-m', str(config['memory_mib'])), ('-k', config['keyboard_layout']), ('-nodefaults', None),
        ('-display', 'none'), ('-vga', 'none'),
        ('-device', 'qemu-xhci,id=usb'), ('-device', 'usb-kbd,bus=usb.0'), ('-device', 'usb-tablet,bus=usb.0'),
        ('-netdev', 'user,id=net0'), ('-device', 'virtio-net-pci,netdev=net0,mac=' + config['mac_address']),
        ('-device', 'virtio-rng-pci'), ('-boot', 'menu=on'), ('-rtc', 'base=localtime'),
        ('-qmp', 'unix:' + str(runtime / 'qmp.sock') + ',server=on,wait=off'),
        ('-vnc', 'unix:' + str(runtime / 'vnc.sock')), ('-serial', 'file:' + str(vm / 'serial.log')),
        ('-monitor', 'none'), ('-S', None)]
    pairs += block_nodes(config, vm)
    pairs += [('-device', 'nvme,drive=system,serial=perp' + config['id'].replace('-', '')[:12] + ',bootindex=1')]
    if config['iso_path'] is not None:
        pairs += [('-blockdev', {'driver': 'file', 'node-name': 'installiso-file', 'filename': config['iso_path'], 'read-only': True}),
                  ('-blockdev', {'driver': 'raw', 'node-name': 'installiso', 'file': 'installiso-file', 'read-only': True})]
    else:
        pairs += [('-drive', 'if=none,media=cdrom,id=installiso,readonly=on')]
    pairs += [('-device', 'usb-bot,id=installusb,bus=usb.0'),
              ('-device', 'scsi-cd,id=installcd,drive=installiso,bus=installusb.0,bootindex=2')]
    if config['guest_tools_iso_path'] is not None:
        pairs += [('-blockdev', {'driver': 'file', 'node-name': 'guesttools-file', 'filename': config['guest_tools_iso_path'], 'read-only': True}),
            ('-blockdev', {'driver': 'raw', 'node-name': 'guesttools', 'file': 'guesttools-file', 'read-only': True}),
            ('-device', 'usb-bot,id=guesttoolsusb,bus=usb.0'),
            ('-device', 'scsi-cd,id=guesttoolscd,drive=guesttools,bus=guesttoolsusb.0')]
    pairs += [('-chardev', 'socket,id=chrtpm,path=' + str(runtime / 'swtpm.sock')),
        ('-tpmdev', 'emulator,id=tpm0,chardev=chrtpm'), ('-device', 'tpm-tis-device,tpmdev=tpm0,ppi=off'),
        ('-device', 'virtio-serial-pci,id=guestserial'),
        ('-chardev', 'socket,id=guestagent,path=' + str(runtime / 'agent.sock') + ',server=on,wait=off'),
        ('-device', 'virtserialport,bus=guestserial.0,chardev=guestagent,name=org.perpendicular.guest_agent.0'),
        ('-audiodev', 'coreaudio,id=audio0'), ('-device', 'ich9-intel-hda,id=hda0'),
        ('-device', 'hda-output,bus=hda0.0,audiodev=audio0')]
    return pairs + [('-device', 'virtio-ramfb,id=display0,addr=0x7')]


def parse_arguments(arguments):
    require(isinstance(arguments, list) and len(arguments) <= 256 and all(isinstance(x, str) and len(x) <= MAX_JSON and '\x00' not in x for x in arguments), 'Invalid argv')
    pairs = []
    index = 0
    while index < len(arguments):
        option = arguments[index]
        require(option in ('-name', '-uuid', '-machine', '-accel', '-cpu', '-smp', '-m', '-k', '-nodefaults', '-display', '-vga', '-device', '-netdev', '-boot', '-rtc', '-qmp', '-vnc', '-serial', '-monitor', '-S', '-blockdev', '-drive', '-chardev', '-tpmdev', '-audiodev'), 'Nonallowlisted QEMU option')
        index += 1
        value = None
        if option not in ('-nodefaults', '-S'):
            require(index < len(arguments), 'Missing QEMU option value')
            value = arguments[index]
            index += 1
            if option == '-blockdev':
                value = json.loads(value, object_pairs_hook=no_duplicates)
                require(isinstance(value, dict), 'Block node must be a JSON object')
        pairs.append((option, value))
    return pairs


def transform(arguments, config, vm, runtime, launch_name):
    require(config['id'] == CLONE_ID, 'Only the exact independent 3D clone is allowlisted')
    canonical_id(config['id'])
    require(re.fullmatch('perpendicular-' + re.escape(config['id']) + '-[0-9a-f]{32}', launch_name) is not None, 'Launch identity is not engine-owned')
    pairs = parse_arguments(arguments)
    expected = expected_pairs(config, vm, runtime, launch_name)
    # JSON booleans must not compare equal to Python's integer 0/1.
    require(json.dumps(pairs, sort_keys=True) == json.dumps(expected, sort_keys=True), 'QEMU argv differs from the frozen clone-only allowlist')
    result = []
    # Preserve spelling/order, including the QMP lifecycle endpoint and every
    # disk/media/security argument, except these four exact reviewed changes.
    index = 0
    while index < len(arguments):
        option = arguments[index]
        count = 1 if option in ('-S', '-nodefaults') else 2
        chunk = arguments[index:index + count]
        if chunk == ['-vnc', 'unix:' + str(runtime / 'vnc.sock')]:
            pass
        elif chunk == ['-display', 'none']:
            result += ['-display', 'cocoa,gl=es']
        elif chunk == ['-device', 'tpm-tis-device,tpmdev=tpm0,ppi=off']:
            result += ['-device', 'tpm-tis-device,tpmdev=tpm0']
        elif chunk == ['-device', 'virtio-ramfb,id=display0,addr=0x7']:
            result += ['-device', 'virtio-ramfb-gl,id=display0,addr=0x7,disable-legacy=on,neptune=on,blob=on,hostmem=256M']
        else:
            result += chunk
        index += count
    # The app executable lives outside the compiled prefix/bin. Keep all ROM
    # lookup in the pinned existing prefix; never copy/reset EFI or TPM state.
    return ['-L', str(PREFIX / 'share/qemu'), *result]


def verify_artifacts():
    for relative, expected in PINNED_ARTIFACTS.items():
        path = PREFIX / relative
        require(digest(path) == expected, 'Pinned graphics artifact changed: ' + relative)
    require(os.access(FORK, os.X_OK), 'Pinned QEMU is not executable')
    require(digest(FORK) == FORK_SHA256, 'Signed Cocoa application Mach-O changed')
    require(digest(APP / 'Contents/Info.plist') == APP_INFO_SHA256, 'Pinned Cocoa application metadata changed')
    package = read_json(APP.parent / 'package.json')
    require(package['binary_sha256'] == FORK_SHA256 and package['original_sha256'] == PINNED_ARTIFACTS['bin/qemu-system-aarch64'], 'Cocoa app provenance changed')
    require(package['bundle_id'] == 'org.perpendicular.cocoa3dtrial' and package['code_identity_unchanged'] is True, 'Cocoa app identity/provenance differs')
    info = plistlib.loads(read_bytes(APP / 'Contents/Info.plist', MAX_JSON))
    require(info['CFBundleIdentifier'] == 'org.perpendicular.cocoa3dtrial' and info['CFBundleExecutable'] == 'qemu-system-aarch64', 'Cocoa app identity changed')
    for name, expected in package['keymap_sha256'].items():
        require(re.fullmatch(r'[a-z-]+', name) is not None, 'Unexpected keymap path')
        require(digest(APP / 'Contents/share/qemu/keymaps' / name) == expected, 'Packaged keymap changed')


def graphics_environment(inherited, output):
    # Never inherit an alternate renderer/loader or experimental probe hooks.
    environment = {key: value for key, value in inherited.items()
        if not key.startswith(('DYLD_', 'QEMU_', 'VIRGL_', 'GALLIUM_', 'NPT_', 'ANGLE_', 'PERP_'))
        and key not in ('LD_PRELOAD', 'LD_LIBRARY_PATH', 'RENDER_SERVER_EXEC_PATH', 'DXMT_LOG_PATH')}
    libraries = str(PREFIX / 'lib') + ':' + str(PREFIX / 'ANGLE.xcarchive/Products/usr/local/lib')
    environment.update({
        'DYLD_FALLBACK_LIBRARY_PATH': libraries,
        'ANGLE_DEFAULT_PLATFORM': 'metal',
        'NPT_BACKEND': 'dxmt',
        'RENDER_SERVER_EXEC_PATH': str(PREFIX / 'libexec/virgl_render_server'),
        'DXMT_LOG_PATH': str(output / 'dxmt'),
    })
    # Explicit allowlisted paths protect the runtime from an inherited override.
    # The native ARM64 defaults are the same library; no D3D12 support is implied.
    for key in ('NPT_D3D11_LIBRARY_PATH', 'NPT_DXGI_LIBRARY_PATH', 'NPT_D3D12_LIBRARY_PATH'):
        environment[key] = str(PREFIX / 'lib/libdxmt-native.dylib')
    return environment


def prepare_manifest(data, clone_id, output):
    canonical_id(clone_id)
    require(clone_id == CLONE_ID, 'Only the exact independent 3D clone is allowlisted')
    data = ordinary_path(str(data))
    checked(data, directory=True, private=True)
    owner = read_json(data / 'owner.json')
    require(owner['format_version'] == 1 and owner['application'] == 'perpendicular-desktop', 'Store ownership mismatch')
    runtime_parent = runtime_root(owner)
    output = ordinary_path(str(output))
    trial_parent = REPO / '.tools/cocoa-neptune-app-trials-gen3'
    require(output.parent == trial_parent and output.name == CLONE_ID and not os.path.lexists(output), 'Output must be the fresh .tools/cocoa-neptune-app-trials-gen3/allowlisted-UUID directory')
    helper = Path(__file__).absolute()
    checked(helper)
    verify_artifacts()
    with file_lock(data / '.engine.lock'), stopped(runtime_parent / SOURCE_ID, SOURCE_ID), stopped(runtime_parent / clone_id, clone_id, allow_reaped_failure=True) as prior_exit:
        source_dir, source = config_at(data, SOURCE_ID)
        vm, config = config_at(data, clone_id)
        require(config['mac_address'] != source['mac_address'] and config['id'] != source['id'], 'Clone must have new UUID and MAC')
        require(config['id'].replace('-', '')[:12] != source['id'].replace('-', '')[:12], 'Clone NVMe serial must differ from source')
        # This clone has already booted independently for a 2D baseline. Its
        # media/EFI variables/TPM bytes may legitimately differ from the source.
        # Bind its exact current configuration now, while both VMs are stopped.
        for key in ('cpus', 'memory_mib', 'disk_gib', 'tpm_enabled', 'audio_output', 'keyboard_layout', 'display_adapter', 'secure_boot_state'):
            require(source[key] == config[key], 'Clone changed preexisting hardware/media/security configuration: ' + key)
        bindings, firmware_hash = independence(source_dir, vm)
        disks = {'source': qcow2_header(source_dir / 'system.qcow2'), 'clone': qcow2_header(vm / 'system.qcow2')}
        require(disks['source']['virtual_size'] == disks['clone']['virtual_size'] == config['disk_gib'] * 1024**3, 'Clone disk capacity differs')
        iso_bindings = {key: {'identity': identity(Path(config[key])), 'sha256': digest(Path(config[key]))}
            for key in ('iso_path', 'guest_tools_iso_path') if config[key] is not None}
        swtpm = str(Path('/opt/homebrew/bin/swtpm').resolve(strict=True))
        checked(Path(swtpm))
        require(os.access(swtpm, os.X_OK), 'Existing swtpm is unavailable')
        manifest = {'format_version': 1, 'purpose': 'private-exact-clone-cocoa-neptune-app-pci7',
            'generation': 3, 'prior_reaped_exit': prior_exit,
            'previous_helper_sha256': 'fcfc19fbbad466382d9624cc41b4f8c626c408347f16333516798f6c59dbc8b4',
            'resource_dir': str(PREFIX / 'share/qemu'),
            'prepared_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'uid': os.geteuid(),
            'data_dir': str(data), 'source_id': SOURCE_ID, 'clone_id': clone_id, 'config': config,
            'owner_sha256': digest(data / 'owner.json'),
            'source_config_sha256': digest(source_dir / 'config.json'), 'clone_config_sha256': digest(vm / 'config.json'),
            'vm_dir': str(vm), 'source_dir': str(source_dir), 'runtime_dir': str(runtime_parent / clone_id),
            'source_runtime_dir': str(runtime_parent / SOURCE_ID), 'wrapper': str(output / 'qemu-trial-wrapper'),
            'helper': str(helper), 'helper_sha256': digest(helper),
            'fork': str(FORK), 'fork_sha256': FORK_SHA256, 'graphics_artifacts': PINNED_ARTIFACTS,
            'swtpm': swtpm, 'swtpm_sha256': digest(Path(swtpm)),
            'firmware_code_sha256': firmware_hash, 'state_bindings': bindings, 'disk_headers': disks, 'iso_bindings': iso_bindings,
            'mutations': ['fixed -L to existing pinned graphics prefix/share/qemu (app relocation)', 'replace only display none with cocoa,gl=es', 'remove only the expected Unix VNC pair (incompatible with GL)',
                'omit unsupported ppi=off on fork tpm-tis-device',
                'replace only PCI7 virtio-ramfb with virtio-ramfb-gl,disable-legacy=on,neptune=on,blob=on,hostmem=256M'],
            'console': 'separate Cocoa window only; integrated app VNC console unavailable',
            'guest_security_verified': False, 'guest_display_driver_verified': False,
            'warnings': ['TPM cryptographic state was copied; it is not a newly provisioned TPM identity.',
                'This QEMU10 research binary does not contain the later bounded USB HID backpressure fix.',
                'No Windows 3D driver load, real Cocoa pixels or sustained performance has been verified.']}
        if not trial_parent.exists():
            trial_parent.mkdir(mode=0o700)
        checked(trial_parent, directory=True, private=True)
        output.mkdir(mode=0o700)
        (output / 'dxmt').mkdir(mode=0o700)
        manifest_path = output / 'manifest.json'
        manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
        wrapper = (f'#!{sys.executable} -I\nimport hashlib, runpy, sys\n'
                   f'p = {str(helper)!r}\n'
                   f'm = {str(manifest_path)!r}\n'
                   f'if hashlib.sha256(open(p, "rb").read()).hexdigest() != {manifest["helper_sha256"]!r}: raise SystemExit("Trial helper changed")\n'
                   f'if hashlib.sha256(open(m, "rb").read()).hexdigest() != {hashlib.sha256(manifest_bytes).hexdigest()!r}: raise SystemExit("Trial manifest changed")\n'
                   f'runpy.run_path(p, run_name="perpendicular_cocoa_trial")["wrapper_main"](m, sys.argv[1:])\n').encode()
        for path, contents, mode in ((manifest_path, manifest_bytes, 0o600), (output / 'qemu-trial-wrapper', wrapper, 0o700)):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(contents)
                stream.flush()
                os.fsync(stream.fileno())
        return manifest


def validate_launch(manifest, arguments):
    require(manifest['format_version'] == 1 and manifest['uid'] == os.geteuid() and manifest['source_id'] == SOURCE_ID, 'Trial manifest ownership/schema mismatch')
    clone_id = canonical_id(manifest['clone_id'])
    require(clone_id == CLONE_ID, 'Only the exact independent 3D clone is allowlisted')
    data = ordinary_path(manifest['data_dir'])
    owner = read_json(data / 'owner.json')
    require(owner['format_version'] == 1 and owner['application'] == 'perpendicular-desktop', 'Store ownership changed')
    require(digest(data / 'owner.json') == manifest['owner_sha256'], 'Prepared store owner changed')
    expected_runtime = runtime_root(owner) / clone_id
    require(manifest['runtime_dir'] == str(expected_runtime) and manifest['source_runtime_dir'] == str(runtime_root(owner) / SOURCE_ID), 'Runtime path changed')
    require(manifest['fork'] == str(FORK) and manifest['fork_sha256'] == FORK_SHA256 and manifest['graphics_artifacts'] == PINNED_ARTIFACTS, 'Pinned graphics manifest changed')
    verify_artifacts()
    require(digest(Path(manifest['swtpm'])) == manifest['swtpm_sha256'], 'Prepared swtpm changed')
    require(manifest['helper'] == str(Path(__file__).absolute()), 'Prepared helper path changed')
    require(digest(Path(manifest['helper'])) == manifest['helper_sha256'], 'Prepared helper changed')
    vm, config = config_at(data, clone_id)
    source_dir, source = config_at(data, SOURCE_ID)
    require(str(vm) == manifest['vm_dir'] and str(source_dir) == manifest['source_dir'] and config == manifest['config'], 'Clone config or owned paths changed')
    require(digest(vm / 'config.json') == manifest['clone_config_sha256'] and digest(source_dir / 'config.json') == manifest['source_config_sha256'], 'Prepared config changed')
    bindings, firmware_hash = independence(source_dir, vm, allow_runtime_lock=True)
    require(firmware_hash == manifest['firmware_code_sha256'], 'Firmware code changed')
    require(set(bindings) == set(manifest['state_bindings']), 'Prepared state tree changed')
    for name, binding in bindings.items():
        require(set(binding) == set(manifest['state_bindings'][name]), 'Prepared source/clone state tree changed')
        for side in binding:
            for key in ('device', 'inode'):
                require(binding[side][key] == manifest['state_bindings'][name][side][key], 'Prepared state file was replaced')
        if 'source' in binding:
            require(binding['source'] == manifest['state_bindings'][name]['source'], 'Stopped source state changed after preparation')
    for side, directory in (('source', source_dir), ('clone', vm)):
        require(qcow2_header(directory / 'system.qcow2') == manifest['disk_headers'][side], 'Prepared disk header changed')
    for key, binding in manifest['iso_bindings'].items():
        require(identity(Path(config[key])) == binding['identity'], 'Read-only ISO changed')
    checked(expected_runtime, directory=True, private=True)
    serial_log = vm / 'serial.log'
    if os.path.lexists(serial_log):
        require(checked(serial_log).st_nlink == 1, 'Serial log must not alias another file')
    job = read_json(expected_runtime / 'launch.json')
    require(set(job) == {'config', 'vm_dir', 'runtime_dir', 'launch_name', 'qemu', 'swtpm'}, 'Launch schema changed')
    require(job['config'] == config and job['vm_dir'] == str(vm) and job['runtime_dir'] == str(expected_runtime) and
            job['qemu'] == manifest['wrapper'] and job['swtpm'] == manifest['swtpm'], 'Supervisor launch identity/path mismatch')
    # The supervisor lock must currently be held. Do not take the store lock:
    # the real engine already owns it while it waits for this launch.
    checked(expected_runtime / 'supervisor.lock', private=True)
    descriptor = os.open(expected_runtime / 'supervisor.lock', os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        else:
            raise Refused('No active engine supervisor owns the clone launch')
    finally:
        os.close(descriptor)
    for name in ('qmp.sock', 'vnc.sock', 'agent.sock'):
        require(not os.path.lexists(expected_runtime / name), 'Control socket already exists before QEMU launch')
    tpm_socket = (expected_runtime / 'swtpm.sock').lstat()
    require(stat.S_ISSOCK(tpm_socket.st_mode) and tpm_socket.st_uid == os.geteuid(), 'Owned cloned TPM endpoint required')
    with stopped(runtime_root(owner) / SOURCE_ID, SOURCE_ID):
        return transform(arguments, config, vm, expected_runtime, job['launch_name'])


def wrapper_main(manifest_path, arguments):
    try:
        manifest_path = ordinary_path(manifest_path)
        checked(manifest_path.parent, directory=True, private=True)
        checked(manifest_path, private=True)
        manifest = read_json(manifest_path)
        require(manifest['wrapper'] == str(manifest_path.parent / 'qemu-trial-wrapper'), 'Manifest/wrapper directory mismatch')
        require(manifest['fork'] == str(FORK) and manifest['fork_sha256'] == FORK_SHA256 and digest(FORK) == FORK_SHA256, 'Pinned fork changed')
        require(manifest['clone_id'] == CLONE_ID and manifest['source_id'] == SOURCE_ID and manifest['purpose'] == 'private-exact-clone-cocoa-neptune-app-pci7', 'Manifest target/purpose changed')
        verify_artifacts()
        if arguments in (['--version'], ['-device', 'help']):
            actual = arguments  # Exact real binary output; neither probe starts a VM.
        else:
            actual = validate_launch(manifest, arguments)
        checked(manifest_path.parent / 'dxmt', directory=True, private=True)
        environment = graphics_environment(os.environ, manifest_path.parent)
        os.execve(str(FORK), [str(FORK), *actual], environment)
    except (Refused, OSError, ValueError, KeyError, TypeError) as error:
        print('Private Cocoa 3D trial refused: ' + str(error), file=sys.stderr)
        raise SystemExit(2)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('clone_id', choices=(CLONE_ID,), help='The single explicitly authorized independent 3D clone')
    parser.add_argument('--data-dir', required=True, type=Path)
    parser.add_argument('--output', type=Path, help='Fresh repo/.tools/cocoa-neptune-app-trials-gen3/allowlisted-UUID only')
    arguments = parser.parse_args(argv)
    try:
        output = arguments.output or REPO / '.tools/cocoa-neptune-app-trials-gen3' / arguments.clone_id
        manifest = prepare_manifest(arguments.data_dir, arguments.clone_id, output)
        print(json.dumps({'prepared': True, 'clone_id': manifest['clone_id'], 'manifest': str(output / 'manifest.json'), 'wrapper': manifest['wrapper'], 'started': False}, indent=2))
    except (Refused, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, 'Preparation refused: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
