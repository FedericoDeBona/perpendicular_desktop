#!/usr/bin/env python3
"""Fetch only pinned sources into .tools/graphics-experiment; never recurse implicitly."""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

REPO = Path(__file__).resolve().parent.parent
BASE = REPO / '.tools' / 'graphics-experiment'
SRC = BASE / 'src'
LOCK_PATH = Path(__file__).with_name('graphics-sources.json')
LOCK = json.loads(LOCK_PATH.read_text())


def run(args, cwd=None):
    result = subprocess.run([str(x) for x in args], cwd=cwd, check=True,
                            stdout=subprocess.PIPE, text=True)
    return result.stdout.strip()


def git(path, *args):
    return run(['git', '-c', 'submodule.recurse=false', '-C', path, *args])


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def checkout(spec, verify=False):
    name, revision = spec['name'], spec['revision']
    if len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision):
        raise ValueError('Source revision must be an immutable full Git SHA: ' + name)
    path = SRC / name
    if path.is_symlink():
        raise ValueError('Source directory is a symlink: ' + name)
    if not (path / '.git').is_dir():
        if verify:
            raise ValueError('Source is missing: ' + name)
        if path.exists() and any(path.iterdir()):
            raise ValueError('Refusing a nonempty unmanaged source: ' + name)
        path.mkdir(parents=True, exist_ok=True)
        git(path, 'init', '--quiet')
        git(path, 'remote', 'add', 'origin', spec['url'])
        if spec.get('sparse'):
            git(path, 'sparse-checkout', 'init', '--cone')
            git(path, 'sparse-checkout', 'set', *spec['sparse'])
    if git(path, 'config', '--get', 'remote.origin.url') != spec['url']:
        raise ValueError('Unexpected source remote: ' + name)
    head = subprocess.run(['git', '-C', str(path), 'rev-parse', '--verify', 'HEAD'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if head.returncode:
        if verify:
            raise ValueError('Source checkout is incomplete: ' + name)
        # A failed/interrupted initial network fetch may leave only Git metadata.
        # Resume that exact pinned fetch without resetting or deleting any files.
        if any(item.name != '.git' for item in path.iterdir()):
            raise ValueError('Refusing files in an incomplete source: ' + name)
        fetch = ['fetch', '--depth=1', '--no-tags']
        if spec.get('sparse'):
            fetch.append('--filter=blob:none')
        git(path, *fetch, 'origin', revision)
        git(path, 'checkout', '--quiet', '--detach', revision)
    if git(path, 'rev-parse', 'HEAD') != revision:
        raise ValueError('Unexpected source revision: ' + name)
    if git(path, 'status', '--porcelain', '--untracked-files=no', '--ignore-submodules=none'):
        raise ValueError('Source has tracked changes: ' + name)
    if spec.get('sparse') and set(git(path, 'sparse-checkout', 'list').splitlines()) != set(spec['sparse']):
        raise ValueError('Sparse checkout differs from lock: ' + name)
    if spec.get('parent_gitlink'):
        parent, relative = spec['parent_gitlink']
        record = git(SRC / parent, 'ls-tree', 'HEAD', '--', relative).split()
        if record[:3] != ['160000', 'commit', revision]:
            raise ValueError('Submodule does not match parent gitlink: ' + name)
    for relative, expected in spec.get('gitlinks', {}).items():
        record = git(path, 'ls-tree', 'HEAD', '--', relative).split()
        if record[:3] != ['160000', 'commit', expected]:
            raise ValueError('Parent gitlink changed: ' + name + '/' + relative)
    for relative, expected in spec.get('wraps', {}).items():
        verify_wrap(path / relative, expected)
    print('Verified source:', name, revision, flush=True)
    return path


def verify_wrap(path, expected):
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(path)
    if not parser.has_section('wrap-git'):
        raise ValueError('Expected a Git wrap: ' + str(path))
    for field in ('url', 'revision', 'patch_directory'):
        if field in expected and parser['wrap-git'].get(field) != expected[field]:
            raise ValueError('Wrap ' + field + ' differs from lock: ' + str(path))


def qemu_wraps(verify):
    for spec in LOCK['qemu_wraps']:
        parent = SRC / 'qemu'
        verify_wrap(parent / 'subprojects' / (spec['name'] + '.wrap'), spec)
        selected = dict(spec, name='qemu/subprojects/' + spec['name'])
        path = checkout(selected, verify)
        if spec.get('patch_directory'):
            overlay = parent / 'subprojects' / 'packagefiles' / spec['patch_directory']
            for original in overlay.rglob('*'):
                if original.is_file():
                    target = path / original.relative_to(overlay)
                    if verify:
                        if not target.is_file() or sha(target) != sha(original):
                            raise ValueError('QEMU package overlay differs: ' + str(target))
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        if target.exists() and sha(target) != sha(original):
                            raise ValueError('Refusing an altered overlay: ' + str(target))
                        shutil.copy2(original, target)


def audit():
    records = []
    specs = list(LOCK['sources'])
    for spec in LOCK['qemu_wraps']:
        name = 'qemu/subprojects/' + spec['name']
        if (SRC / name / '.git').is_dir():
            specs.append(dict(spec, name=name))
    for spec in specs:
        path = SRC / spec['name']
        record = {'name': spec['name'], 'url': spec['url'], 'revision': spec['revision'],
                  'tree': git(path, 'rev-parse', 'HEAD^{tree}'), 'gitlinks': [], 'wraps': [], 'licenses': [],
                  'vendored_python_wheels': []}
        module_urls = {}
        if (path / '.gitmodules').is_file():
            modules = configparser.ConfigParser(interpolation=None)
            modules.read(path / '.gitmodules')
            module_urls = {modules[section]['path']: modules[section]['url'] for section in modules.sections()}
        for line in git(path, 'ls-tree', '-r', 'HEAD').splitlines():
            metadata, relative = line.split('\t', 1)
            if metadata.startswith('160000 '):
                record['gitlinks'].append({'path': relative, 'revision': metadata.split()[2], 'url': module_urls.get(relative),
                                           'fetched': (path / relative / '.git').exists()})
        for wrap in sorted((path / 'subprojects').glob('*.wrap')):
            parser = configparser.ConfigParser(interpolation=None)
            parser.read(wrap)
            record['wraps'].append({'path': str(wrap.relative_to(path)), 'sha256': sha(wrap),
                                    'sections': {section: dict(parser[section]) for section in parser.sections()}})
        license_candidates = [p for p in path.iterdir() if p.is_file() and
                              any(t in p.name.lower() for t in ('license', 'copying', 'notice'))]
        for relative in spec.get('licenses', []):
            item = path / relative
            if item.is_file():
                license_candidates.append(item)
            elif item.is_dir():
                license_candidates.extend(p for p in item.rglob('*') if p.is_file() and
                    any(t in p.name.lower() for t in ('license', 'copying', 'notice')))
            else:
                raise ValueError('Expected license file missing: ' + str(item))
        for license_path in sorted(set(license_candidates)):
            relative = license_path.relative_to(path)
            target = BASE / 'provenance' / 'licenses' / spec['name'] / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(license_path, target)
            record['licenses'].append({'path': str(relative), 'sha256': sha(license_path)})
        for wheel in sorted((path / 'python/wheels').glob('*.whl')):
            wheel_record = {'path': str(wheel.relative_to(path)), 'sha256': sha(wheel), 'licenses': []}
            with zipfile.ZipFile(wheel) as bundled:
                for name in bundled.namelist():
                    relative = PurePosixPath(name)
                    if relative.is_absolute() or '..' in relative.parts:
                        raise ValueError('Unsafe path in vendored wheel')
                    if any(t in relative.name.lower() for t in ('license', 'copying', 'notice')) and not name.endswith('/'):
                        data = bundled.read(name)
                        target = BASE / 'provenance/licenses' / spec['name'] / 'wheels' / wheel.name / str(relative)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(data)
                        wheel_record['licenses'].append({'path': name, 'sha256': hashlib.sha256(data).hexdigest()})
            record['vendored_python_wheels'].append(wheel_record)
        records.append(record)
    write_json(BASE / 'provenance' / 'sources.json', {
        'lock_sha256': sha(LOCK_PATH), 'sources': records,
        'policy': 'No recursive submodule update. Unused gitlinks/wraps are recorded, not fetched. ' +
                  'Meson builds use nodownload. QEMU wrap overlays come only from its pinned tree.'})
    shutil.copy2(LOCK_PATH, BASE / 'provenance' / 'graphics-sources.json')


def download(url, path, expected_hash, max_bytes, headers=None):
    if path.exists():
        if sha(path) != expected_hash:
            raise ValueError('Cached download has wrong SHA-256: ' + str(path))
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + '.partial')
    try:
        request = urllib.request.Request(url, headers=headers or {})
        with urllib.request.urlopen(request, timeout=60) as response, partial.open('wb') as target:
            count = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                count += len(chunk)
                if count > max_bytes:
                    raise ValueError('Download exceeds its size bound')
                target.write(chunk)
        if sha(partial) != expected_hash:
            raise ValueError('Downloaded SHA-256 does not match lock: ' + str(path))
        partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)


