#!/usr/bin/env python3
"""Generation3 resource/failed-preflight regressions; private files only."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import unittest
from unittest import mock
import plistlib
import subprocess

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = load('trial_base_tests', 'test-trial.py')
trial = load('app_trial', 'prepare-app-trial.py')
base.trial = trial


class AppTrialCheck(base.TrialCheck):
    def setUp(self):
        super().setUp()
        app = self.repo / 'fixture.app'
        (app / 'Contents/share/qemu/keymaps').mkdir(parents=True, mode=0o700)
        info = app / 'Contents/Info.plist'
        base.write(info, plistlib.dumps({'CFBundleIdentifier': 'org.perpendicular.cocoa3dtrial',
            'CFBundleExecutable': 'qemu-system-aarch64'}))
        base.write(app / 'Contents/share/qemu/keymaps/it', b'fixture keymap')
        package = {'binary_sha256': self.pin, 'original_sha256': self.pin,
            'bundle_id': 'org.perpendicular.cocoa3dtrial', 'code_identity_unchanged': True,
            'keymap_sha256': {'it': trial.digest(app / 'Contents/share/qemu/keymaps/it')}}
        self.json(app.parent / 'package.json', package)
        self.patches.enter_context(mock.patch.multiple(trial, APP=app, APP_INFO_SHA256=trial.digest(info)))
        self.output = self.repo / '.tools/cocoa-neptune-app-trials-gen3' / trial.CLONE_ID

    def test_exact_four_changes_preserve_disk_security_and_lifecycle(self):
        actual = trial.transform(self.arguments, self.config, self.vm, self.runtime, self.launch_name)
        self.assertEqual(actual[:2], ['-L', str(self.prefix / 'share/qemu')])
        pairs = trial.parse_arguments(actual[2:])
        expected = trial.parse_arguments(self.arguments)
        self.assertIn(('-display', 'cocoa,gl=es'), pairs)
        self.assertFalse(any(key == '-vnc' for key, _ in pairs))
        self.assertIn(('-device', 'tpm-tis-device,tpmdev=tpm0'), pairs)
        self.assertIn(('-device', 'virtio-ramfb-gl,id=display0,addr=0x7,disable-legacy=on,neptune=on,blob=on,hostmem=256M'), pairs)
        unchanged = lambda values: [pair for pair in values if pair[0] not in ('-display', '-vnc')
            and not (pair[0] == '-device' and (pair[1].startswith('tpm-tis-device') or pair[1].startswith('virtio-ramfb')))]
        self.assertEqual(unchanged(pairs), unchanged(expected))
        self.assertIn(('-S', None), pairs)

    def test_preflight_failure_requires_explicit_clone_gate_and_gone_pid(self):
        self.runtime.mkdir(mode=0o700)
        base.write(self.runtime / 'supervisor.lock', b'')
        self.json(self.runtime / 'launch.json', {'launch_name': self.launch_name,
            'config': self.config, 'runtime_dir': str(self.runtime)})
        exit_record = {'launch_name': self.launch_name, 'success': False, 'exit_code': 1,
            'error': None, 'exited_at': 'fixture'}
        self.json(self.runtime / 'exit.json', exit_record)
        self.json(self.runtime / 'runtime.json', {'launch_name': self.launch_name, 'pid': os.getpid()})
        with self.assertRaises(trial.Refused):
            with trial.stopped(self.runtime, trial.CLONE_ID, probe=lambda pid: False):
                pass
        with self.assertRaises(trial.Refused):
            with trial.stopped(self.runtime, trial.CLONE_ID, probe=lambda pid: True, allow_reaped_failure=True):
                pass
        with trial.stopped(self.runtime, trial.CLONE_ID, probe=lambda pid: False, allow_reaped_failure=True) as prior:
            self.assertEqual(prior, exit_record)
        self.assertEqual(trial.read_json(self.runtime / 'exit.json'), exit_record)
        (self.runtime / 'runtime.json').unlink()
        with self.assertRaises(trial.Refused):
            with trial.stopped(self.runtime, trial.CLONE_ID, probe=lambda pid: False, allow_reaped_failure=True):
                pass

    def test_changed_app_info_or_keymap_refused(self):
        for path in (trial.APP / 'Contents/Info.plist', trial.APP / 'Contents/share/qemu/keymaps/it'):
            before = path.read_bytes()
            base.write(path, before + b' ')
            with self.assertRaises(trial.Refused):
                trial.verify_artifacts()
            base.write(path, before)

    def test_fresh_attempt_rebinds_atomic_tpm_replacement_without_vm_copy(self):
        first = self.prepare()
        source_before = trial.identity(self.source / 'tpm/tpm2-00.permall')
        state = self.vm / 'tpm/tpm2-00.permall'
        replacement = self.vm / 'tpm/replacement.tmp'
        base.write(replacement, b'legitimate stopped fixture TPM replacement')
        os.replace(replacement, state)
        attempt = self.output.with_name(trial.CLONE_ID + '-restart-2')
        second = trial.prepare_manifest(self.data, trial.CLONE_ID, attempt)
        self.assertNotEqual(first['state_bindings']['tpm/tpm2-00.permall']['clone']['inode'],
            second['state_bindings']['tpm/tpm2-00.permall']['clone']['inode'])
        self.assertEqual(second['state_bindings']['tpm/tpm2-00.permall']['clone'], trial.identity(state))
        self.assertEqual(second['clone_id'], trial.CLONE_ID)
        self.assertEqual(second['vm_dir'], first['vm_dir'])
        self.assertEqual(second['wrapper'], str(attempt / 'qemu-trial-wrapper'))
        self.assertEqual(source_before, trial.identity(self.source / 'tpm/tpm2-00.permall'))
        self.assertEqual({path.name for path in (self.data / 'VMs').iterdir()}, {trial.SOURCE_ID, trial.CLONE_ID})
        self.assertTrue((self.output / 'manifest.json').is_file())

    def test_attempt_suffix_accepts_exact_48_character_boundary(self):
        attempt = self.output.with_name(trial.CLONE_ID + '-' + 'a' * 48)
        manifest = trial.prepare_manifest(self.data, trial.CLONE_ID, attempt)
        self.assertEqual(manifest['wrapper'], str(attempt / 'qemu-trial-wrapper'))
        self.assertEqual(trial.read_json(attempt / 'manifest.json')['clone_id'], trial.CLONE_ID)

    def test_invalid_or_oversized_attempt_suffix_refused(self):
        suffixes = ('-', '-UPPER', '-try_2', '-try.2', '-.', '-..', '-caf\u00e9',
            '-try\nagain', '-try\x00again', '-' + 'a' * 49)
        for suffix in suffixes:
            with self.subTest(suffix=repr(suffix)), self.assertRaises(trial.Refused):
                trial.prepare_manifest(self.data, trial.CLONE_ID, self.output.with_name(trial.CLONE_ID + suffix))
        self.assertFalse(self.output.parent.exists())

    def test_attempt_output_wrong_parent_nested_or_traversal_refused(self):
        name = trial.CLONE_ID + '-retry'
        invalid = (self.output.parent.parent / name, self.output.parent / 'nested' / name,
            self.output.parent / '..' / self.output.parent.name / name,
            self.output.parent / (trial.SOURCE_ID + '-retry'))
        for attempt in invalid:
            with self.subTest(path=str(attempt)), self.assertRaises(trial.Refused):
                trial.prepare_manifest(self.data, trial.CLONE_ID, attempt)
        self.assertFalse(self.output.parent.exists())

    def test_attempt_output_cannot_reuse_directory_file_or_dangling_symlink(self):
        self.output.parent.mkdir(mode=0o700)
        attempt = self.output.with_name(trial.CLONE_ID + '-retry')
        attempt.mkdir(mode=0o700)
        with self.assertRaises(trial.Refused):
            trial.prepare_manifest(self.data, trial.CLONE_ID, attempt)
        attempt.rmdir()
        base.write(attempt, b'existing private file')
        with self.assertRaises(trial.Refused):
            trial.prepare_manifest(self.data, trial.CLONE_ID, attempt)
        self.assertEqual(attempt.read_bytes(), b'existing private file')
        attempt.unlink()
        attempt.symlink_to(self.base / 'absent')
        with self.assertRaises(trial.Refused):
            trial.prepare_manifest(self.data, trial.CLONE_ID, attempt)
        self.assertTrue(attempt.is_symlink())

    def test_explicit_slot8_changes_exactly_one_gpu_argument(self):
        default = trial.transform(self.arguments, self.config, self.vm, self.runtime, self.launch_name)
        slot8 = trial.transform(self.arguments, self.config, self.vm, self.runtime, self.launch_name, gpu_slot=8)
        self.assertEqual(len(default), len(slot8))
        changes = [(left, right) for left, right in zip(default, slot8) if left != right]
        self.assertEqual(changes, [('virtio-ramfb-gl,id=display0,addr=0x7,disable-legacy=on,neptune=on,blob=on,hostmem=256M',
            'virtio-ramfb-gl,id=display0,addr=0x8,disable-legacy=on,neptune=on,blob=on,hostmem=256M')])
        self.assertEqual(slot8[slot8.index('-uuid') + 1], trial.CLONE_ID)

    def test_slot8_manifest_binds_choice_through_real_launch_guard(self):
        manifest = trial.prepare_manifest(self.data, trial.CLONE_ID, self.output, gpu_slot=8)
        self.assertEqual(manifest['gpu_slot'], 8)
        self.assertEqual(manifest['purpose'], 'private-exact-clone-cocoa-neptune-app-pci8')
        self.assertEqual(trial.read_json(self.output / 'manifest.json')['gpu_slot'], 8)
        with self.supervisor(manifest):
            actual = trial.validate_launch(manifest, self.arguments)
        self.assertIn('virtio-ramfb-gl,id=display0,addr=0x8,disable-legacy=on,neptune=on,blob=on,hostmem=256M', actual)
        self.assertFalse(any(value.startswith('virtio-ramfb-gl,id=display0,addr=0x7,') for value in actual))

    def test_invalid_gpu_slot_type_or_range_refused_without_output(self):
        for slot in (True, False, '8', 8.0, None, 0, 6, 9, 255):
            with self.subTest(slot=repr(slot)):
                with self.assertRaises(trial.Refused):
                    trial.prepare_manifest(self.data, trial.CLONE_ID, self.output, gpu_slot=slot)
                with self.assertRaises(trial.Refused):
                    trial.transform(self.arguments, self.config, self.vm, self.runtime, self.launch_name, gpu_slot=slot)
        self.assertFalse(self.output.parent.exists())

    def test_gpu_slot_or_purpose_manifest_tamper_refused(self):
        manifest = self.prepare()
        self.assertEqual(manifest['gpu_slot'], 7)
        with self.supervisor(manifest):
            for slot in (8, True, '7', 9, None):
                changed = dict(manifest, gpu_slot=slot)
                with self.subTest(slot=repr(slot)), self.assertRaises(trial.Refused):
                    trial.validate_launch(changed, self.arguments)
            changed = dict(manifest, purpose='private-exact-clone-cocoa-neptune-app-pci8')
            with self.assertRaises(trial.Refused):
                trial.validate_launch(changed, self.arguments)

    def test_generated_wrapper_rejects_coherent_slot_tamper_before_exec(self):
        manifest = self.prepare()
        changed = dict(manifest, gpu_slot=8, purpose='private-exact-clone-cocoa-neptune-app-pci8')
        self.json(self.output / 'manifest.json', changed)
        result = subprocess.run([str(self.output / 'qemu-trial-wrapper'), '--version'], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Trial manifest changed', result.stderr)

    def test_slot8_still_rejects_nonowned_or_readdressed_engine_gpu(self):
        for arguments in ([value.replace('display0,addr=0x7', 'display0,addr=0x8') for value in self.arguments],
                [value.replace('display0,addr=0x7', 'other,addr=0x7') for value in self.arguments],
                self.arguments + ['-device', 'virtio-ramfb,id=other,addr=0x8']):
            with self.assertRaises(trial.Refused):
                trial.transform(arguments, self.config, self.vm, self.runtime, self.launch_name, gpu_slot=8)


if __name__ == '__main__':
    unittest.main(verbosity=2)
