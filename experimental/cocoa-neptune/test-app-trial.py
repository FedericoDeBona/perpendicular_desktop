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


if __name__ == '__main__':
    unittest.main(verbosity=2)
