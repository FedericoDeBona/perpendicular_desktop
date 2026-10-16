#!/usr/bin/env python3
"""Private-file/socket fixture: never starts a VM or sends guest input."""
import contextlib
import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('cocoa_trial', HERE / 'prepare-trial.py')
trial = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trial)


def write(path, data, mode=0o600):
    path.write_bytes(data)
    path.chmod(mode)


def argv(pairs):
    result = []
    for option, value in pairs:
        result.append(option)
        if value is not None:
            result.append(json.dumps(value) if isinstance(value, dict) else value)
    return result


class TrialCheck(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='perp-cocoa-contract-', dir='/tmp')
        self.base = Path(self.temporary.name)
        self.repo = self.base / 'repo'
        self.repo.mkdir(mode=0o700)
        (self.repo / '.tools').mkdir(mode=0o700)
        self.prefix = self.repo / 'prefix'
        self.prefix.mkdir(mode=0o700)
        self.binary = self.prefix / 'bin/qemu-system-aarch64'
        self.binary.parent.mkdir(mode=0o700)
        write(self.binary, b'fixture-not-an-executable-VM', 0o700)
        self.pin = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.runtime_parent = self.base / 'runtime'
        self.runtime_parent.mkdir(mode=0o700)
        self.patches = contextlib.ExitStack()
        self.patches.enter_context(mock.patch.multiple(trial, REPO=self.repo, PREFIX=self.prefix,
            FORK=self.binary, FORK_SHA256=self.pin, PINNED_ARTIFACTS={'bin/qemu-system-aarch64': self.pin}))
        self.patches.enter_context(mock.patch.object(trial, 'runtime_root', return_value=self.runtime_parent))
        self.data = self.base / 'data'
        self.data.mkdir(mode=0o700)
        (self.data / 'VMs').mkdir(mode=0o700)
        self.json(self.data / 'owner.json', {'format_version': 1, 'application': 'perpendicular-desktop', 'instance_id': str(uuid.uuid4())})
        write(self.data / '.engine.lock', b'')
        self.iso = self.base / 'driver.iso'
        write(self.iso, b'fixture ISO')
        for vm_id in (trial.SOURCE_ID, trial.CLONE_ID):
            vm = self.data / 'VMs' / vm_id
            vm.mkdir(mode=0o700)
            config = {'format_version': 1, 'id': vm_id, 'name': 'fixture', 'cpus': 4,
                'memory_mib': 8192, 'disk_gib': 64, 'iso_path': None,
                'guest_tools_iso_path': str(self.iso), 'created_at': 'fixture',
                'firmware_code_path': str(vm / 'efi-code.fd'), 'tpm_enabled': True,
                'secure_boot_state': 'unverified', 'mac_address': trial.engine_mac(vm_id),
                'keyboard_layout': 'it', 'audio_output': True, 'display_adapter': 'virtio-ramfb'}
            self.json(vm / 'config.json', config)
            write(vm / 'efi-code.fd', b'independent firmware code')
            write(vm / 'efi-vars.fd', b'')
            with (vm / 'efi-vars.fd').open('r+b') as stream:
                stream.truncate(64 * 1024 * 1024)
            header = bytearray(104)
            header[:4] = b'QFI\xfb'
            struct.pack_into('>I', header, 4, 3)
            struct.pack_into('>I', header, 20, 16)
            struct.pack_into('>Q', header, 24, 64 * 1024**3)
            struct.pack_into('>I', header, 100, 104)
            write(vm / 'system.qcow2', header)
            (vm / 'tpm').mkdir(mode=0o700)
            write(vm / 'tpm/tpm2-00.permall', b'independent state ' + vm_id.encode())
        self.output = self.repo / '.tools/cocoa-neptune-trials' / trial.CLONE_ID
        self.vm, self.config = trial.config_at(self.data, trial.CLONE_ID)
        self.source = self.data / 'VMs' / trial.SOURCE_ID
        self.runtime = self.runtime_parent / trial.CLONE_ID
        self.launch_name = 'perpendicular-' + trial.CLONE_ID + '-' + '1' * 32
        self.arguments = argv(trial.expected_pairs(self.config, self.vm, self.runtime, self.launch_name))

    def tearDown(self):
        self.patches.close()
        self.temporary.cleanup()

    def json(self, path, data):
        write(path, (json.dumps(data, sort_keys=True) + '\n').encode())

    def prepare(self):
        return trial.prepare_manifest(self.data, trial.CLONE_ID, self.output)

    @contextlib.contextmanager
    def supervisor(self, manifest):
        self.runtime.mkdir(mode=0o700)
        write(self.runtime / 'supervisor.lock', b'')
        job = {'config': self.config, 'vm_dir': str(self.vm), 'runtime_dir': str(self.runtime),
            'launch_name': self.launch_name, 'qemu': manifest['wrapper'], 'swtpm': manifest['swtpm']}
        self.json(self.runtime / 'launch.json', job)
        peer = socket.socket(socket.AF_UNIX)
        peer.bind(str(self.runtime / 'swtpm.sock'))
        with (self.runtime / 'supervisor.lock').open('r+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                yield
            finally:
                peer.close()

    def test_exact_four_changes_preserve_disk_security_and_lifecycle(self):
        actual = trial.transform(self.arguments, self.config, self.vm, self.runtime, self.launch_name)
        pairs = trial.parse_arguments(actual)
        expected = trial.parse_arguments(self.arguments)
        self.assertIn(('-display', 'cocoa,gl=es'), pairs)
        self.assertFalse(any(key == '-vnc' for key, _ in pairs))
        self.assertIn(('-device', 'tpm-tis-device,tpmdev=tpm0'), pairs)
        self.assertIn(('-device', 'virtio-ramfb-gl,id=display0,addr=0x7,disable-legacy=on,neptune=on,blob=on,hostmem=256M'), pairs)
        untouched = lambda values: [pair for pair in values if pair[0] not in ('-display', '-vnc')
            and not (pair[0] == '-device' and (pair[1].startswith('tpm-tis-device') or pair[1].startswith('virtio-ramfb')))]
        self.assertEqual(untouched(pairs), untouched(expected))
        self.assertEqual([p for p in pairs if p[0] == '-blockdev'], [p for p in expected if p[0] == '-blockdev'])
        self.assertIn(('-S', None), pairs)

    def test_source_and_unrelated_vm_are_always_refused(self):
        for vm_id in (trial.SOURCE_ID, str(uuid.uuid4())):
            config = dict(self.config, id=vm_id)
            with self.assertRaises(trial.Refused):
                trial.transform(self.arguments, config, self.vm, self.runtime, self.launch_name)
            with self.assertRaises(trial.Refused):
                trial.prepare_manifest(self.data, vm_id, self.output)

    def test_added_option_or_mutated_important_argument_refused(self):
        for modified in (self.arguments + ['-incoming', 'tcp:0:4444'],
                [value.replace('addr=0x7', 'addr=0x8') for value in self.arguments],
                [value.replace('ppi=off', 'ppi=on') for value in self.arguments],
                [value.replace('unix:' + str(self.runtime / 'vnc.sock'), '0.0.0.0:0') for value in self.arguments],
                self.arguments + ['-device', 'virtio-ramfb-gl']):
            with self.assertRaises(trial.Refused):
                trial.transform(modified, self.config, self.vm, self.runtime, self.launch_name)

    def test_block_readonly_cannot_be_replaced_with_integer(self):
        changed = list(self.arguments)
        index = next(i for i, value in enumerate(changed) if '"ueficode-file"' in value and 'filename' in value)
        block = json.loads(changed[index]);block['read-only'] = 1
        changed[index] = json.dumps(block)
        with self.assertRaises(trial.Refused):
            trial.transform(changed, self.config, self.vm, self.runtime, self.launch_name)

    def test_prepare_private_manifest_no_state_modification(self):
        before = {name: trial.identity(self.vm / name) for name in ('system.qcow2', 'efi-vars.fd', 'efi-code.fd', 'config.json', 'tpm/tpm2-00.permall')}
        manifest = self.prepare()
        self.assertEqual(manifest['clone_id'], trial.CLONE_ID)
        self.assertEqual(manifest['console'], 'separate Cocoa window only; integrated app VNC console unavailable')
        self.assertFalse(manifest['guest_display_driver_verified'])
        self.assertEqual(trial.checked(self.output, directory=True).st_mode & 0o777, 0o700)
        self.assertEqual(trial.checked(self.output / 'manifest.json').st_mode & 0o777, 0o600)
        self.assertEqual(before, {name: trial.identity(self.vm / name) for name in before})

    def test_baseline_modified_clone_tpm_and_efi_are_permitted(self):
        write(self.vm / 'tpm/tpm2-00.permall', b'different post-baseline state')
        with (self.vm / 'efi-vars.fd').open('r+b') as stream:
            stream.write(b'post baseline')
        self.prepare()

    def test_hardlink_and_backing_chain_refused(self):
        disk = self.vm / 'system.qcow2'
        disk.unlink();os.link(self.source / 'system.qcow2', disk)
        with self.assertRaises(trial.Refused):
            self.prepare()
        disk.unlink();write(disk, (self.source / 'system.qcow2').read_bytes())
        with disk.open('r+b') as stream:
            stream.seek(8);stream.write(struct.pack('>Q', 104))
        with self.assertRaises(trial.Refused):
            self.prepare()

    def test_symlink_and_existing_output_refused(self):
        self.output.parent.mkdir(mode=0o700)
        self.output.symlink_to(self.vm, target_is_directory=True)
        with self.assertRaises(trial.Refused):
            self.prepare()
        self.output.unlink();self.output.mkdir(mode=0o700)
        with self.assertRaises(trial.Refused):
            self.prepare()

    def test_active_supervisor_prevents_prepare(self):
        self.runtime.mkdir(mode=0o700)
        write(self.runtime / 'supervisor.lock', b'')
        with (self.runtime / 'supervisor.lock').open('r+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(trial.Refused):
                self.prepare()

    def test_real_private_socket_and_supervisor_lock_validate(self):
        manifest = self.prepare()
        with self.supervisor(manifest):
            result = trial.validate_launch(manifest, self.arguments)
        self.assertIn('cocoa,gl=es', result)

    def test_no_supervisor_or_preexisting_control_socket_refused(self):
        manifest = self.prepare()
        with self.supervisor(manifest):
            control = socket.socket(socket.AF_UNIX)
            try:
                control.bind(str(self.runtime / 'qmp.sock'))
                with self.assertRaises(trial.Refused):
                    trial.validate_launch(manifest, self.arguments)
            finally:
                control.close()
                (self.runtime / 'qmp.sock').unlink()
        with self.assertRaises(trial.Refused):
            trial.validate_launch(manifest, self.arguments)

    def test_source_or_config_or_media_changed_refused(self):
        manifest = self.prepare()
        with self.supervisor(manifest):
            for path in (self.source / 'tpm/tpm2-00.permall', self.vm / 'config.json', self.iso):
                saved = path.read_bytes();meta = path.stat()
                write(path, saved + b' ')
                with self.assertRaises(trial.Refused):
                    trial.validate_launch(manifest, self.arguments)
                write(path, saved);os.utime(path, ns=(meta.st_atime_ns, meta.st_mtime_ns))

    def test_owner_or_helper_binding_changed_refused(self):
        manifest = self.prepare()
        with self.supervisor(manifest):
            changed = copy.deepcopy(manifest);changed['helper_sha256'] = '0' * 64
            with self.assertRaises(trial.Refused):
                trial.validate_launch(changed, self.arguments)
            owner = trial.read_json(self.data / 'owner.json');owner['instance_id'] = str(uuid.uuid4())
            self.json(self.data / 'owner.json', owner)
            with self.assertRaises(trial.Refused):
                trial.validate_launch(manifest, self.arguments)

    def test_pinned_binary_change_refused(self):
        write(self.binary, b'changed candidate', 0o700)
        with self.assertRaises(trial.Refused):
            self.prepare()

    def test_generated_wrapper_manifest_tamper_fails_before_exec(self):
        manifest = self.prepare()
        self.json(self.output / 'manifest.json', dict(manifest, clone_id=trial.SOURCE_ID))
        result = subprocess.run([str(self.output / 'qemu-trial-wrapper'), '--version'], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Trial manifest changed', result.stderr)

    def test_probe_exact_forwarding_and_environment_scrubbing(self):
        self.prepare()
        for arguments in (['--version'], ['-device', 'help']):
            with mock.patch.object(trial.os, 'execve') as execute, mock.patch.dict(os.environ,
                    {'DYLD_LIBRARY_PATH': '/bad', 'NPT_BACKEND': 'd3dmetal', 'PERP_LIVE_IGNORE_READY': '1', 'RENDER_SERVER_EXEC_PATH': '/bad'}):
                trial.wrapper_main(str(self.output / 'manifest.json'), arguments)
            binary, actual, environment = execute.call_args.args
            self.assertEqual(binary, str(self.binary))
            self.assertEqual(actual, [str(self.binary), *arguments])
            self.assertEqual(environment['NPT_BACKEND'], 'dxmt')
            self.assertEqual(environment['ANGLE_DEFAULT_PLATFORM'], 'metal')
            self.assertEqual(environment['RENDER_SERVER_EXEC_PATH'], str(self.prefix / 'libexec/virgl_render_server'))
            self.assertNotIn('DYLD_LIBRARY_PATH', environment)
            self.assertNotIn('PERP_LIVE_IGNORE_READY', environment)

    def test_device_help_with_extra_args_is_not_a_probe(self):
        self.prepare()
        with mock.patch.object(trial.os, 'execve') as execute, self.assertRaises(SystemExit):
            trial.wrapper_main(str(self.output / 'manifest.json'), ['-device', 'help', '-S'])
        execute.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
