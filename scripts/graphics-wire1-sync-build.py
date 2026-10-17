#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build a private copy-before-Signal renderer for the complete matched Wire1 pin."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
COMMON = ROOT / '.tools/graphics-experiment'
TOOLS = ROOT / '.tools/build-venv/bin'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


shared = load('matched_build', ROOT / 'scripts/graphics-wire1-rebuild.py')
live = load('live_source_patches', ROOT / 'scripts/graphics-live.py')
sha, require, save = shared.sha, shared.require, shared.save


def port(text):
    """Our private host transport v2 carries the actual 72-byte old descriptor.

    No guest protocol, native backend layout or upstream wire constant changes.
    The newer development transport remains unchanged in its original files.
    """
    text = text.replace('#include <directx-native/dxn_shared.h>', '#include "wire1-layout.h"')
    text = text.replace('dxn_shared_texture', 'dxmt_shared_texture_handle')
    text = text.replace('dxn_shared_check(layout,DXN_SHARED_TEXTURE_MAGIC,sizeof(*layout))', 'perp_wire1_layout_valid(layout)')
    for field in ('width', 'height', 'dxgi_format', 'mip_levels', 'array_size', 'sample_count'):
        text = text.replace('layout->meta.' + field, 'layout->' + field)
    text = text.replace('layout->meta.cpu_access_flags || layout->meta.usage!=0 || layout->plane_count!=1 ||\n       layout->drm_modifier || layout->planes[0].offset',
                        'layout->cpu_access || layout->offset')
    text = text.replace('0x2u|DXN_MISC_LINEAR_EXPORT', '0x2u')
    text = text.replace('sizeof(PerpSnapshotPacket)==176', 'sizeof(PerpSnapshotPacket)==96')
    # This is a distinct HOST extension, never the signed driver's wire version.
    text = text.replace('#define PERP_BROKER_VERSION 1u', '#define PERP_BROKER_VERSION 2u')
    for before, after in (('h->version!=1', 'h->version!=2'), ('h->version=1', 'h->version=2'),
                          ('.version=1', '.version=2'), ('p->version!=1', 'p->version!=2'),
                          ('packet->version!=1', 'packet->version!=2')):
        text = text.replace(before, after)
    text = text.replace('h->bytes!=248', 'h->bytes!=sizeof(PerpBrokerHeader)+sizeof(PerpSnapshotPacket)')
    require(not any(token in text for token in ('dxn_shared_', 'DXN_', 'layout->meta.', 'layout->planes[')),
            'Unported newer descriptor use')
    return text


