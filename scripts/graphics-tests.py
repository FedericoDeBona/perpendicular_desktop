#!/usr/bin/env python3
"""Network-free tests for the experiment's pin checks and selective LLVM extraction."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('graphics_fetch', Path(__file__).with_name('graphics-fetch.py'))
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)


class GraphicsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='perpendicular-graphics-test-')
        self.base = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_registered_pins(self):
        lock = fetch.LOCK
        for item in lock['sources'] + lock['qemu_wraps']:
            self.assertRegex(item['revision'], r'^[0-9a-f]{40}$')
        for item in lock['sources']:
            for wrapped in item.get('wraps', {}).values():
                self.assertEqual(wrapped['revision'], next(s['revision'] for s in lock['sources'] if s['name']=='directx-native'))
        webkit = next(s for s in lock['sources'] if s['name']=='WebKit')
        self.assertEqual(set(webkit['sparse']), {'Source/ThirdParty/ANGLE','Configurations','Tools/ccache'})

    def test_wrap_change_is_rejected(self):
        p = self.base / 'selected.wrap'
        expected = {'url':'https://example.invalid/repo.git','revision':'a'*40}
        p.write_text('[wrap-git]\nurl = https://example.invalid/repo.git\nrevision = ' + 'a'*40 + '\n')
        fetch.verify_wrap(p, expected)
        p.write_text(p.read_text().replace('a'*40, 'b'*40))
        with self.assertRaisesRegex(ValueError, 'differs from lock'):
            fetch.verify_wrap(p, expected)

    def test_interrupted_initial_fetch_resumes_without_resetting_files(self):
        origin = self.base / 'origin'
        origin.mkdir()
        fetch.git(origin, 'init', '--quiet')
        (origin/'pinned.txt').write_text('original pinned source\n')
        fetch.git(origin, 'add', 'pinned.txt')
        fetch.git(origin, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                  '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
                  'commit', '--quiet', '-m', 'Fixture pin')
        revision = fetch.git(origin, 'rev-parse', 'HEAD')
        source = self.base / 'src/selected'
        source.mkdir(parents=True)
        fetch.git(source, 'init', '--quiet')
        fetch.git(source, 'remote', 'add', 'origin', str(origin))
        selected = {'name':'selected', 'url':str(origin), 'revision':revision}
        with patch.object(fetch, 'SRC', self.base/'src'):
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                fetch.checkout(selected, verify=True)
            (source/'do-not-overwrite.txt').write_text('keep this file')
            with self.assertRaisesRegex(ValueError, 'Refusing files'):
                fetch.checkout(selected)
            self.assertEqual((source/'do-not-overwrite.txt').read_text(), 'keep this file')
            (source/'do-not-overwrite.txt').unlink()
            fetch.checkout(selected)
            fetch.checkout(selected, verify=True)
        self.assertEqual((source/'pinned.txt').read_text(), 'original pinned source\n')

    def fixture_bottle(self, extra=None):
        archive = self.base / 'downloads/llvm15-arm64-sonoma.tar.gz'
        archive.parent.mkdir(parents=True)
        entries = {
            'include/llvm/Config/llvm-config.h': b'#define LLVM_VERSION_MAJOR 15\n',
            'lib/libLLVMSupport.a': b'fixture static library',
            'lib/libunwind.a': b'fixture unwind',
            'bin/never-execute': b'not selected',
            'lib/never-load.dylib': b'not selected',
            'LICENSE.TXT': b'fixture bundled notice'
        }
        entries.update(extra or {})
        with tarfile.open(archive, 'w:gz') as tar:
            for name, data in entries.items():
                entry = tarfile.TarInfo('llvm@15/15.0.7/' + name)
                entry.size = len(data)
                tar.addfile(entry, io.BytesIO(data))
            link = tarfile.TarInfo('llvm@15/15.0.7/include/unsafe-symlink')
            link.type = tarfile.SYMTYPE
            link.linkname = '/tmp/not-a-target'
            tar.addfile(link)
        formula = self.base / 'provenance/llvm15-homebrew-formula.rb'
        formula.parent.mkdir(parents=True)
        formula.write_bytes(b'fixture pinned formula')
        license_path = self.base / 'provenance/licenses/llvm15/LICENSE.TXT'
        license_path.parent.mkdir(parents=True)
        license_path.write_bytes(b'fixture pinned LLVM license')
        lock = copy.deepcopy(fetch.LOCK)
        lock['llvm_bottle'].update(sha256=fetch.sha(archive), bytes=archive.stat().st_size,
            formula_sha256=fetch.sha(formula), license_sha256=fetch.sha(license_path))
        return lock

    def extract(self, lock, verify=False):
        with patch.object(fetch, 'BASE', self.base), patch.object(fetch, 'LOCK', lock), \
                patch.object(fetch, 'download'), patch('urllib.request.urlopen', return_value=io.BytesIO(b'{"token":"fixture"}')):
            fetch.llvm_bottle(verify)

    def test_extract_only_headers_static_and_notices_then_verify(self):
        lock = self.fixture_bottle()
        self.extract(lock)
        root = self.base / 'llvm15'
        self.assertTrue((root/'include/llvm/Config/llvm-config.h').is_file())
        self.assertTrue((root/'lib/libLLVMSupport.a').is_file())
        self.assertTrue((root/'LICENSE.TXT').is_file())
        self.assertFalse((root/'bin').exists())
        self.assertFalse((root/'lib/never-load.dylib').exists())
        self.assertFalse((root/'include/unsafe-symlink').exists())
        self.extract(lock, verify=True)
        (root/'lib/libLLVMSupport.a').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'file changed'):
            self.extract(lock, verify=True)

    def test_unsafe_archive_path_rejected_and_partial_removed(self):
        lock = self.fixture_bottle({'include/../../escaped':b'must not write'})
        with self.assertRaisesRegex(ValueError, 'Unsafe path'):
            self.extract(lock)
        self.assertFalse((self.base/'llvm15').exists())
        self.assertFalse((self.base/'escaped').exists())

    def test_bad_bottle_hash_rejected_before_extraction(self):
        lock = self.fixture_bottle()
        lock['llvm_bottle']['sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'bottle is missing or changed'):
            self.extract(lock)
        self.assertFalse((self.base/'llvm15').exists())

    def test_python_tools_select_only_pure_python_and_reject_tampering(self):
        archive = self.base/'downloads/pyyaml-6.0.3.tar.gz'
        archive.parent.mkdir()
        with tarfile.open(archive, 'w:gz') as tar:
            for name, data in {'lib/yaml/__init__.py':b'__version__="6.0.3"\n',
                               'lib/yaml/parser.py':b'# pure Python fixture\n',
                               'LICENSE':b'MIT fixture', 'setup.py':b'must not run',
                               'yaml/_yaml.so':b'must not load'}.items():
                item = tarfile.TarInfo('pyyaml-6.0.3/'+name)
                item.size = len(data)
                tar.addfile(item, io.BytesIO(data))
        lock = copy.deepcopy(fetch.LOCK)
        lock['pyyaml'].update(sha256=fetch.sha(archive), bytes=archive.stat().st_size)
        with patch.object(fetch, 'BASE', self.base), patch.object(fetch, 'LOCK', lock), patch.object(fetch, 'download'):
            fetch.python_tools()
            fetch.python_tools(verify=True)
            target = self.base/'python-deps'
            self.assertEqual({str(p.relative_to(target)) for p in target.rglob('*') if p.is_file()},
                {'yaml/__init__.py','yaml/parser.py','LICENSE-PyYAML.txt','extraction.json'})
            (target/'yaml/parser.py').write_text('changed')
            with self.assertRaisesRegex(ValueError, 'file changed'):
                fetch.python_tools(verify=True)

    def test_python_tools_reject_unsafe_archive_without_partial_install(self):
        archive = self.base/'downloads/pyyaml-6.0.3.tar.gz'
        archive.parent.mkdir()
        with tarfile.open(archive, 'w:gz') as tar:
            item = tarfile.TarInfo('pyyaml-6.0.3/lib/yaml/../../escape.py')
            item.size = 1
            tar.addfile(item, io.BytesIO(b'x'))
        lock = copy.deepcopy(fetch.LOCK)
        lock['pyyaml'].update(sha256=fetch.sha(archive), bytes=archive.stat().st_size)
        with patch.object(fetch, 'BASE', self.base), patch.object(fetch, 'LOCK', lock), patch.object(fetch, 'download'):
            with self.assertRaisesRegex(ValueError, 'Unsafe path'):
                fetch.python_tools()
        self.assertFalse((self.base/'python-deps').exists())
        self.assertFalse((self.base/'escape.py').exists())


if __name__ == '__main__':
    unittest.main()
