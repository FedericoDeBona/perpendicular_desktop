#!/usr/bin/env python3
"""Build/record an isolated whole-repository Wire1 profile. Never starts a VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OLD = ROOT / '.tools/graphics-experiment'
PIN = 'd3c970599eb0bfbfe417b86d87fc0e0641da9512'
DEFS = 'src/neptune/neptune-protocol/npt_protocol_defs.h'
DEFS_SHA = '30c843d723860bfda07d1c6e72262d56dc5224f9ffb61d0d8f9f7e645a4ec402'
FROZEN = {
    '.tools/graphics-experiment/prefix/lib/libvirglrenderer.1.dylib': 'ef7607dc1c25927e8e5d5c23040109aee77e45190a7cf5dee769bc43e340c98a',
    '.tools/graphics-experiment/prefix/libexec/virgl_render_server': 'd8a3e00d78b7d61e0412bcb035304e142ae7c78f54528d54ee50bd2a34ab9f9f',
    '.tools/graphics-experiment/prefix/lib/libdxmt-native.dylib': 'f01c20fd4fe4cd5d8a0a1ad8d93922f5c8045f325244bfbbe0ad27ebbf443e1c',
    '.tools/graphics-experiment/prefix/bin/qemu-system-aarch64': '8d4d5ec3f94f7f8117568a2fbf426499e71636c2b0af3f5854adf19a33e94981',
    '.tools/cocoa-neptune-app/Perpendicular 3D Trial.app/Contents/MacOS/qemu-system-aarch64': '3707f441f6d593add3dd0a60a7033cc7672b68dab840292cea131172c5fffbc9',
    '.tools/graphics-experiment/build/gpu-command-diagnostics-3/candidate/qemu-system-aarch64': 'ed4116c76d948a6b21e4fc5af00c50dbecabc7ace94a745bce6ac8000d078cef',
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def environment():
    env = {key: value for key, value in os.environ.items() if not key.startswith(('DYLD_', 'NPT_', 'ANGLE_', 'VIRGL_', 'QEMU_'))}
    env.update({'PATH': str(ROOT / '.tools/build-venv/bin') + ':' + env.get('PATH', ''),
        'PYTHONPATH': str(OLD / 'python-deps'), 'PKG_CONFIG_PATH': str(OLD / 'prefix/lib/pkgconfig'),
        'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer',
        'DYLD_FALLBACK_LIBRARY_PATH': str(OLD / 'prefix/lib') + ':' + str(OLD / 'prefix/ANGLE.xcarchive/Products/usr/local/lib'),
        'ANGLE_DEFAULT_PLATFORM': 'metal'})
    return env


def capture(command, env):
    result = subprocess.run(list(map(str, command)), env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def verify_frozen():
    for name, expected in FROZEN.items():
        assert sha(ROOT / name) == expected, 'Original artifact changed: ' + name


def record(base, env, optimization='0'):
    source = base / 'src/virglrenderer'; build = base / 'build/renderer'; prefix = base / 'prefix'
    assert capture(['git', '-C', source, 'rev-parse', 'HEAD'], env) == PIN
    assert capture(['git', '-C', source, 'diff', '--name-only', 'HEAD'], env) == ''
    assert capture(['git', '-C', source, 'status', '--porcelain'], env) == ''
    assert sha(source / DEFS) == DEFS_SHA
    assert re.search(r'#define\s+NPT_PROTOCOL_WIRE_VERSION\s+1u\b', (source / DEFS).read_text())
    names = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z']).decode().split('\0')
    inventory = {}
    for name in filter(None, names):
        path = source / name
        data = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
        inventory[name] = hashlib.sha256(data).hexdigest()
    provenance = base / 'provenance';provenance.mkdir(exist_ok=True)
    (provenance / 'source-files.json').write_text(json.dumps(inventory, indent=2, sort_keys=True) + '\n')
    outputs = [prefix / 'lib/libvirglrenderer.1.dylib', prefix / 'libexec/virgl_render_server']
    binaries = {}
    for path in outputs:
        verified = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], capture_output=True, text=True)
        assert verified.returncode == 0, verified.stderr
        binaries[str(path.relative_to(ROOT))] = {'sha256': sha(path),
            'architectures': capture(['/usr/bin/lipo', '-archs', path], env),
            'dependencies': capture(['/usr/bin/otool', '-L', path], env), 'strict_signature_verified': True}
    dependencies = json.loads(capture([ROOT / '.tools/build-venv/bin/meson', 'introspect', '--dependencies', build], env))
    compile_commands = build / 'compile_commands.json'
    assert str(OLD / 'src/virglrenderer') not in compile_commands.read_text(), 'Wire2 renderer source/include leaked into profile'
    options = json.loads(capture([ROOT / '.tools/build-venv/bin/meson', 'introspect', '--buildoptions', build], env))
    settings = {entry['name']: entry['value'] for entry in options}
    assert settings['optimization'] == optimization, 'Built optimization does not match requested profile'
    assert settings['prefix'] == str(prefix) and settings['neptune'] is True and settings['venus'] is False
    assert settings['render-server-mode'] == settings['render-server-worker'] == 'process'
    tools = {'python': sys.version, 'meson': capture([ROOT / '.tools/build-venv/bin/meson', '--version'], env),
        'ninja': capture([ROOT / '.tools/build-venv/bin/ninja', '--version'], env),
        'clang': capture(['/usr/bin/xcrun', 'clang', '--version'], env),
        'sdk': capture(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env),
        'pyyaml': capture([sys.executable, '-c', 'import yaml; print(yaml.__version__)'], env),
        'epoxy': capture(['pkg-config', '--modversion', 'epoxy'], env)}
    reused_sources = {name: capture(['git', '-C', OLD / 'src' / name, 'rev-parse', 'HEAD'], env)
        for name in ('dxmt', 'WebKit', 'libepoxy')}
    report = {'schema': 1, 'source_url': 'https://github.com/utmapp/virglrenderer.git', 'source_pin': PIN,
        'source_tree': capture(['git', '-C', source, 'rev-parse', 'HEAD^{tree}'], env),
        'source_inventory_sha256': sha(provenance / 'source-files.json'), 'source_files': len(inventory),
        'compile_commands_sha256': sha(compile_commands), 'wire2_renderer_source_referenced': False,
        'source_clean': True, 'protocol_defs_sha256': DEFS_SHA, 'wire_version': 1,
        'neptune_generated_origin': 'All tracked generated protocol headers and complete transport/decoder/dispatch/overrides from this whole pin',
        'protocol_or_source_patches': [], 'license': {'path': 'src/virglrenderer/COPYING', 'sha256': sha(source / 'COPYING')},
        'build_options': settings, 'dependencies': dependencies, 'tools': tools, 'binaries': binaries,
        'reused_source_revisions': reused_sources,
        'reused_readonly_runtime_sha256': FROZEN, 'max_jobs': 2, 'Windows_tested_by_this_recipe': False}
    verify_frozen()
    (provenance / 'build.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, default=ROOT / '.tools/graphics-wire1')
    parser.add_argument('--record-existing', action='store_true', help='Only validate/record already-built private profile; do not rebuild')
    parser.add_argument('--optimization', choices=('0', '2'), default='0', help='Explicit separate profile optimization; original checkpoint defaults to 0')
    args = parser.parse_args(); base = args.profile.absolute()
    assert base.parent == ROOT / '.tools' and re.fullmatch(r'graphics-wire1(?:-[a-z0-9-]{1,48})?', base.name)
    env = environment();verify_frozen()
    if not args.record_existing:
        assert not os.path.lexists(base), 'Fresh profile required; existing frozen outputs are not overwritten'
        (base / 'logs').mkdir(parents=True, mode=0o700)
        source = base / 'src/virglrenderer'; source.parent.mkdir()
        def run(label, command):
            with (base / 'logs' / (label + '.log')).open('w') as log:
                result = subprocess.run(list(map(str, command)), env=env, stdout=log, stderr=subprocess.STDOUT)
            assert result.returncode == 0, 'See ' + str(base / 'logs' / (label + '.log'))
        run('git-init', ['git', 'init', source])
        run('git-remote', ['git', '-C', source, 'remote', 'add', 'origin', 'https://github.com/utmapp/virglrenderer.git'])
        run('git-fetch', ['git', '-C', source, 'fetch', '--depth', '1', 'origin', PIN])
        run('git-checkout', ['git', '-C', source, 'checkout', '--detach', PIN])
        assert sha(source / DEFS) == DEFS_SHA
        build = base / 'build/renderer'; prefix = base / 'prefix'
        meson = ROOT / '.tools/build-venv/bin/meson'
        run('configure', [meson, 'setup', build, source, '--prefix=' + str(prefix), '--libdir=lib',
            '--buildtype=release', '--wrap-mode=nodownload', '-Doptimization=' + args.optimization,
            '-Dc_args=-I' + str(OLD / 'src/WebKit/Source/ThirdParty/ANGLE/include'), '-Dplatforms=egl',
            '-Dneptune=true', '-Dvenus=false', '-Dvtest=false', '-Drender-server-mode=process',
            '-Drender-server-worker=process', '-Dcheck-gl-errors=false', '-Dtracing=none'])
        run('compile', [meson, 'compile', '-C', build, '-j', '2'])
        installed = json.loads(capture([meson, 'introspect', '--installed', build], env))
        assert all(Path(path).is_relative_to(prefix) for path in installed.values())
        run('install-private', [meson, 'install', '-C', build, '--no-rebuild'])
    report = record(base, env, args.optimization)
    print(json.dumps({'source_pin': PIN, 'wire_version': 1, 'binaries': report['binaries'],
        'source_files': report['source_files'], 'originals_unchanged': True, 'started_VM': False}, indent=2))


if __name__ == '__main__':
    main()
