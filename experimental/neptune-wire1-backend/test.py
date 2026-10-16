#!/usr/bin/env python3
"""Native compatible backend smoke: exact renderer POD, real GPU pixels, no VM."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
PUBLIC = Path(__file__).resolve().parent
BASE = ROOT / '.tools/graphics-wire1-backend'
spec = importlib.util.spec_from_file_location('backend_recipe', PUBLIC / 'build.py')
build = importlib.util.module_from_spec(spec); spec.loader.exec_module(build)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--profile', type=Path, default=BASE)
    selection.add_argument('--rebuild-backend', type=Path, help='Fresh current-host backend profile with build.json')
    parser.add_argument('--rebuild-renderer', type=Path, help='Matching clean current-host renderer source profile')
    args = parser.parse_args()
    rebuilding = args.rebuild_backend is not None
    assert rebuilding == (args.rebuild_renderer is not None), 'Both rebuild profiles are required together'
    base = (args.rebuild_backend if rebuilding else args.profile).absolute()
    if rebuilding:
        renderer_base = args.rebuild_renderer.absolute()
        for path in (base, renderer_base):
            assert path.parent.resolve() == (ROOT / '.tools').resolve() and not path.is_symlink()
            assert re.fullmatch(r'graphics-rebuild-[a-z0-9-]{1,64}', path.name)
        base = base.parent.resolve() / base.name
        renderer_base = renderer_base.parent.resolve() / renderer_base.name
        manifest = json.loads((base / 'build.json').read_text())
        renderer_plan = json.loads((renderer_base / 'plan.json').read_text())
        assert manifest['plan']['output'] == str(base) and renderer_plan['output'] == str(renderer_base)
        assert manifest['plan']['component'] == 'backend' and manifest['plan']['source']['pin'] == build.PIN
        assert renderer_plan['component'] == 'renderer' and renderer_plan['source']['pin'] == build.renderer.PIN
        assert build.sha(base / 'source-files.json') == manifest['source_inventory_sha256']
        assert build.sha(base / 'dependencies.json') == manifest['dependencies_sha256']
        protected = json.loads((base / 'protected.json').read_text())
        assert protected
        def verify_originals():
            for name, expected in protected.items():
                assert build.sha(Path(name)) == expected, 'Protected installed application changed: ' + name
            for name, expected in json.loads((base / 'dependencies.json').read_text()).items():
                assert build.sha(Path(name)) == expected, 'Backend dependency changed: ' + name
        renderer_inventory = json.loads((renderer_base / 'source-files.json').read_text())['repository']
    else:
        assert base.parent == ROOT / '.tools' and re.fullmatch(r'graphics-wire1-backend(?:-[a-z0-9-]{1,48})?', base.name)
        renderer_base = ROOT / '.tools/graphics-wire1'
        renderer_inventory = json.loads((renderer_base / 'provenance/source-files.json').read_text())
        verify_originals = build.frozen
    verify_originals()
    output = base / 'native-check'; output.mkdir(mode=0o700, exist_ok=False)
    source = base / 'src/dxmt'; prefix = base / 'prefix'
    renderer = renderer_base / 'src/virglrenderer'
    env = build.renderer.environment()
    build.validate_source(source, env)
    assert build.capture(['git', '-C', renderer, 'rev-parse', 'HEAD'], env) == build.renderer.PIN
    assert build.capture(['git', '-C', renderer, 'status', '--porcelain'], env) == ''
    shared_path = renderer / 'src/neptune/npt_shared.c'
    assert build.sha(shared_path) == renderer_inventory['src/neptune/npt_shared.c']
    shared = shared_path.read_text()
    definitions = []
    for macro in ('NPT_DARWIN_SHARED_TEXTURE_MAGIC', 'NPT_DARWIN_SHARED_HANDLE_VERSION'):
        match = re.search(r'^#define\s+' + macro + r'\s+(0x[0-9A-Fa-f]+u|[0-9]+u)\b', shared, re.M)
        assert match, macro
        definitions.append('#define ' + macro + ' ' + match[1])
    match = re.search(r'struct npt_darwin_shared_texture\s*\{.*?\n\};', shared, re.S)
    assert match
    (output / 'renderer-shared-layout.h').write_text('#include <stdint.h>\n' + '\n'.join(definitions) + '\n' + match[0] + '\n')
    binary = prefix / 'lib/libdxmt-native.dylib'; before = build.sha(binary)
    if rebuilding:
        assert before == manifest['binaries'][str(binary)]['sha256'], 'Rebuilt backend identity changed'
    executable = output / 'native-check'
    command = ['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++17', '-O0', '-Wall', '-Wextra', '-Werror',
        '-I' + str(prefix / 'include'), '-I' + str(output), '-isystem', str(source / 'include/native/windows'),
        '-isystem', str(source / 'include/native/directx'), str(PUBLIC / 'native-check.cpp'),
        '-L' + str(prefix / 'lib'), '-ldxmt-native', '-Wl,-rpath,' + str(prefix / 'lib'), '-o', str(executable)]
    with (output / 'compile.log').open('w') as log:
        result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    assert result.returncode == 0, 'See native-check/compile.log'
    env['DYLD_LIBRARY_PATH'] = str(prefix / 'lib')
    env['DYLD_PRINT_LIBRARIES'] = '1'
    env['DXMT_LOG_PATH'] = str(output)
    with (output / 'stderr.log').open('w') as log:
        result = subprocess.run([executable], env=env, stdout=subprocess.PIPE, stderr=log, text=True, timeout=30)
    (output / 'stdout.json').write_text(result.stdout)
    assert result.returncode == 0, 'See native-check/stderr.log'
    receipt = json.loads(result.stdout)
    assert receipt['result'] == 'pass' and receipt['pixels_verified'] == 2048 and receipt['wrong_version_rejected']
    loaded = [line for line in (output / 'stderr.log').read_text(errors='replace').splitlines()
        if 'dyld[' in line and 'libdxmt-native' in line]
    assert any(str(binary) in line for line in loaded)
    assert not any(str(build.OLD / 'prefix/lib/libdxmt-native.dylib') in line for line in loaded)
    assert build.sha(binary) == before
    verify_originals()
    receipt.update({'build_command': command, 'binary_sha256': before,
        'renderer_shared_source_sha256': build.sha(shared_path), 'backend_header_sha256': build.sha(source / build.HEADER),
        'generated_layout_sha256': build.sha(output / 'renderer-shared-layout.h'), 'loaded_backend_lines': loaded,
        'guest_CPU_executed': False, 'guest_disks': False, 'Neptune_COM_commands_sent': False, 'exit_code': result.returncode})
    if rebuilding:
        receipt['current_host_rebuild'] = {'backend_manifest_sha256': build.sha(base / 'build.json'),
            'renderer_plan_sha256': build.sha(renderer_base / 'plan.json')}
    (output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