def llvm_bottle(verify=False):
    spec = LOCK['llvm_bottle']
    archive = BASE / 'downloads' / 'llvm15-arm64-sonoma.tar.gz'
    formula = BASE / 'provenance' / 'llvm15-homebrew-formula.rb'
    license_path = BASE / 'provenance/licenses/llvm15/LICENSE.TXT'
    target = BASE / 'llvm15'
    if target.is_symlink():
        raise ValueError('LLVM target must not be a symlink')
    if not verify:
        download(spec['formula_source'], formula, spec['formula_sha256'], 128 * 1024)
        download(spec['license_url'], license_path, spec['license_sha256'], 128 * 1024)
        if not archive.exists():
            token_request = 'https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/llvm/15:pull'
            with urllib.request.urlopen(token_request, timeout=30) as response:
                token = json.load(response)['token']
            download(spec['url'], archive, spec['sha256'], spec['bytes'], {'Authorization': 'Bearer ' + token})
    if not archive.is_file() or sha(archive) != spec['sha256']:
        raise ValueError('LLVM bottle is missing or changed; run --llvm-bottle')
    if not formula.is_file() or sha(formula) != spec['formula_sha256']:
        raise ValueError('LLVM formula provenance is missing or changed')
    if not license_path.is_file() or sha(license_path) != spec['license_sha256']:
        raise ValueError('LLVM license provenance is missing or changed')
    receipt_path = target / 'extraction.json'
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get('archive_sha256') != spec['sha256']:
            raise ValueError('LLVM extraction receipt mismatch')
        for item in receipt['files']:
            p = target / item['path']
            if p.is_symlink() or not p.is_file() or sha(p) != item['sha256']:
                raise ValueError('LLVM extracted file changed: ' + str(p))
    elif verify:
        raise ValueError('LLVM extraction receipt missing')
    else:
        if target.exists():
            raise ValueError('Refusing unmanaged LLVM directory')
        target.mkdir(parents=True)
        receipt = {'archive_sha256': spec['sha256'], 'files': [],
                   'selection': 'Static libraries, headers and notices only; no executables/dylibs/relocation'}
        try:
            with tarfile.open(archive, 'r:gz') as source:
                for member in source:
                    parts = PurePosixPath(member.name).parts
                    if len(parts) < 3 or parts[:2] != ('llvm@15', '15.0.7'):
                        continue
                    relative = PurePosixPath(*parts[2:])
                    selected = (relative.parts[0] == 'include' or
                                relative.parts[0] == 'lib' and relative.suffix == '.a' or
                                any(t in relative.name.lower() for t in ('license', 'copying', 'notice')))
                    if not selected or not member.isfile():
                        continue
                    if relative.is_absolute() or '..' in relative.parts:
                        raise ValueError('Unsafe path in LLVM bottle')
                    output = target / str(relative)
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as data, output.open('wb') as destination:
                        shutil.copyfileobj(data, destination)
                    receipt['files'].append({'path': str(relative), 'sha256': sha(output)})
            if not (target / 'include/llvm/Config/llvm-config.h').is_file() or not (target / 'lib/libLLVMSupport.a').is_file():
                raise ValueError('Bottle lacks required LLVM headers/static libraries')
            write_json(receipt_path, receipt)
        except BaseException:
            shutil.rmtree(target)
            raise
    write_json(BASE / 'provenance' / 'llvm15.json', dict(spec, extraction=str(receipt_path.relative_to(BASE))))
    print('Verified LLVM 15 headers/static libraries:', target, flush=True)


