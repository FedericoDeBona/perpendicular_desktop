#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build a fresh private Cocoa capture QEMU; never install, package or launch it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASE = ROOT / '.tools/graphics-experiment'
SOURCE = BASE / 'src/qemu'
BUILD = BASE / 'build/qemu'
OUTPUT_ROOT = ROOT / '.tools/cocoa-native-display-build'
PIN = '88e5ee7ec6703662fec7b638cca74c4769e683d6'
COCOA_SHA = '1924b6069e19a2e1b58fa2ccf586fe2188b0910f7e0d70abba202f1535841cf9'
NINJA_SHA = '3d7c980892aab9b8f4a26018fc84fd58c0cfd41b7084762e23bc11c810b2bfe4'
TRACE = BASE / 'build/gpu-command-diagnostics-3'
TRACE_OBJ = TRACE / 'virtio-gpu-virgl.c.o'
TRACE_SHA = '2005f72322153732efd111f8d220f0e63787e96e9bf8d9b7f38e62d5ed330dce'
TRACE_APP = ROOT / '.tools/cocoa-neptune-trace3-app/Perpendicular 3D Trial.app/Contents/MacOS/qemu-system-aarch64'
TRACE_APP_SHA = '0bc3e2c35b41af1fd4313729d37e490af357def0141a91eb02807f203c265339'
COCOA_OBJ = 'libcommon.a.p/ui_cocoa.m.o'
GPU_OBJ = 'libcommon.a.p/hw_display_virtio-gpu-virgl.c.o'
TARGET = 'qemu-system-aarch64-unsigned'
NINJA = ROOT / '.tools/build-venv/bin/ninja'
INPUTS = {
    'publisher.h': HERE / 'publisher.h', 'publisher.m': HERE / 'publisher.m',
    'ndt.h': ROOT / 'experimental/native-display-transport/ndt.h',
    'ndt.c': ROOT / 'experimental/native-display-transport/ndt.c',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def environment():
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('DYLD_', 'QEMU_', 'VIRGL_', 'NPT_', 'ANGLE_'))}
    env['PATH'] = str(ROOT / '.tools/build-venv/bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'
    env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    return env


def capture(command, cwd=None):
    result = subprocess.run(list(map(str, command)), cwd=cwd, env=environment(),
                            capture_output=True, text=True, check=False)
    require(result.returncode == 0, 'Read-only command failed: ' + shlex.join(map(str, command)) + '\n' + result.stderr[-2000:])
    return result.stdout.strip()


def block(text, prefix):
    matches = [part for part in text.split('\n\n') if part.startswith(prefix)]
    require(len(matches) == 1, 'Expected exactly one Ninja block: ' + prefix)
    return matches[0]


def variable(recipe, name):
    values = [line.split(' = ', 1)[1] for line in recipe.splitlines()[1:] if line.startswith(' ' + name + ' = ')]
    require(len(values) == 1 and '$' not in values[0], 'Unsupported or ambiguous recipe variable: ' + name)
    return values[0]


def ninja_path(path):
    text = str(path)
    require(not any(c in text for c in '\r\n\0'), 'Invalid path in Ninja graph')
    return text.replace('$', '$$').replace(' ', '$ ').replace(':', '$:')


def ninja_words(text):
    # The pinned link line contains paths and Ninja escapes, never variables.
    result, word, index = [], '', 0
    while index < len(text):
        char = text[index]
        if char == '$':
            index += 1
            require(index < len(text) and text[index] in ' $:', 'Unsupported Ninja variable or continuation')
            word += text[index]
        elif char.isspace():
            if word:
                result.append(word)
                word = ''
        else:
            word += char
        index += 1
    if word:
        result.append(word)
    return result


def patch_cocoa(text):
    include = '#include <Metal/Metal.h>'
    function = '- (void)drawFrame:(CocoaGLRead *)read\n{'
    require(text.count(include) == 1 and text.count(function) == 1, 'Unexpected Cocoa Metal/function anchor count')
    start = text.index(function)
    end = text.index('\n}\n#endif', start) + 2
    body = text[start:end]
    anchor = '        [blit endEncoding];\n\n        [commandBuffer addCompletedHandler:'
    require(body.count(anchor) == 1, 'Expected one blit-end → original-completion-handler anchor inside drawFrame')
    require(body.count('[blit endEncoding];') == body.count('[commandBuffer addCompletedHandler:') == 1, 'Ambiguous blit/completion-handler sequence')
    require('perp_native_display_' not in text and '"publisher.h"' not in text, 'Cocoa source already patched')
    body = body.replace(anchor, '        [blit endEncoding];\n        perp_native_display_capture(commandBuffer, drawable.texture);\n\n        [commandBuffer addCompletedHandler:', 1)
    patched = text[:start] + body + text[end:]
    patched = patched.replace(include, include + '\n#include "publisher.h"', 1)
    reset = 'static void cocoa_gl_scanout_disable(DisplayChangeListener *dcl)\n{\n'
    require(patched.count(reset) == 1, 'Expected exactly one scanout-disable function')
    patched = patched.replace(reset, reset + '#ifdef USE_METAL\n    perp_native_display_reset();\n#endif\n', 1)
    refresh = 'static void cocoa_gl_refresh(DisplayChangeListener *dcl)\n{\n    cocoa_refresh(dcl);\n'
    require(patched.count(refresh) == 1, 'Expected exactly one Cocoa refresh function')
    # Only the QEMU main loop accesses scanout/read-inflight state. The serial
    # publisher queue merely raises a generation-bound atomic demand. Retrying
    # here preserves the existing no-drawable/inflight path and slot bound.
    patched = patched.replace(refresh, refresh +
        '\n#ifdef USE_METAL\n'
        '    if (gl_scanout_src && perp_native_display_needs_refresh()) {\n'
        '        qatomic_set(&gl_dirty, true);\n'
        '    }\n'
        '#endif\n', 1)
    compatibility = '    return dcl->ops == &dcl_gl_ops;'
    require(patched.count(compatibility) == 1, 'Expected one Cocoa listener compatibility gate')
    return patched.replace(compatibility,
        '    return dcl->ops == &dcl_gl_ops\n'
        '#ifdef USE_METAL\n'
        '        || (perp_native_display_enabled() && !dcl->ops->dpy_gl_update)\n'
        '#endif\n'
        '        ;', 1)


def source_check():
    require(capture(['git', '-C', SOURCE, 'rev-parse', 'HEAD']) == PIN, 'QEMU source pin changed')
    require(sha(SOURCE / 'ui/cocoa.m') == COCOA_SHA, 'Pristine Cocoa source SHA-256 changed')
    require(sha(BUILD / 'build.ninja') == NINJA_SHA, 'Pinned Ninja recipes changed')
    require(sha(TRACE_OBJ) == TRACE_SHA, 'Trace3 GPU diagnostic object changed')
    require(sha(TRACE_APP) == TRACE_APP_SHA, 'Existing actual trace3 app changed')
    receipt = json.loads((TRACE / 'build.json').read_text())
    require(receipt['source_pin'] == PIN and receipt['context_init_gate'] is True, 'Trace3 receipt no longer matches profile')
    require(sha(TRACE / 'source/hw/display/virtio-gpu-virgl.c') == receipt['patched_source_sha256'], 'Trace3 diagnostic source changed')
    require(sha(TRACE / 'candidate/qemu-system-aarch64') == receipt['candidate_sha256'], 'Trace3 signed candidate changed')
    original = (SOURCE / 'ui/cocoa.m').read_text()
    patched = patch_cocoa(original)
    require(patched.count('perp_native_display_capture(commandBuffer, drawable.texture);') == 1, 'Capture injection count changed')
    text = (BUILD / 'build.ninja').read_text()
    cocoa = block(text, 'build ' + COCOA_OBJ + ':')
    link = block(text, 'build ' + TARGET + ':')
    require(cocoa.splitlines()[0].startswith('build ' + COCOA_OBJ + ': objc_COMPILER ../../src/qemu/ui/cocoa.m || '), 'Unexpected Cocoa compile edge')
    words = ninja_words(link.splitlines()[0].split(': c_LINKER ', 1)[1])
    require(words.count(COCOA_OBJ) == words.count(GPU_OBJ) == 1, 'Link graph does not contain exactly one Cocoa and GPU object')
    return text, cocoa, link, patched


def file_record(path):
    absolute = Path(os.path.abspath(path))
    require(absolute.is_file(), 'Required protected input is missing: ' + str(absolute))
    return {'sha256': sha(absolute), 'bytes': absolute.stat().st_size,
            'resolved': str(absolute.resolve()),
            'symlink': os.readlink(absolute) if absolute.is_symlink() else None}


def verify_records(records):
    for name, expected in records.items():
        require(file_record(Path(name)) == expected, 'Protected input changed: ' + name)


def input_inventory(cocoa, link):
    paths = {Path(__file__).resolve(), SOURCE / 'ui/cocoa.m', BUILD / 'build.ninja', TRACE_OBJ,
             TRACE / 'build.json', TRACE / 'diagnostics.ninja', TRACE / 'source/hw/display/virtio-gpu-virgl.c',
             TRACE / 'candidate/qemu-system-aarch64', BUILD / TARGET, BUILD / '.ninja_log', BUILD / '.ninja_deps', BASE / 'prefix/bin/qemu-system-aarch64',
             TRACE_APP, NINJA.resolve(),
             ROOT / '.tools/graphics-wire1/prefix/lib/libvirglrenderer.1.dylib',
             ROOT / '.tools/graphics-wire1/prefix/libexec/virgl_render_server',
             ROOT / '.tools/graphics-wire1-backend/prefix/lib/libdxmt-native.dylib'}
    paths.update(INPUTS.values())
    # Reused objects, archives and explicit/implicit link inputs are all frozen.
    for token in ninja_words(link.splitlines()[0].split(': c_LINKER ', 1)[1]):
        if token not in ('|', '||'):
            paths.add(BUILD / token)
    for token in ninja_words(cocoa.splitlines()[0].split(' || ', 1)[1]):
        paths.add(BUILD / token)
    for token in shlex.split(variable(link, 'LINK_ARGS')):
        if token.startswith('@'):
            paths.add(BUILD / token[1:])
        elif token.endswith(('.a', '.dylib')) and not token.startswith('-'):
            paths.add(BUILD / token)
        elif token.startswith('-Wl,-exported_symbols_list,'):
            paths.add(BUILD / token.split(',', 2)[2])
    # Previous compile's actual header closure, including generated/SDK headers.
    deps = capture([NINJA, '-C', BUILD, '-t', 'deps', COCOA_OBJ])
    for line in deps.splitlines():
        if line.startswith('    '):
            paths.add(BUILD / line.strip())
    return {str(Path(os.path.abspath(path))): file_record(path) for path in sorted(paths)}


def write_private(path, content):
    with path.open('xb') as stream:
        stream.write(content.encode() if isinstance(content, str) else content)
    path.chmod(0o600)


def make_graph(output, text, cocoa, link):
    source = output / 'source'
    objects = [output / name for name in ('cocoa.m.o', 'publisher.m.o', 'ndt.c.o')]
    linked = output / TARGET
    rules = [block(text, 'rule ' + name + '\n') for name in ('objc_COMPILER', 'c_COMPILER', 'c_LINKER')]
    args = variable(cocoa, 'ARGS')
    common = ' -I' + shlex.quote(str(source))
    cocoa_args = args + common + ' -iquote ' + shlex.quote(str(SOURCE / 'ui')) + ' -fno-objc-arc'
    publisher_args = args + common + ' -fobjc-arc -fblocks'
    c_args = re.sub(r'-std=gnu11\b', '-std=c17', args) + common
    require('-std=c17' in c_args, 'NDT C17 compile flag replacement failed')
    edges = []
    for obj, input_file, compiler, flags in zip(objects,
            (source / 'ui/cocoa.m', source / 'publisher.m', source / 'ndt.c'),
            ('objc_COMPILER', 'objc_COMPILER', 'c_COMPILER'), (cocoa_args, publisher_args, c_args)):
        edges.append('build ' + ninja_path(obj) + ': ' + compiler + ' ' + ninja_path(input_file) +
            ' | ' + ninja_path(source / 'publisher.h') + ' ' + ninja_path(source / 'ndt.h') + '\n' +
            ' DEPFILE = ' + ninja_path(str(obj) + '.d') + '\n DEPFILE_UNQUOTED = ' + ninja_path(str(obj) + '.d') +
            '\n ARGS = ' + flags.replace('$', '$$'))
    first, *rest = link.splitlines()
    first = first.replace('build ' + TARGET + ':', 'build ' + ninja_path(linked) + ':', 1)
    first = first.replace(COCOA_OBJ, ' '.join(ninja_path(obj) for obj in objects), 1)
    first = first.replace(GPU_OBJ, ninja_path(TRACE_OBJ), 1)
    frameworks = variable(link, 'LINK_ARGS') + ' -framework Metal -framework Foundation'
    rest = [' LINK_ARGS = ' + frameworks if line.startswith(' LINK_ARGS = ') else line for line in rest]
    graph = 'ninja_required_version = 1.8.2\nbuilddir = ' + ninja_path(output / 'ninja-state') + '\n\n'
    graph += '\n\n'.join(rules + edges + ['\n'.join([first, *rest])]) + '\n'
    require('\ninclude ' not in graph and '\nsubninja ' not in graph, 'Original build graph must not be included')
    return graph, linked, objects


def fresh_output(requested):
    parent = OUTPUT_ROOT
    if not parent.exists():
        parent.mkdir(mode=0o700)
    require(not parent.is_symlink() and parent.resolve() == parent and parent.stat().st_uid == os.geteuid(), 'Private output root must be an owned real directory')
    require(stat.S_IMODE(parent.stat().st_mode) & 0o077 == 0, 'Output root must have mode0700')
    output = Path(os.path.abspath(requested)) if requested else parent / uuid.uuid4().hex
    require(output.parent == parent and re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}', output.name), 'Output must be one fresh child of .tools/cocoa-native-display-build')
    require(not os.path.lexists(output), 'Fresh output required; refusing any existing file/directory/symlink')
    output.mkdir(mode=0o700)
    return output


def self_test():
    original = (SOURCE / 'ui/cocoa.m').read_text()
    result = patch_cocoa(original)
    restored = result.replace('#include "publisher.h"\n', '').replace('        perp_native_display_capture(commandBuffer, drawable.texture);\n', '')
    restored = restored.replace('#ifdef USE_METAL\n    perp_native_display_reset();\n#endif\n', '')
    restored = restored.replace('\n#ifdef USE_METAL\n'
        '    if (gl_scanout_src && perp_native_display_needs_refresh()) {\n'
        '        qatomic_set(&gl_dirty, true);\n'
        '    }\n'
        '#endif\n', '')
    restored = restored.replace('    return dcl->ops == &dcl_gl_ops\n'
        '#ifdef USE_METAL\n'
        '        || (perp_native_display_enabled() && !dcl->ops->dpy_gl_update)\n'
        '#endif\n'
        '        ;', '    return dcl->ops == &dcl_gl_ops;')
    require(restored == original, 'Patch changed unrelated source')
    for bad in (result, original.replace('[blit endEncoding];', '[blit endEncoding];\n        [blit endEncoding];'), original.replace('drawFrame:(CocoaGLRead *)read', 'drawFrame:(void *)read'),
                original.replace('static void cocoa_gl_refresh(DisplayChangeListener *dcl)', 'static void cocoa_gl_refresh_changed(DisplayChangeListener *dcl)'),
                original + '\nstatic void cocoa_gl_refresh(DisplayChangeListener *dcl)\n{\n    cocoa_refresh(dcl);\n'):
        try:
            patch_cocoa(bad)
        except ValueError:
            pass
        else:
            raise ValueError('Altered/already-patched/ambiguous source was accepted')
    require(ninja_words('a$ b c$$d e$:f | g') == ['a b', 'c$d', 'e:f', '|', 'g'], 'Ninja path escaping failed')
    with tempfile.TemporaryDirectory(prefix='perp-builder-test-') as temp:
        path = Path(temp) / 'input'; path.write_bytes(b'original')
        records = {str(path): file_record(path)}; verify_records(records)
        path.write_bytes(b'changed')
        try:
            verify_records(records)
        except ValueError:
            pass
        else:
            raise ValueError('Changed protected bytes were accepted')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--check', action='store_true', help='Read-only source/recipe/trace-object gate (default)')
    modes.add_argument('--prepare', action='store_true', help='Fresh copied sources/standalone Ninja/dry plan only; no compilation')
    modes.add_argument('--build', action='store_true', help='Explicit full private build; requires ready publisher/transport sources')
    parser.add_argument('--output', type=Path, help='Fresh child directory under .tools/cocoa-native-display-build')
    parser.add_argument('--self-test', action='store_true', help='Run pure anchor/escaping/input-integrity fixtures; no compiler/VM')
    args = parser.parse_args()
    text, cocoa, link, patched = source_check()
    if args.self_test:
        self_test()
    if not args.build and not args.prepare:
        require(args.output is None, '--output requires --prepare or --build')
        print(json.dumps({'result': 'PASS', 'source_pin': PIN, 'cocoa_sha256': COCOA_SHA,
            'trace3_object_sha256': TRACE_SHA, 'self_test': args.self_test,
            'missing_publisher_transport': [str(path.relative_to(ROOT)) for path in INPUTS.values() if not path.is_file()],
            'compiled': False, 'started_VM': False}, indent=2))
        return
    for path in INPUTS.values():
        require(path.is_file() and not path.is_symlink(), 'Ready original regular publisher/transport source required: ' + str(path))
    protected = input_inventory(cocoa, link)
    output = fresh_output(args.output)
    (output / 'source').mkdir(mode=0o700)
    (output / 'source/ui').mkdir(mode=0o700)
    (output / 'ninja-state').mkdir(mode=0o700)
    write_private(output / 'source/ui/cocoa.m', patched)
    for name, path in INPUTS.items():
        write_private(output / 'source' / name, path.read_bytes())
    write_private(output / 'protected-inputs.json', json.dumps(protected, indent=2, sort_keys=True) + '\n')
    graph, linked, objects = make_graph(output, text, cocoa, link)
    description = output / 'native-display.ninja'; write_private(description, graph)
    command = [NINJA, '-C', BUILD, '-f', description, '-j', '2', linked]
    plan = capture([NINJA, '-n', *command[1:]])
    require(len([line for line in plan.splitlines() if re.match(r'^\[\d+/\d+\] ', line)]) == 4, 'Expected only three private compiles and one private link in plan')
    write_private(output / 'build-plan.txt', plan + '\n')
    receipt = {'schema': 1, 'source_pin': PIN, 'cocoa_original_sha256': COCOA_SHA,
        'cocoa_patched_sha256': sha(output / 'source/ui/cocoa.m'), 'trace3_object': str(TRACE_OBJ),
        'trace3_object_sha256': TRACE_SHA, 'original_ninja_sha256': NINJA_SHA,
        'protected_inputs': len(protected), 'protected_inputs_sha256': sha(output / 'protected-inputs.json'),
        'copied_source_sha256': {str(path.relative_to(output)): sha(path) for path in sorted((output / 'source').rglob('*')) if path.is_file()},
        'ninja_sha256': sha(description), 'command': list(map(str, command)), 'max_jobs': 2,
        'cocoa_arc': False, 'publisher_arc': True, 'transport_standard': 'c17',
        'tools': {'python': sys.version, 'ninja': capture([NINJA, '--version']),
            'clang': capture(['/usr/bin/xcrun', 'clang', '--version']),
            'sdk_path': capture(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path']),
            'sdk_version': capture(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'])},
        'prepared_only': not args.build, 'installed': False, 'packaged': False, 'vm_started': False}
    if args.build:
        with (output / 'build.log').open('xb') as log:
            os.chmod(output / 'build.log', 0o600)
            result = subprocess.run(list(map(str, command)), env=environment(), stdout=log, stderr=subprocess.STDOUT)
        verify_records(protected)
        require(result.returncode == 0, 'Build failed; see ' + str(output / 'build.log'))
        compiled_deps = {}
        for obj in objects:
            closure = capture([NINJA, '-C', BUILD, '-f', description, '-t', 'deps', obj])
            for line in closure.splitlines():
                if line.startswith('    '):
                    path = Path(os.path.abspath(BUILD / line.strip()))
                    compiled_deps[str(path)] = file_record(path)
        write_private(output / 'compiled-dependencies.json', json.dumps(compiled_deps, indent=2, sort_keys=True) + '\n')
        linked.chmod(0o700)
        for obj in objects:
            obj.chmod(0o600)
        candidate = output / 'candidate/qemu-system-aarch64'; candidate.parent.mkdir(mode=0o700)
        with linked.open('rb') as source_binary, candidate.open('xb') as candidate_binary:
            shutil.copyfileobj(source_binary, candidate_binary)
        candidate.chmod(0o700)
        entitlements = output / 'hypervisor.plist'
        write_private(entitlements, plistlib.dumps({'com.apple.security.hypervisor': True}))
        capture(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'org.perpendicular.cocoa-native-display.qemu', '--entitlements', entitlements, candidate])
        capture(['/usr/bin/codesign', '--verify', '--strict', candidate])
        actual = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', '--xml', str(candidate)], capture_output=True, check=True)
        require(plistlib.loads(actual.stdout[actual.stdout.find(b'<?xml'):]) == {'com.apple.security.hypervisor': True}, 'Unexpected signed entitlements')
        receipt.update({'candidate': str(candidate), 'candidate_sha256': sha(candidate), 'unsigned_sha256': sha(linked),
            'object_sha256': {str(path): sha(path) for path in objects}, 'build_log_sha256': sha(output / 'build.log'),
            'compiled_dependencies': len(compiled_deps), 'compiled_dependencies_sha256': sha(output / 'compiled-dependencies.json'),
            'strict_signature_verified': True, 'entitlements': {'com.apple.security.hypervisor': True}})
    verify_records(protected)
    receipt['protected_inputs_unchanged'] = True
    write_private(output / 'build.json', json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'result': 'PASS', 'output': str(output), 'prepared_only': not args.build,
        'candidate': receipt.get('candidate'), 'candidate_sha256': receipt.get('candidate_sha256'),
        'protected_inputs': len(protected), 'protected_inputs_unchanged': True, 'started_VM': False}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        print('Build refused/failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
