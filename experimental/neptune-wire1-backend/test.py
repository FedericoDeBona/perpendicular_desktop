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
    parser.add_argument('--profile', type=Path, default=BASE)
    args = parser.parse_args()
    base = args.profile.absolute()
    assert base.parent == ROOT / '.tools' and re.fullmatch(r'graphics-wire1-backend(?:-[a-z0-9-]{1,48})?', base.name)
    build.frozen()
    output = base / 'native-check'; output.mkdir(mode=0o700, exist_ok=False)
    source = base / 'src/dxmt'; prefix = base / 'prefix'
    renderer = ROOT / '.tools/graphics-wire1/src/virglrenderer'
    env = build.renderer.environment()
    build.validate_source(source, env)
    assert build.capture(['git', '-C', renderer, 'rev-parse', 'HEAD'], env) == build.renderer.PIN
    shared_path = renderer / 'src/neptune/npt_shared.c'
    renderer_inventory = json.loads((ROOT / '.tools/graphics-wire1/provenance/source-files.json').read_text())
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
    build.frozen()
    receipt.update({'build_command': command, 'binary_sha256': before,
        'renderer_shared_source_sha256': build.sha(shared_path), 'backend_header_sha256': build.sha(source / build.HEADER),
        'generated_layout_sha256': build.sha(output / 'renderer-shared-layout.h'), 'loaded_backend_lines': loaded,
        'guest_CPU_executed': False, 'guest_disks': False, 'Neptune_COM_commands_sent': False, 'exit_code': result.returncode})
    (output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
