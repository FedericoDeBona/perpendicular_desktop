#!/usr/bin/env python3
"""Build the private graphics experiment, with at most two compiler jobs and no VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import time
import tempfile

REPO = Path(__file__).resolve().parent.parent
BASE = REPO / '.tools/graphics-experiment'
SRC = BASE / 'src'
PREFIX = BASE / 'prefix'
BUILD = BASE / 'build'
LOGS = BASE / 'logs'
LOCK = Path(__file__).with_name('graphics-sources.json')


def command(args, env, label, cwd=None):
    LOGS.mkdir(parents=True, exist_ok=True)
    path = LOGS / (label + '.log')
    print(label + ': ' + str(path), flush=True)
    start = time.monotonic()
    with path.open('w') as stream:
        stream.write(json.dumps({'argv': [str(x) for x in args], 'cwd': str(cwd or REPO)}) + '\n')
        stream.flush()
        result = subprocess.run([str(x) for x in args], cwd=cwd or REPO, env=env,
                                stdout=stream, stderr=subprocess.STDOUT)
        stream.write(json.dumps({'exit_code': result.returncode}) + '\n')
    if result.returncode:
        lines = path.read_text(errors='replace').splitlines()
        diagnostics = [line for line in lines if any(word in line for word in ('error:', 'fatal:', 'FAILED:', 'ERROR:'))]
        selected = diagnostics[-12:] + lines[-6:]
        print('\n'.join(line[:900] for line in selected), file=sys.stderr)
        raise RuntimeError(label + ' failed (exit ' + str(result.returncode) + '); see ' + str(path))
    print(label + ': complete ({:.1f}s)'.format(time.monotonic() - start), flush=True)


def capture(args, env):
    result = subprocess.run([str(x) for x in args], env=env, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or 'Prerequisite command failed')
    return result.stdout.strip()


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def prerequisites(developer_dir=None, metal_required=True, optimization='0'):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('This isolated experiment requires an Apple Silicon Mac.')
    env = os.environ.copy()
    env['CMAKE_BUILD_PARALLEL_LEVEL'] = '2'
    env['MAKEFLAGS'] = '-j2'
    env['NINJAFLAGS'] = '-j2'
    env['PYTHONPATH'] = str(BASE / 'python-deps')
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    # Existing project build tools are read-only dependencies; never install/upgrade them here.
    tool_bin = REPO / '.tools/build-venv/bin'
    env['PATH'] = str(tool_bin) + os.pathsep + env.get('PATH', '')
    candidates = [Path(developer_dir)] if developer_dir else [
        Path(env['DEVELOPER_DIR'])] if env.get('DEVELOPER_DIR') else []
    if not candidates:
        candidates = [Path('/Applications/Xcode.app/Contents/Developer'),
                      Path('/Applications/Xcode-beta.app/Contents/Developer'),
                      Path.home() / 'Applications/Xcode.app/Contents/Developer']
    developer = next((p for p in candidates if (p / 'usr/bin/xcodebuild').is_file()), None)
    if developer is None:
        raise RuntimeError('Full Xcode is not installed yet. The App Store download may still be in progress. ' +
                           'No installation, license acceptance, or system selection was attempted.')
    env['DEVELOPER_DIR'] = str(developer)
    # Read-only check. Never call -runFirstLaunch, -license accept, sudo, or component downloads.
    status = subprocess.run(['xcodebuild', '-checkFirstLaunchStatus'], env=env,
                            capture_output=True, text=True)
    if status.returncode:
        raise RuntimeError('Xcode needs its first-launch/license setup. The coordinating task must handle ' +
                           'any Apple consent or privileges. Details: ' + (status.stderr or status.stdout).strip())
    found = {}
    for tool in (('clang++', 'metal', 'metallib') if metal_required else ('clang++',)):
        try:
            found[tool] = capture(['xcrun', '--find', tool], env)
        except RuntimeError as error:
            raise RuntimeError('Xcode Metal prerequisites are incomplete; no component was downloaded: ' + str(error))
    for tool in ('meson', 'ninja', 'pkg-config'):
        if not shutil.which(tool, path=env['PATH']):
            raise RuntimeError('Required existing build tool missing: ' + tool)
        found[tool] = capture([tool, '--version'], env)
    found['clang_version'] = capture(['xcrun', 'clang++', '--version'], env)
    if metal_required:
        metal_result = subprocess.run(['xcrun', 'metal', '--version'], env=env, capture_output=True, text=True)
        found['metal_version'] = (metal_result.stdout + metal_result.stderr).strip()
        if metal_result.returncode or 'cannot execute tool' in found['metal_version'].lower():
            raise RuntimeError('Metal resolves to an uninstalled-toolchain launcher; no component was downloaded.')
    found.update({'developer_dir': str(developer), 'xcode': capture(['xcodebuild', '-version'], env),
                  'sdk': capture(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env),
                  'host': platform.platform(), 'max_compiler_jobs': 2,
                  'optimization': optimization, 'functional_experiment_only': True,
                  'metal_tools_checked': metal_required,
                  'lock_sha256': hashlib.sha256(LOCK.read_bytes()).hexdigest()})
    (BASE / 'provenance').mkdir(parents=True, exist_ok=True)
    (BASE / 'provenance/toolchain.json').write_text(json.dumps(found, indent=2) + '\n')
    return env


def meson_component(name, source, options, env, optimization='0'):
    destination = BUILD / name
    setup = ['meson', 'setup', destination, source, '--prefix=' + str(PREFIX), '--libdir=lib',
             '--buildtype=release', '--wrap-mode=nodownload', '-Doptimization=' + optimization, *options]
    if name in ('dxmt', 'renderer'):
        setup.append('--force-fallback-for=directx-native,directx-native-headers')
    if (destination / 'meson-private/coredata.dat').exists():
        setup.insert(2, '--reconfigure')
    command(setup, env, name + '-configure')
    command(['meson', 'compile', '-C', destination, '-j', '2'], env, name + '-compile')
    command(['meson', 'install', '-C', destination, '--no-rebuild'], env, name + '-install')


def finalize_private_qemu(env):
    """Discard upstream icon metadata only on our private executable, then sign it."""
    unsigned = BUILD / 'qemu/qemu-system-aarch64-unsigned'
    private_qemu = PREFIX / 'bin/qemu-system-aarch64'
    entitlement = SRC / 'qemu/accel/hvf/entitlements.plist'
    if unsigned.is_symlink() or private_qemu.is_symlink() or not unsigned.is_file():
        raise RuntimeError('Expected regular private QEMU build products')
    if plistlib.loads(entitlement.read_bytes()) != {'com.apple.security.hypervisor': True}:
        raise RuntimeError('Pinned QEMU entitlement must contain only public Hypervisor access')
    # Upstream signs, then appends Rez/Finder metadata. Strict codesign rejects
    # that resource fork/FinderInfo. A new data-fork-only file avoids stripping
    # any attributes from existing binaries, directories, apps or system files.
    with tempfile.NamedTemporaryFile(dir=private_qemu.parent, prefix='.qemu-finalize-', delete=False) as temporary:
        clean = Path(temporary.name)
    try:
        shutil.copyfile(unsigned, clean)
        shutil.copymode(unsigned, clean)
        command(['codesign', '--force', '--sign', '-', '--timestamp=none',
                 '--identifier', 'org.perpendicular.graphics-experiment.qemu',
                 '--entitlements', entitlement, clean], env, 'qemu-private-sign')
        command(['codesign', '--verify', '--strict', clean], env, 'qemu-private-sign-verify')
        clean.replace(private_qemu)
    finally:
        clean.unlink(missing_ok=True)
    command(['codesign', '--verify', '--strict', private_qemu], env, 'qemu-signature-verify')
    command(['codesign', '-d', '--entitlements', '-', '--xml', private_qemu], env, 'qemu-entitlements')
    record = {'source': str(unsigned.relative_to(BASE)), 'source_sha256': file_hash(unsigned),
              'output': str(private_qemu.relative_to(BASE)), 'output_sha256': file_hash(private_qemu),
              'entitlements_sha256': file_hash(entitlement),
              'scope': 'New private data-fork copy; public Hypervisor entitlement only; no VM launch'}
    (BASE / 'provenance/qemu-finalization.json').write_text(json.dumps(record, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=['prerequisites', 'llvm', 'angle', 'epoxy', 'dxmt', 'renderer', 'qemu', 'smoke', 'all'], default='prerequisites')
    parser.add_argument('--developer-dir', help='Full Xcode Contents/Developer path; process-local only')
    parser.add_argument('--optimization', choices=['0','1','2','3'], default='0',
                        help='default 0: functional smoke with lower compiler memory/time; no performance claims')
    parser.add_argument('--smoke-surface', choices=['both','pbuffer','surfaceless'], default='both',
                        help='isolate a surface mode when investigating a driver/backend failure')
    args = parser.parse_args()
    if BASE.is_symlink() or PREFIX.is_symlink() or BUILD.is_symlink():
        raise RuntimeError('Refusing a symlinked experiment/build/prefix directory')
    env = prerequisites(args.developer_dir, metal_required=args.stage not in ('llvm', 'epoxy'), optimization=args.optimization)
    print('Prerequisites verified; compiler parallelism is capped at 2.', flush=True)
    if args.stage == 'prerequisites':
        return
    command([sys.executable, Path(__file__).with_name('graphics-fetch.py'), '--verify'], env, 'verify-sources')
    BUILD.mkdir(parents=True, exist_ok=True)
    PREFIX.mkdir(parents=True, exist_ok=True)
    angle_source = SRC / 'WebKit/Source/ThirdParty/ANGLE'
    angle_lib = PREFIX / 'ANGLE.xcarchive/Products/usr/local/lib'
    angle_headers = angle_source / 'include'
    env['PKG_CONFIG_PATH'] = str(PREFIX / 'lib/pkgconfig')
    env['DYLD_FALLBACK_LIBRARY_PATH'] = str(PREFIX / 'lib') + ':' + str(angle_lib)
    env['ANGLE_DEFAULT_PLATFORM'] = 'metal'
    stages = ['llvm', 'angle', 'epoxy', 'smoke', 'dxmt', 'renderer', 'qemu'] if args.stage == 'all' else [args.stage]
    for stage in stages:
        if stage == 'llvm':
            command([sys.executable, Path(__file__).with_name('graphics-fetch.py'), '--verify', '--llvm-bottle'], env, 'verify-llvm')
            llvm = BASE / 'llvm15'
            binary = BUILD / 'graphics-llvm-probe'
            command(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++17', '-O' + args.optimization, '-I' + str(llvm / 'include'),
                Path(__file__).with_name('graphics-llvm-probe.cpp'), '-L' + str(llvm / 'lib'),
                '-lLLVMSupport', '-lLLVMDemangle', '/opt/homebrew/opt/zstd/lib/libzstd.a',
                llvm / 'lib/libunwind.a', '-lz', '-lcurses', '-lxml2', '-o', binary], env, 'llvm-link-probe')
            command([binary], env, 'llvm-run-probe')
            print((LOGS / 'llvm-run-probe.log').read_text(), flush=True)
        elif stage == 'angle':
            command(['xcodebuild', '-scheme', 'ANGLE', '-configuration', 'Release', '-sdk', 'macosx',
                     '-arch', 'arm64', '-jobs', '2', '-derivedDataPath', BUILD / 'angle-derived-data',
                     '-archivePath', PREFIX / 'ANGLE', 'archive',
                     'CODE_SIGNING_ALLOWED=NO', 'WEBCORE_LIBRARY_DIR=/usr/local/lib',
                     'NORMAL_UMBRELLA_FRAMEWORKS_DIR=', 'ADDITIONAL_SDKS=',
                     'MACOSX_DEPLOYMENT_TARGET=14.0',
                     'GCC_OPTIMIZATION_LEVEL=' + args.optimization,
                     'WK_LIBCPP_ASSERTIONS_CFLAGS=-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE',
                     'GCC_TREAT_WARNINGS_AS_ERRORS=NO'],
                    env, 'angle-archive', angle_source)
        elif stage == 'epoxy':
            meson_component('epoxy', SRC / 'libepoxy', ['-Dc_args=-I' + str(angle_headers),
                '-Degl=yes', '-Dglx=no', '-Dx11=false', '-Dtests=false'], env, args.optimization)
        elif stage == 'dxmt':
            command([sys.executable, Path(__file__).with_name('graphics-fetch.py'), '--verify', '--llvm-bottle'], env, 'verify-llvm')
            llvm = BASE / 'llvm15'
            zstd = Path('/opt/homebrew/opt/zstd/lib/libzstd.a')
            unwind = llvm / 'lib/libunwind.a'
            if not zstd.is_file() or not unwind.is_file():
                raise RuntimeError('Existing zstd and bottle libunwind static libraries are required; nothing was installed.')
            # The upstream native Meson adds these only for /opt/homebrew prefixes.
            # Our isolated static-only LLVM extraction intentionally has another prefix.
            link_args = json.dumps([str(zstd), str(unwind)])
            meson_component('dxmt', SRC / 'dxmt', ['-Dnative_llvm_path=' + str(llvm),
                '-Denable_d3d12=false', '-Denable_nvapi=false', '-Denable_nvngx=false',
                '-Dcpp_link_args=' + link_args, '-Dc_link_args=' + link_args], env, args.optimization)
        elif stage == 'renderer':
            command([sys.executable, Path(__file__).with_name('graphics-fetch.py'), '--verify', '--python-tools'], env, 'verify-python-tools')
            meson_component('renderer', SRC / 'virglrenderer', ['-Dc_args=-I' + str(angle_headers),
                '-Dplatforms=egl', '-Dneptune=true', '-Dvenus=false', '-Dvtest=false',
                '-Drender-server-mode=process', '-Drender-server-worker=process',
                '-Dcheck-gl-errors=false', '-Dtracing=none'], env, args.optimization)
        elif stage == 'smoke':
            binary = BUILD / 'graphics-smoke'
            command(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++17', '-fobjc-arc', '-O' + args.optimization,
                '-Wall', '-Wextra', '-Werror', '-I' + str(angle_headers),
                Path(__file__).with_name('graphics-smoke.mm'), '-L' + str(angle_lib),
                '-Wl,-rpath,' + str(angle_lib), '-lEGL', '-framework', 'Foundation',
                '-framework', 'Metal', '-o', binary], env, 'smoke-compile')
            command([binary] + ([] if args.smoke_surface == 'both' else ['--' + args.smoke_surface + '-only']), env, 'smoke-run')
            records = [json.loads(line) for line in (LOGS / 'smoke-run.log').read_text().splitlines()
                       if line.startswith('{')]
            report = {'binary_sha256': file_hash(binary), 'functional_experiment_only': True,
                      'optimization': args.optimization, 'surface': args.smoke_surface,
                      'trials': [record for record in records if 'matched_pixels' in record],
                      'result': next(record for record in records if record.get('result') == 'pass')}
            report['total_matched_pixels'] = sum(trial['matched_pixels'] for trial in report['trials'])
            report_path = BASE / 'provenance/smoke-results.json'
            report_path.write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps({'result': 'pass', 'trials': len(report['trials']),
                              'total_matched_pixels': report['total_matched_pixels'],
                              'report': str(report_path)}), flush=True)
        elif stage == 'qemu':
            command([sys.executable, Path(__file__).with_name('graphics-fetch.py'), '--verify', '--qemu-wraps'], env, 'verify-qemu-wraps')
            # This QEMU wrap names the obsolete libslirp_dep variable, while
            # its pinned slirp exports libslirp_libdep. Build that exact source
            # as a private pkg-config dependency instead of patching either tree.
            meson_component('slirp', SRC / 'qemu/subprojects/slirp',
                            ['-Ddefault_library=shared'], env, args.optimization)
            qbuild = BUILD / 'qemu'
            qbuild.mkdir(exist_ok=True)
            command([SRC / 'qemu/configure', '--prefix=' + str(PREFIX), '--target-list=aarch64-softmmu',
                '--python=' + sys.executable, '--extra-cflags=-I' + str(angle_headers),
                '--extra-ldflags=-L' + str(angle_lib), '--disable-download', '--disable-rust',
                '--enable-hvf', '--disable-hvf-private', '--enable-fdt=internal',
                '--enable-vnc', '--enable-tpm', '--enable-slirp', '--enable-cocoa',
                '--enable-opengl', '--enable-virglrenderer', '--disable-docs', '--disable-gtk',
                '--disable-sdl', '--disable-pvg', '--disable-werror', '-Doptimization=' + args.optimization], env, 'qemu-configure', qbuild)
            command(['ninja', '-j', '2'], env, 'qemu-compile', qbuild)
            command(['ninja', '-j', '2', 'install'], env, 'qemu-install', qbuild)
            finalize_private_qemu(env)
            command([PREFIX / 'bin/qemu-system-aarch64', '--version'], env, 'qemu-version')
            print('Private QEMU built and finalized with only the public ad hoc Hypervisor entitlement. ' +
                  'No stable executable was replaced and no VM was launched.', flush=True)
    outputs = []
    for directory in (PREFIX, BUILD):
        for path in directory.rglob('*'):
            if path.is_file() and not path.is_symlink() and (path.suffix == '.dylib' or path.name in
                    ('qemu-system-aarch64', 'virgl_render_server', 'graphics-smoke', 'graphics-llvm-probe')):
                outputs.append({'path': str(path.relative_to(BASE)),
                    'sha256': file_hash(path),
                    'mach_o_dependencies': capture(['otool', '-L', path], env).splitlines()[1:],
                    'mach_o_build': capture(['vtool', '-show-build', path], env).splitlines()[1:]})
    (BASE / 'provenance/build-outputs.json').write_text(json.dumps(outputs, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit('Graphics build stopped: ' + str(error))
