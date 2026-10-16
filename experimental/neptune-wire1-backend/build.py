#!/usr/bin/env python3
"""Build the whole DMTX-v2 DXMT pin into a new private prefix; never launch QEMU."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OLD = ROOT / '.tools/graphics-experiment'
PIN = '917b721c0f915c6524b416169fdce4427a39524f'
HEADERS_PIN = '9df86f2341616ef1888ae59919feaa6d4fad693d'
HEADER = 'src/dxmt-native/dxmt_native.h'
HEADER_SHA = '6a6f4e5528dab829911dd0261079aebea0a03289aaaf5ee66898db7b0d3b7422'
spec = importlib.util.spec_from_file_location('wire1_renderer_recipe', ROOT / 'experimental/neptune-wire1/build.py')
renderer = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(renderer)
FROZEN = dict(renderer.FROZEN)
FROZEN.update({
    '.tools/graphics-wire1/prefix/lib/libvirglrenderer.1.dylib': 'd554a7b740bcd639c9b1aafca63992bbfcc2400f081058143a7fe0a04e17d83c',
    '.tools/graphics-wire1/prefix/libexec/virgl_render_server': 'abb91b15d010fbb5a9637e92043d20b339e5e6a7078115a9f6dfeccec91a927c',
})


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def frozen():
    for name, expected in FROZEN.items():
        assert sha(ROOT / name) == expected, 'Protected artifact changed: ' + name


def capture(command, env):
    result = subprocess.run(list(map(str, command)), env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def inventory(source):
    names = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z']).decode().split('\0')
    return {name: hashlib.sha256(os.readlink(source / name).encode()).hexdigest()
            if (source / name).is_symlink() else sha(source / name)
            for name in filter(None, names) if not (source / name).is_dir()}


def validate_source(source, env):
    assert capture(['git', '-C', source, 'rev-parse', 'HEAD'], env) == PIN
    assert capture(['git', '-C', source, 'status', '--porcelain'], env) == ''
    assert sha(source / HEADER) == HEADER_SHA
    headers = source / 'include/native/directx'
    assert capture(['git', '-C', headers, 'rev-parse', 'HEAD'], env) == HEADERS_PIN
    assert capture(['git', '-C', headers, 'status', '--porcelain'], env) == ''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, default=ROOT / '.tools/graphics-wire1-backend')
    parser.add_argument('--continue-source', action='store_true', help='Build an already fetched, clean exact source; requires absent build/prefix')
    parser.add_argument('--record-existing', action='store_true')
    parser.add_argument('--optimization', choices=('0', '2'), default='0', help='Explicit separate profile optimization; original checkpoint defaults to 0')
    args = parser.parse_args()
    assert not (args.continue_source and args.record_existing)
    base = args.profile.absolute()
    assert base.parent == ROOT / '.tools' and re.fullmatch(r'graphics-wire1-backend(?:-[a-z0-9-]{1,48})?', base.name)
    source = base / 'src/dxmt'; build = base / 'build/dxmt'; prefix = base / 'prefix'
    env = renderer.environment()
    env.update({'CMAKE_BUILD_PARALLEL_LEVEL': '2', 'MAKEFLAGS': '-j2', 'NINJAFLAGS': '-j2', 'PYTHONDONTWRITEBYTECODE': '1'})
    frozen()

    def run(label, command):
        with (base / 'logs' / (label + '.log')).open('w') as output:
            result = subprocess.run(list(map(str, command)), env=env, stdout=output, stderr=subprocess.STDOUT)
        print(label + ' exit ' + str(result.returncode), flush=True)
        assert result.returncode == 0, 'See ' + str(base / 'logs' / (label + '.log'))

    if not args.record_existing:
        if not args.continue_source:
            assert not os.path.lexists(base), 'Fresh profile required'
            (base / 'logs').mkdir(parents=True, mode=0o700)
            source.parent.mkdir()
            run('git-init', ['git', 'init', source])
            run('git-remote', ['git', '-C', source, 'remote', 'add', 'origin', 'https://github.com/utmapp/dxmt.git'])
            run('git-fetch', ['git', '-C', source, 'fetch', '--depth', '1', 'origin', PIN])
            run('git-checkout', ['git', '-C', source, 'checkout', '--detach', PIN])
            run('git-submodule', ['git', '-C', source, 'submodule', 'update', '--init', '--depth', '1', 'include/native/directx'])
        assert not os.path.lexists(build) and not os.path.lexists(prefix)
        validate_source(source, env)
        llvm = OLD / 'llvm15'; zstd = Path('/opt/homebrew/opt/zstd/lib/libzstd.a'); unwind = llvm / 'lib/libunwind.a'
        assert zstd.is_file() and unwind.is_file()
        links = json.dumps([str(zstd), str(unwind)])
        meson = ROOT / '.tools/build-venv/bin/meson'
        run('configure', [meson, 'setup', build, source, '--prefix=' + str(prefix), '--libdir=lib',
            '--buildtype=release', '--wrap-mode=nodownload', '-Doptimization=' + args.optimization,
            '-Dnative_llvm_path=' + str(llvm), '-Denable_d3d12=false', '-Denable_nvapi=false', '-Denable_nvngx=false',
            '-Dcpp_link_args=' + links, '-Dc_link_args=' + links])
        run('compile', [meson, 'compile', '-C', build, '-j', '2'])
        installed = json.loads(capture([meson, 'introspect', '--installed', build], env))
        assert all(Path(path).is_relative_to(prefix) for path in installed.values())
        run('install-private', [meson, 'install', '-C', build, '--no-rebuild'])

    validate_source(source, env)
    provenance = base / 'provenance'; provenance.mkdir(exist_ok=True)
    files = {'repository': inventory(source), 'directx_headers': inventory(source / 'include/native/directx')}
    (provenance / 'source-files.json').write_text(json.dumps(files, indent=2, sort_keys=True) + '\n')
    llvm_inputs = {str(path.relative_to(OLD / 'llvm15')): sha(path) for path in sorted((OLD / 'llvm15/lib').glob('*.a'))}
    (provenance / 'llvm-static-inputs.json').write_text(json.dumps(llvm_inputs, indent=2, sort_keys=True) + '\n')
    binary = prefix / 'lib/libdxmt-native.dylib'
    capture(['/usr/bin/codesign', '--verify', '--strict', binary], env)
    commands = build / 'compile_commands.json'
    assert str(OLD / 'src/dxmt') not in commands.read_text(), 'Original/new ABI source leaked into build'
    options = json.loads(capture([ROOT / '.tools/build-venv/bin/meson', 'introspect', '--buildoptions', build], env))
    settings = {entry['name']: entry['value'] for entry in options}
    assert settings['optimization'] == args.optimization, 'Built optimization does not match requested profile'
    report = {'schema': 1, 'source_url': 'https://github.com/utmapp/dxmt.git', 'source_pin': PIN,
        'source_tree': capture(['git', '-C', source, 'rev-parse', 'HEAD^{tree}'], env), 'source_clean': True,
        'source_patches': [], 'source_inventory_sha256': sha(provenance / 'source-files.json'),
        'source_files': {key: len(value) for key, value in files.items()}, 'directx_headers_pin': HEADERS_PIN,
        'disabled_unfetched_nvapi_pin': 'd08488fcc82eef313b0464db37d2955709691e94',
        'native_header_sha256': HEADER_SHA, 'shared_texture_ABI': {'magic': 'DMTX', 'version': 2, 'size_bytes': 72, 'fd_offset': 8},
        'compile_commands_sha256': sha(commands), 'build_options': settings,
        'tools': {'python': sys.version, 'meson': capture([ROOT / '.tools/build-venv/bin/meson', '--version'], env),
            'ninja': capture([ROOT / '.tools/build-venv/bin/ninja', '--version'], env), 'clang': capture(['xcrun', 'clang++', '--version'], env),
            'metal': capture(['xcrun', 'metal', '--version'], env), 'sdk': capture(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env)},
        'binary': {'path': str(binary.relative_to(ROOT)), 'sha256': sha(binary), 'architectures': capture(['/usr/bin/lipo', '-archs', binary], env),
            'dependencies': capture(['/usr/bin/otool', '-L', binary], env), 'strict_signature_verified': True},
        'reused_dependencies': {str(p): sha(p) for p in [OLD / 'provenance/llvm15.json', OLD / 'llvm15/extraction.json',
            Path('/opt/homebrew/opt/zstd/lib/libzstd.a'), OLD / 'llvm15/lib/libunwind.a']},
        'llvm_version': json.loads((OLD / 'provenance/llvm15.json').read_text())['version'],
        'llvm_static_inputs': {'files': len(llvm_inputs), 'inventory_sha256': sha(provenance / 'llvm-static-inputs.json')},
        'zstd_actual_path': str(Path('/opt/homebrew/opt/zstd/lib/libzstd.a').resolve()),
        'renderer_recipe_sha256': sha(ROOT / 'experimental/neptune-wire1/build.py'),
        'licenses': {name: sha(source / name) for name in ('LICENSE', 'COPYING.LIB', 'LICENSE.OLD')},
        'max_jobs': 2, 'protected_sha256': FROZEN, 'Windows_tested_by_recipe': False}
    frozen()
    (provenance / 'build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'source_pin': PIN, 'binary': report['binary'], 'originals_unchanged': True}, indent=2))


if __name__ == '__main__':
    main()
