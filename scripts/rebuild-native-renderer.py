#!/usr/bin/env python3
"""Rebuild the selected graphics lifecycle patch from matching private inputs.

Reads the reference graphics build only. Does not change an app, VM or reference
checkout. The output is a fresh runtime with both sides of its control protocol.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess

REPO = Path(__file__).resolve().parent.parent
ARCHIVE_SHA = 'a77490144ebca838d1d49d73e366eae845a4c88316347a937ee45819fe9e49ae'
LIBRARY_SHA = '7ae9fe98836432435f1a33239cde19b9c8f59b54f7fbdefa96be17a22d141274'
SERVER_SHA = 'e74b5fe2a981da00106b030f37cfbd1f62ace4afec7ce50f56e3045515b65160'
SHARED_HANDLE_SHA = 'b8a9c35e30f84e918148a2efc237e672399a02745527af6f76988acd36a351ca'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, cwd=None):
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True,
                        help='Matching Wire1 host-v3 renderer build profile')
    parser.add_argument('--runtime', type=Path, required=True,
                        help='Unmodified, hash-matched Native3D runtime')
    parser.add_argument('--output', type=Path, required=True,
                        help='New private output directory')
    parser.add_argument('--shared-handle-diagnostics', action='store_true',
                        help='Count seven existing D3D11/DXGI rejections, without argument tracing')
    args = parser.parse_args()
    reference = args.reference.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True)
    output = args.output.resolve()
    if output.exists():
        raise ValueError('Fresh output required; existing runtimes are preserved.')
    original_library = reference / 'prefix/lib/libvirglrenderer.1.dylib'
    original_server = reference / 'prefix/libexec/virgl_render_server'
    archive = reference / 'build/src/libvirgl.a'
    for path, expected in ((original_library, LIBRARY_SHA), (original_server, SERVER_SHA),
                           (archive, ARCHIVE_SHA)):
        if digest(path) != expected:
            raise ValueError(f'Graphics input does not match the pinned build: {path.name}')
    manifest = json.loads((runtime / 'runtime.json').read_text())
    if (manifest.get('guest_wire_version'), manifest.get('host_transport_version'),
            manifest.get('native_descriptor_version')) != (1, 3, 2):
        raise ValueError('Incompatible graphics runtime')
    for name, expected in manifest['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or digest(runtime / relative) != expected:
            raise ValueError('Runtime input mismatch: ' + name)
    provenance = json.loads((runtime / 'Notices/provenance.json').read_text())
    for name, expected in (('lib/libvirglrenderer.1.dylib', LIBRARY_SHA),
                           ('bin/virgl_render_server', SERVER_SHA)):
        if provenance['origins'][name]['sha256'] != expected:
            raise ValueError('Renderer and server must come from the same pinned build')
    source = reference / 'src/virglrenderer'
    records = json.loads((reference / 'build/compile_commands.json').read_text())
    original_root = records[0]['directory'].split('/.tools/')[0]
    reference_root = reference.parent.parent

    def relocate(value):
        return value.replace(original_root + '/.tools/', str(reference_root) + '/.tools/')

    work = output / 'build'
    copied = work / 'source'
    private = copied / 'src/perp-sync'
    private.mkdir(parents=True)
    names = ['src/proxy/proxy_context.c', 'src/proxy/proxy_client.c',
             'server/render_client.c', 'server/render_worker.c', 'server/render_worker.h',
             *['src/perp-sync/' + n for n in ('proxy-broker.c', 'live.h', 'broker.h',
                'wire.h', 'wire1-layout.h', 'snapshot-storage.h', 'channel.h')]]
    diagnostic_source = 'src/neptune/npt_overrides_shared_handle.c'
    if args.shared_handle_diagnostics:
        if digest(source / diagnostic_source) != SHARED_HANDLE_SHA:
            raise ValueError('Shared-HANDLE diagnostic source does not match the pinned build')
        names.append(diagnostic_source)
    inputs = {name: digest(source / name) for name in names}
    for name in names:
        target = copied / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(relocate((source / name).read_text()))
    patch = REPO / 'graphics/renderer/context-retirement.patch'
    run(['patch', '-p1', '--forward', '--batch', '-i', patch], copied)
    admission_patch = REPO / 'graphics/renderer/context-admission-channel.patch'
    run(['patch', '-p1', '--forward', '--batch', '-i', admission_patch], copied)
    changed = ['src/perp-sync/proxy-broker.c', 'src/proxy/proxy_context.c',
               'src/proxy/proxy_client.c', 'server/render_client.c', 'server/render_worker.c']
    diagnostic_patch = REPO / 'graphics/renderer/shared-handle-diagnostics.patch'
    if args.shared_handle_diagnostics:
        run(['patch', '-p1', '--forward', '--batch', '-i', diagnostic_patch], copied)
        changed.append(diagnostic_source)
    objects = {}
    for name in changed:
        record = next(r for r in records if r['file'].endswith('/' + name))
        command = [relocate(a) for a in shlex.split(record['command'])]
        obj = work / Path(record['output']).name
        command[1:1] = ['-I' + str(private), '-I' + str(copied / 'server'),
                         '-I' + str(copied / 'src/proxy')]
        for option, value in (('-c', copied / name), ('-o', obj), ('-MF', str(obj) + '.d'), ('-MQ', obj)):
            command[command.index(option) + 1] = str(value)
        run(command, reference / 'build')
        objects[record['output']] = obj
        if name == 'src/perp-sync/proxy-broker.c':
            admission_command = list(command)
    for flag in ['-c', '-o', '-MF', '-MQ']:
        index = admission_command.index(flag)
        del admission_command[index:index + 2]
    admission_command.remove('-MD')
    check = work / 'check-admission'
    run([*admission_command, '-UNDEBUG', REPO / 'graphics/renderer/check-admission.c',
         '-o', check], reference / 'build')
    run([check])
    patched_archive = work / 'libvirgl.a'
    shutil.copy2(archive, patched_archive)
    run(['ar', '-r', patched_archive, *[v for k, v in objects.items() if k.startswith('src/')]])
    ninja = shutil.which('ninja') or str(reference_root / '.tools/build-venv/bin/ninja')

    def link(target, destination, replacements):
        recipe = subprocess.check_output([ninja, '-C', str(reference / 'build'), '-t', 'commands', target], text=True)
        command = [relocate(a) for a in shlex.split(recipe.splitlines()[-1])]
        command[command.index('-o') + 1] = str(destination)
        command = [str(replacements.get(a, a)) for a in command]
        run(command, reference / 'build')

    library = work / 'libvirglrenderer.1.dylib'
    server = work / 'virgl_render_server'
    link('src/libvirglrenderer.1.dylib', library, {'src/libvirgl.a': patched_archive})
    link('server/virgl_render_server', server,
         {**objects, 'src/libvirgl.a': patched_archive, 'src/libvirglrenderer.1.dylib': library})
    result = output / 'Native3D'
    shutil.copytree(runtime, result, symlinks=True)
    for name, origin in (('lib/libvirglrenderer.1.dylib', library), ('bin/virgl_render_server', server)):
        target = result / name
        shutil.copy2(origin, target)
        imports = subprocess.check_output(['otool', '-L', str(target)], text=True).splitlines()[1:]
        changes = []
        for line in imports:
            dep = line.strip().split(' (', 1)[0]
            if dep.startswith(('/System/', '/usr/lib/', '@')):
                continue
            dependency = result / 'lib' / Path(dep).name
            if not dependency.exists():
                raise ValueError('Missing packaged dependency: ' + dep)
            changes.extend(['-change', dep, ('@loader_path/../lib/' if name.startswith('bin/')
                                           else '@loader_path/') + dependency.name])
        if name.startswith('lib/'):
            changes.extend(['-id', '@rpath/' + target.name])
        if changes:
            run(['install_name_tool', *changes, target])
        run(['codesign', '--force', '--sign', '-', '--timestamp=none', target])
        run(['codesign', '--verify', '--strict', target])
        manifest['files'][name] = digest(target)
    manifest['renderer_control_version'] = 2
    manifest['context_retirement'] = 1
    manifest['context_admission'] = 1
    # Both binaries are rebuilt from the pinned base, not copied from the input.
    # Do not inherit a diagnostic capability that this build did not compile.
    manifest.pop('shared_handle_diagnostics', None)
    receipt = {'base_library_sha256': LIBRARY_SHA, 'base_server_sha256': SERVER_SHA,
               'base_archive_sha256': ARCHIVE_SHA, 'source_inputs': inputs,
               'patch_sha256': digest(patch), 'guest_wire_version': 1,
               'host_transport_version': 3, 'renderer_control_version': 2,
               'runtime_verified': False}
    notices = result / 'Notices/Perpendicular'
    notices.mkdir(exist_ok=True)
    shutil.copy2(patch, notices / patch.name)
    (notices / 'context-retirement.json').write_text(json.dumps(receipt, indent=2) + '\n')
    shutil.copy2(admission_patch, notices / admission_patch.name)
    (notices / 'context-admission.json').write_text(json.dumps({
        'base_library_sha256': LIBRARY_SHA, 'base_server_sha256': SERVER_SHA,
        'patch_sha256': digest(admission_patch), 'context_limit': 32,
        'admission_before_worker_creation': True, 'runtime_verified': False,
    }, indent=2) + '\n')
    if args.shared_handle_diagnostics:
        manifest['shared_handle_diagnostics'] = 1
        shutil.copy2(diagnostic_patch, notices / diagnostic_patch.name)
        diagnostic_receipt = {
            'source_sha256': SHARED_HANDLE_SHA,
            'patch_sha256': digest(diagnostic_patch),
            'base_runtime_manifest_sha256': digest(runtime / 'runtime.json'),
            'apis': 7, 'log_lines_per_api_per_process_max': 8,
            'counter_saturation': 128, 'guest_arguments_logged': False,
            'rejection_behavior_changed': False, 'runtime_verified': False,
        }
        (notices / 'shared-handle-diagnostics.json').write_text(json.dumps(diagnostic_receipt, indent=2) + '\n')
    (result / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if any(digest(source / name) != expected for name, expected in inputs.items()):
        raise ValueError('Reference source changed during the build')
    print('Prepared runtime:', result)
    print('Reference checkout, app and VM were not changed.')


if __name__ == '__main__':
    main()
