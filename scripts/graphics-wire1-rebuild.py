#!/usr/bin/env python3
"""Rebuild whole matching Wire1 sources against this host, without archived binaries or a VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
COMMON = ROOT / '.tools/graphics-experiment'
MESON = ROOT / '.tools/build-venv/bin/meson'
GIT = '/Library/Developer/CommandLineTools/usr/bin/git'
PINS = {
    'backend': {'repo': 'dxmt', 'pin': '917b721c0f915c6524b416169fdce4427a39524f',
                'header': 'src/dxmt-native/dxmt_native.h',
                'header_sha256': '6a6f4e5528dab829911dd0261079aebea0a03289aaaf5ee66898db7b0d3b7422'},
    'renderer': {'repo': 'virglrenderer', 'pin': 'd3c970599eb0bfbfe417b86d87fc0e0641da9512',
                 'header': 'src/neptune/neptune-protocol/npt_protocol_defs.h',
                 'header_sha256': '30c843d723860bfda07d1c6e72262d56dc5224f9ffb61d0d8f9f7e645a4ec402'},
}
HEADERS_PIN = '9df86f2341616ef1888ae59919feaa6d4fad693d'


def require(value, message):
    if not value:
        raise RuntimeError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def source_inventory(source, env):
    require(not subprocess.check_output([GIT, '-C', str(source), 'status', '--porcelain'], env=env),
            'Source must remain clean: ' + str(source))
    files = subprocess.check_output([GIT, '-C', str(source), 'ls-files', '-z'], env=env).decode().split('\0')
    return {name: hashlib.sha256(os.readlink(source / name).encode()).hexdigest()
            if (source / name).is_symlink() else sha(source / name)
            for name in filter(None, files) if not (source / name).is_dir()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', choices=PINS, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--optimization', choices=('2', '3'), default='3')
    parser.add_argument('--source-only', action='store_true', help='Fetch and validate sources without configuring or compiling')
    parser.add_argument('--resume', action='store_true', help='Continue only the same recorded profile and protected inputs')
    args = parser.parse_args()
    base = args.output.absolute()
    require(base.parent.resolve() == (ROOT / '.tools').resolve() and not base.is_symlink() and
            re.fullmatch(r'graphics-rebuild-[a-z0-9-]{1,64}', base.name), 'Output must be a new .tools/graphics-rebuild-* profile')
    base = base.parent.resolve() / base.name
    pin = PINS[args.component]
    plan = {'schema': 1, 'component': args.component, 'source': pin,
            'optimization': args.optimization, 'output': str(base), 'max_jobs': 2}
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('DYLD_', 'QEMU_', 'VIRGL_', 'NPT_', 'ANGLE_'))}
    env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
               PATH=str(MESON.parent) + ':' + env.get('PATH', ''),
               PYTHONPATH=str(COMMON / 'python-deps'), PYTHONDONTWRITEBYTECODE='1',
               PKG_CONFIG_PATH=str(COMMON / 'prefix/lib/pkgconfig'),
               DYLD_FALLBACK_LIBRARY_PATH=str(COMMON / 'prefix/lib') + ':' +
                   str(COMMON / 'prefix/ANGLE.xcarchive/Products/usr/local/lib'),
               CMAKE_BUILD_PARALLEL_LEVEL='2', MAKEFLAGS='-j2', NINJAFLAGS='-j2')
    if args.resume:
        require((base / 'plan.json').is_file() and json.loads((base / 'plan.json').read_text()) == plan,
                'Resume requires the exact recorded component, pin, output and optimization')
    else:
        require(not os.path.lexists(base), 'Fresh output required; use --resume for this exact profile')
        base.mkdir(mode=0o700)
        (base / 'logs').mkdir()
        save(base / 'plan.json', plan)
        app = Path('/Applications/Perpendicular Desktop.app')
        require(app.is_dir(), 'Installed application required for the current-host preservation baseline')
        save(base / 'protected.json', {str(p): sha(p) for p in sorted(app.rglob('*')) if p.is_file()})
    protected = json.loads((base / 'protected.json').read_text())
    require(protected, 'Empty application preservation baseline')

    def verify_protected():
        for name, expected in protected.items():
            require(sha(Path(name)) == expected, 'Installed application changed during build: ' + name)

    verify_protected()

    def run(label, command):
        log = base / 'logs' / (label + '-' + str(time.time_ns()) + '.log')
        print(label + ': ' + str(log.relative_to(ROOT)), flush=True)
        with log.open('w') as output:
            output.write(json.dumps({'argv': list(map(str, command))}) + '\n'); output.flush()
            result = subprocess.run(list(map(str, command)), env=env, stdout=output, stderr=subprocess.STDOUT)
        require(result.returncode == 0, label + ' failed; see ' + str(log))

    def capture(command):
        return subprocess.check_output(list(map(str, command)), env=env, text=True).strip()

    source = base / 'src' / pin['repo']
    require(not source.is_symlink() and source.resolve().is_relative_to(base), 'Source path escaped profile')
    if not source.exists():
        source.parent.mkdir()
        run('git-init', [GIT, 'init', source])
        run('git-remote', [GIT, '-C', source, 'remote', 'add', 'origin', 'https://github.com/utmapp/' + pin['repo'] + '.git'])
        run('git-fetch', [GIT, '-C', source, 'fetch', '--depth', '1', 'origin', pin['pin']])
        run('git-checkout', [GIT, '-C', source, 'checkout', '--detach', pin['pin']])
        if args.component == 'backend':
            run('git-headers', [GIT, '-C', source, 'submodule', 'update', '--init', '--depth', '1', 'include/native/directx'])
    require(capture([GIT, '-C', source, 'rev-parse', 'HEAD']) == pin['pin'], 'Whole source pin mismatch')
    require(sha(source / pin['header']) == pin['header_sha256'], 'Protocol/native ABI header mismatch')
    inventory = {'repository': source_inventory(source, env)}
    if args.component == 'backend':
        headers = source / 'include/native/directx'
        require(capture([GIT, '-C', headers, 'rev-parse', 'HEAD']) == HEADERS_PIN, 'DirectX headers pin mismatch')
        inventory['directx_headers'] = source_inventory(headers, env)
    else:
        require(re.search(r'#define\s+NPT_PROTOCOL_WIRE_VERSION\s+1u\b', (source / pin['header']).read_text()), 'Expected Wire1 protocol')
    save(base / 'source-files.json', inventory)
    if args.source_only:
        verify_protected()
        print('Exact whole source/header pins verified; no compiler, runtime or VM launched.', flush=True)
        return

    build, prefix = base / 'build', base / 'prefix'
    require(all(not p.is_symlink() and p.resolve().is_relative_to(base) for p in (build, prefix)),
            'Build or install prefix escaped profile')
    run('verify-common', [sys.executable, ROOT / 'scripts/graphics-fetch.py', '--verify', '--llvm-bottle', '--python-tools'])
    if args.component == 'backend':
        llvm = COMMON / 'llvm15'
        dependencies = sorted((llvm / 'lib').glob('*.a')) + [COMMON / 'provenance/llvm15.json',
            llvm / 'extraction.json', Path('/opt/homebrew/opt/zstd/lib/libzstd.a')]
        require(len(dependencies) > 3, 'Verified private LLVM dependencies are missing')
        link = json.dumps([str(Path('/opt/homebrew/opt/zstd/lib/libzstd.a')), str(llvm / 'lib/libunwind.a')])
        options = ['-Dnative_llvm_path=' + str(llvm), '-Denable_d3d12=false', '-Denable_nvapi=false',
                   '-Denable_nvngx=false', '-Dcpp_link_args=' + link, '-Dc_link_args=' + link]
        binaries = [prefix / 'lib/libdxmt-native.dylib']
    else:
        angle = COMMON / 'prefix/ANGLE.xcarchive/Products/usr/local/lib'
        dependencies = [angle / 'libEGL.dylib', angle / 'libGLESv2.dylib',
                        COMMON / 'prefix/lib/libepoxy.0.dylib', COMMON / 'prefix/lib/pkgconfig/epoxy.pc']
        options = ['-Dc_args=-I' + str(COMMON / 'src/WebKit/Source/ThirdParty/ANGLE/include'),
                   '-Dplatforms=egl', '-Dneptune=true', '-Dvenus=false', '-Dvtest=false',
                   '-Drender-server-mode=process', '-Drender-server-worker=process',
                   '-Dcheck-gl-errors=false', '-Dtracing=none']
        binaries = [prefix / 'lib/libvirglrenderer.1.dylib', prefix / 'libexec/virgl_render_server']
    actual_dependencies = {str(p): sha(p) for p in dependencies}
    dependency_file = base / 'dependencies.json'
    if dependency_file.exists():
        require(json.loads(dependency_file.read_text()) == actual_dependencies, 'Read-only dependencies changed since configure')
    else:
        save(dependency_file, actual_dependencies)
    if not (build / 'meson-private/coredata.dat').exists():
        run('configure', [MESON, 'setup', build, source, '--prefix=' + str(prefix), '--libdir=lib',
            '--buildtype=release', '--wrap-mode=nodownload', '-Doptimization=' + args.optimization, *options])
    settings = {item['name']: item['value'] for item in json.loads(capture([MESON, 'introspect', '--buildoptions', build]))}
    require(settings['prefix'] == str(prefix) and settings['optimization'] == args.optimization and
            settings['wrap_mode'] == 'nodownload', 'Configured output/optimization/download policy changed')
    if args.component == 'backend':
        require(settings['native_llvm_path'] == str(COMMON / 'llvm15') and
                all(settings[name] is False for name in ('enable_d3d12', 'enable_nvapi', 'enable_nvngx')),
                'Native backend feature/dependency selection changed')
    else:
        require(settings['neptune'] is True and settings['venus'] is False and settings['vtest'] is False and
                settings['render-server-mode'] == settings['render-server-worker'] == 'process',
                'Renderer feature/process isolation selection changed')
    run('compile', [MESON, 'compile', '-C', build, '-j', '2'])
    commands = build / 'compile_commands.json'
    require(str(COMMON / 'src' / pin['repo']) not in commands.read_text(),
            'Different-ABI common source/include leaked into this whole-pin build')
    installed = json.loads(capture([MESON, 'introspect', '--installed', build]))
    require(all(Path(p).resolve().is_relative_to(prefix.resolve()) for p in installed.values()),
            'Install destination escaped private prefix')
    run('install-private', [MESON, 'install', '-C', build, '--no-rebuild'])
    for binary in binaries:
        run('signature', ['/usr/bin/codesign', '--verify', '--strict', binary])
        require(capture(['/usr/bin/lipo', '-archs', binary]) == 'arm64', 'Unexpected binary architecture')
    require(actual_dependencies == {str(p): sha(p) for p in dependencies}, 'Dependency changed while compiling')
    require(inventory['repository'] == source_inventory(source, env), 'Source changed while compiling')
    verify_protected()
    save(base / 'build.json', {'plan': plan, 'source_inventory_sha256': sha(base / 'source-files.json'),
        'dependencies_sha256': sha(dependency_file), 'protected_application_unchanged': True,
        'build_options': settings, 'compile_commands_sha256': sha(commands),
        'binaries': {str(p): {'sha256': sha(p), 'dependencies': capture(['/usr/bin/otool', '-L', p])} for p in binaries},
        'compiler': capture(['/usr/bin/xcrun', 'clang++', '--version']),
        'sdk': capture(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path']),
        'recipe_sha256': sha(Path(__file__)), 'Windows_tested': False})
    print('Private whole-source build verified; installed application unchanged; no VM launched.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('Rebuild stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)