def python_tools(verify=False):
    """Select pure Python YAML sources only; never execute setup.py or install globally."""
    spec = LOCK['pyyaml']
    archive = BASE / 'downloads' / ('pyyaml-' + spec['version'] + '.tar.gz')
    target = BASE / 'python-deps'
    receipt_path = target / 'extraction.json'
    if not verify:
        download(spec['url'], archive, spec['sha256'], spec['bytes'])
    if not archive.is_file() or sha(archive) != spec['sha256']:
        raise ValueError('PyYAML archive is missing or changed; run --python-tools')
    if target.is_symlink():
        raise ValueError('Python tools target must not be a symlink')
    if receipt_path.is_file():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get('archive_sha256') != spec['sha256']:
            raise ValueError('PyYAML extraction receipt mismatch')
        for item in receipt['files']:
            path = target / item['path']
            if path.is_symlink() or not path.is_file() or sha(path) != item['sha256']:
                raise ValueError('PyYAML extracted file changed: ' + str(path))
    elif verify:
        raise ValueError('PyYAML extraction receipt missing')
    else:
        if target.exists():
            raise ValueError('Refusing unmanaged Python tools directory')
        target.mkdir(parents=True)
        receipt = {'archive_sha256': spec['sha256'], 'files': [],
                   'selection': 'Pure Python yaml package and MIT license only; no setup.py/native extension'}
        try:
            total = 0
            with tarfile.open(archive, 'r:gz') as source:
                for member in source:
                    path = PurePosixPath(member.name)
                    if path.is_absolute() or '..' in path.parts:
                        raise ValueError('Unsafe path in PyYAML archive')
                    if not member.isfile() or path.parts[0] != 'pyyaml-' + spec['version']:
                        continue
                    relative = PurePosixPath(*path.parts[1:])
                    if len(relative.parts) == 3 and relative.parts[:2] == ('lib', 'yaml') and relative.suffix == '.py':
                        output = target / 'yaml' / relative.name
                    elif str(relative) == 'LICENSE':
                        output = target / 'LICENSE-PyYAML.txt'
                    else:
                        continue
                    total += member.size
                    if member.size > 1024 * 1024 or total > 8 * 1024 * 1024:
                        raise ValueError('PyYAML selected sources exceed size bound')
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as data, output.open('wb') as destination:
                        shutil.copyfileobj(data, destination)
                    receipt['files'].append({'path': str(output.relative_to(target)), 'sha256': sha(output)})
            if not (target / 'yaml/__init__.py').is_file() or not (target / 'LICENSE-PyYAML.txt').is_file():
                raise ValueError('PyYAML archive lacks package or license')
            write_json(receipt_path, receipt)
        except BaseException:
            shutil.rmtree(target)
            raise
    license_path = BASE / 'provenance/licenses/pyyaml/LICENSE'
    license_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(target / 'LICENSE-PyYAML.txt', license_path)
    write_json(BASE / 'provenance/pyyaml.json', dict(spec, extraction=str(receipt_path.relative_to(BASE))))
    print('Verified private pure Python PyYAML:', target, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true', help='verify existing sources without network')
    parser.add_argument('--llvm-bottle', action='store_true', help='fetch/extract official pinned LLVM15 static libraries/headers')
    parser.add_argument('--qemu-wraps', action='store_true', help='also populate the six recorded QEMU build wraps')
    parser.add_argument('--python-tools', action='store_true', help='extract pinned pure Python YAML build dependency privately')
    args = parser.parse_args()
    if args.verify:
        # A partial/sparse clone must fail verification rather than lazily
        # fetching a missing blob behind this explicitly offline command.
        os.environ['GIT_NO_LAZY_FETCH'] = '1'
    BASE.mkdir(parents=True, exist_ok=True)
    if BASE.is_symlink() or SRC.is_symlink():
        raise ValueError('Experiment root must not be a symlink')
    for spec in LOCK['sources']:
        checkout(spec, args.verify)
    # Create only these two pinned Meson fallbacks; no GitHub SSH or recursive fetching.
    for parent in ('dxmt', 'virglrenderer'):
        destination = SRC / parent / 'subprojects/directx-native'
        expected = os.path.relpath(SRC / 'directx-native', destination.parent)
        if destination.is_symlink():
            if os.readlink(destination) != expected:
                raise ValueError('Unexpected directx-native fallback link')
        elif destination.exists():
            raise ValueError('Unmanaged directx-native fallback')
        elif args.verify:
            raise ValueError('Missing directx-native fallback')
        else:
            destination.symlink_to(expected, target_is_directory=True)
    if args.qemu_wraps:
        qemu_wraps(args.verify)
    audit()
    if args.llvm_bottle:
        llvm_bottle(args.verify)
    if args.python_tools:
        python_tools(args.verify)
    print('Experimental source provenance:', BASE / 'provenance/sources.json', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit('Graphics fetch stopped: ' + str(error))