LAYOUT = '''/* SPDX-License-Identifier: MIT */
#ifndef PERP_WIRE1_LAYOUT_H
#define PERP_WIRE1_LAYOUT_H
#include <stddef.h>
#include <dxmt-native/dxmt_native.h>
_Static_assert(sizeof(dxmt_shared_texture_handle)==72,"whole-pin DMTX v2 layout");
_Static_assert(offsetof(dxmt_shared_texture_handle,fd)==8,"whole-pin fd offset");
static inline int perp_wire1_layout_valid(const dxmt_shared_texture_handle *p) {
    return p && p->magic==DXMT_SHARED_TEXTURE_MAGIC && p->version==DXMT_SHARED_HANDLE_VERSION;
}
#endif
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--renderer', required=True, type=Path)
    parser.add_argument('--backend', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--generations', action='store_true', help='Private host v3 immutable generation leases; guest Wire1 unchanged')
    args = parser.parse_args()
    paths = [p.absolute() for p in (args.output, args.renderer, args.backend)]
    for path in paths:
        require(path.parent.resolve() == (ROOT / '.tools').resolve() and not path.is_symlink() and
                re.fullmatch(r'graphics-rebuild-[a-z0-9-]{1,64}', path.name), 'Expected direct private rebuild profile')
    base, renderer, backend = [p.parent.resolve() / p.name for p in paths]
    require(not os.path.lexists(base), 'Fresh output required; retain failed attempts separately')
    dependencies = {}
    for name, profile in (('renderer', renderer), ('backend', backend)):
        receipt = json.loads((profile / 'build.json').read_text())
        require(receipt['plan']['component'] == name and receipt['plan']['output'] == str(profile) and
                receipt['plan']['source']['pin'] == shared.PINS[name]['pin'], 'Matched whole-pin build required')
        dependencies[str(profile / 'build.json')] = sha(profile / 'build.json')
        dependencies.update({name: item['sha256'] for name, item in receipt['binaries'].items()})
        require(sha(profile / 'dependencies.json') == receipt['dependencies_sha256'], 'Changed dependency inventory')
        dependencies.update(json.loads((profile / 'dependencies.json').read_text()))
    inputs = [Path(__file__), ROOT / 'scripts/graphics-wire1-generations.py', ROOT / 'scripts/graphics-live.py', ROOT / 'scripts/graphics-neptune.py',
              ROOT / 'scripts/graphics-build.py', ROOT / 'scripts/graphics-wire1-rebuild.py']
    for folder in ('neptune-snapshot', 'neptune-live', 'neptune-broker'):
        inputs.extend(p for p in (ROOT / 'experimental' / folder).iterdir() if p.is_file())
    protected = {str(p): sha(p) for p in inputs}
    protected.update(dependencies)
    protected.update(json.loads((renderer / 'protected.json').read_text()))
    def verify():
        for name, expected in protected.items():
            require(sha(Path(name)) == expected, 'Protected source/dependency/app changed: ' + name)
    verify()
    base.mkdir(mode=0o700); (base / 'logs').mkdir(); (base / 'patches').mkdir()
    save(base / 'protected.json', protected)
    source = base / 'src/virglrenderer'
    pristine = renderer / 'src/virglrenderer'
    require(subprocess.check_output(['/Library/Developer/CommandLineTools/usr/bin/git', '-C', str(pristine),
        'rev-parse', 'HEAD'], text=True).strip() == shared.PINS['renderer']['pin'], 'Renderer source pin changed')
    require(not subprocess.check_output(['/Library/Developer/CommandLineTools/usr/bin/git', '-C', str(pristine),
        'status', '--porcelain']), 'Renderer source must remain clean')
    shutil.copytree(pristine, source, ignore=shutil.ignore_patterns('.git', '__pycache__'))
    original = {str(p.relative_to(source)): sha(p) for p in source.rglob('*') if p.is_file()}
    live.build.SRC = renderer / 'src'
    live.OUTPUT = base / 'patches'
    live.patch_renderer()  # Existing unique/reversible upstream source anchors.
    destinations = {'npt_context.c': 'src/neptune', 'npt_shared.c': 'src/neptune',
        'npt_overrides_d3d11_fence.c': 'src/neptune', 'proxy_context.c': 'src/proxy',
        'virglrenderer.c': 'src', 'render_context.c': 'server', 'render_socket.c': 'server'}
    for name, parent in destinations.items():
        (source / parent / name).write_text((base / 'patches/source' / name).read_text())
    private = source / 'src/perp-sync'; private.mkdir()
    for name, origin in {'snapshot.c': base / 'patches/source/snapshot.c', 'snapshot.h': base / 'patches/source/snapshot.h',
        'wire.h': ROOT / 'experimental/neptune-snapshot/wire.h', 'wire.c': ROOT / 'experimental/neptune-snapshot/wire.c',
        'broker.h': ROOT / 'experimental/neptune-broker/broker.h', **{name: ROOT / 'experimental/neptune-live' / name
            for name in ('live.h', 'worker-prefix.inc', 'worker-signal.inc', 'worker-suffix.inc', 'proxy-broker.c')}}.items():
        (private / name).write_text(port(origin.read_text()))
    (private / 'wire1-layout.h').write_text(LAYOUT)
    # The old descriptor has no Usage field: validate the actual COM texture
    # description instead of inferring its missing field from another ABI.
    path = private / 'snapshot.c'; text = path.read_text()
    anchor = '    VTABLE(PFN_ID3D11DeviceChild_GetDevice,tex,'
    require(text.count(anchor) == 1, 'Texture-owner anchor changed')
    text = text.replace(anchor, '    D3D11_TEXTURE2D_DESC actual={0};\n'
        '    VTABLE(PFN_ID3D11Texture2D_GetDesc,tex,NPT_VTBL_ID3D11Texture2D_GetDesc)(tex,&actual);\n'
        '    if(actual.Usage || actual.CPUAccessFlags || actual.MipLevels!=1 || actual.ArraySize!=1 || actual.SampleDesc.Count!=1)goto invalid;\n' + anchor)
    path.write_text(text)
    if args.generations:
        load('generation_extension', ROOT / 'scripts/graphics-wire1-generations.py').apply(private, ROOT)
    path = source / 'src/meson.build'; text = path.read_text(); anchor = 'neptune_sources = [\n'
    require(text.count(anchor) == 1, 'Neptune Meson anchor changed')
    path.write_text(text.replace(anchor, anchor + "   'perp-sync/snapshot.c',\n   'perp-sync/wire.c',\n   'perp-sync/proxy-broker.c',\n"))
    save(base / 'source-files.json', {str(p.relative_to(source)): sha(p) for p in source.rglob('*') if p.is_file()})
    save(base / 'plan.json', {'renderer': str(renderer), 'backend': str(backend), 'source_pin': shared.PINS['renderer']['pin'],
        'backend_pin': shared.PINS['backend']['pin'], 'host_transport_version': 3 if args.generations else 2, 'guest_wire_version': 1,
        'original_source_files': original, 'max_jobs': 2, 'optimization': 3})
    prefix, build = base / 'prefix', base / 'build'
    angle = COMMON / 'src/WebKit/Source/ThirdParty/ANGLE/include'
    includes = [angle, backend / 'prefix/include', private, source / 'src/neptune', source / 'src/proxy', source / 'server']
    env = {key: value for key, value in os.environ.items() if not key.startswith(('DYLD_', 'QEMU_', 'NPT_', 'ANGLE_', 'PERP_', 'VIRGL_'))}
    env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', PATH=str(TOOLS)+':/opt/homebrew/bin:/usr/bin:/bin',
        PYTHONPATH=str(COMMON / 'python-deps'), PYTHONDONTWRITEBYTECODE='1', PKG_CONFIG_PATH=str(COMMON / 'prefix/lib/pkgconfig'),
        DYLD_FALLBACK_LIBRARY_PATH=str(COMMON / 'prefix/lib')+':'+str(COMMON / 'prefix/ANGLE.xcarchive/Products/usr/local/lib'))
    def run(label, command):
        log = base / 'logs' / (label + '-' + str(time.time_ns()) + '.log')
        print(label + ': ' + str(log.relative_to(ROOT)), flush=True)
        with log.open('w') as output:
            output.write(json.dumps({'argv': list(map(str, command))}) + '\n'); output.flush()
            result = subprocess.run(list(map(str, command)), env=env, stdout=output, stderr=subprocess.STDOUT)
        require(result.returncode == 0, label + ' failed: ' + str(log))
    flags = json.dumps(['-I'+str(p) for p in includes])
    run('configure', [TOOLS / 'meson', 'setup', build, source, '--prefix='+str(prefix), '--libdir=lib',
        '--buildtype=release', '--wrap-mode=nodownload', '-Doptimization=3', '-Dc_args='+flags,
        '-Dplatforms=egl', '-Dneptune=true', '-Dvenus=false', '-Dvtest=false', '-Drender-server-mode=process',
        '-Drender-server-worker=process', '-Dcheck-gl-errors=false', '-Dtracing=none'])
    run('compile', [TOOLS / 'meson', 'compile', '-C', build, '-j', '2'])
    installed = json.loads(subprocess.check_output([str(TOOLS / 'meson'), 'introspect', '--installed', str(build)], env=env, text=True))
    require(all(Path(p).resolve().is_relative_to(prefix.resolve()) for p in installed.values()), 'Install escaped private prefix')
    run('install-private', [TOOLS / 'meson', 'install', '-C', build, '--no-rebuild'])
    outputs = [prefix / 'lib/libvirglrenderer.1.dylib', prefix / 'libexec/virgl_render_server']
    for path in outputs: run('signature', ['/usr/bin/codesign', '--verify', '--strict', path])
    verify()
    save(base / 'build.json', {'result': 'built_not_runtime_verified', 'plan_sha256': sha(base / 'plan.json'),
        'recipe_sha256': sha(Path(__file__)), 'source_inventory_sha256': sha(base / 'source-files.json'),
        'binaries': {str(p): sha(p) for p in outputs}, 'installed_app_unchanged': True, 'VM_started': False,
        'scope': 'Copy-before-Signal bridge; original owner/import/multi-ring guards retained; no Windows qualification'})
    print('Matched Wire1 synchronization renderer built privately; runtime/Windows qualification pending.', flush=True)


if __name__ == '__main__':
    try: main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('Wire1 synchronization build stopped: ' + str(error), file=sys.stderr); sys.exit(1)
