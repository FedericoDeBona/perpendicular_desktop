#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Link an isolated QEMU scanout/broker overlay; no install, driver or VM changes."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / '.tools/build-venv/bin'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


shared = load('matched_recipe', ROOT / 'scripts/graphics-wire1-rebuild.py')
require, sha, save = shared.require, shared.sha, shared.save


def replace(text, before, after):
    require(text.count(before) == 1, 'Unique QEMU anchor changed: ' + before[:80])
    return text.replace(before, after, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu', type=Path, required=True)
    parser.add_argument('--sync-renderer', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    paths = [p.absolute() for p in (args.output, args.qemu, args.sync_renderer)]
    for p in paths:
        require(p.parent.resolve() == (ROOT / '.tools').resolve() and not p.is_symlink() and
                re.fullmatch(r'graphics-rebuild-[a-z0-9-]{1,64}', p.name), 'Expected private rebuild profile')
    base, qemu, sync = [p.parent.resolve() / p.name for p in paths]
    require(not os.path.lexists(base), 'Fresh output required')
    qreceipt = json.loads((qemu / 'build.json').read_text())
    sreceipt = json.loads((sync / 'build.json').read_text())
    plan = json.loads((sync / 'plan.json').read_text())
    require(qreceipt['plan']['qemu_pin'] == '88e5ee7ec6703662fec7b638cca74c4769e683d6' and
            qreceipt['plan']['renderer'] == plan['renderer'] and qreceipt['plan']['backend'] == plan['backend'] and
            plan['host_transport_version'] == 2 and plan['guest_wire_version'] == 1, 'Matched host/guest profiles required')
    require(sha(sync / 'plan.json') == sreceipt['plan_sha256'] and
            sha(sync / 'source-files.json') == sreceipt['source_inventory_sha256'], 'Sync build identity changed')
    library = sync / 'prefix/lib/libvirglrenderer.1.dylib'
    protected = {**json.loads((sync / 'protected.json').read_text()),
        **json.loads((qemu / 'protected.json').read_text()), **qreceipt['plan']['dependencies'],
        **sreceipt['binaries'], qreceipt['candidate']: qreceipt['candidate_sha256']}
    sink = ROOT / 'experimental/neptune-live/qemu-native-sync.m'
    qheader = ROOT / 'experimental/neptune-live/qemu-live.h'
    pheader = ROOT / 'experimental/cocoa-native-display/publisher.h'
    for p in (Path(__file__), qemu / 'build.json', sync / 'build.json', sink, qheader, pheader,
              qemu / 'build/build.ninja', qemu / 'build/compile_commands.json'):
        protected[str(p)] = sha(p)
    def verify():
        for name, expected in protected.items():
            require(sha(Path(name)) == expected, 'Protected build/app input changed: ' + name)
    verify()
    base.mkdir(mode=0o700); copied = base / 'source'; copied.mkdir(); (base / 'logs').mkdir()
    save(base / 'protected.json', protected)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('DYLD_', 'QEMU_', 'NPT_', 'PERP_', 'ANGLE_', 'VIRGL_'))}
    env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', PATH=str(TOOLS)+':/opt/homebrew/bin:/usr/bin:/bin')
    def run(label, command, cwd=None):
        log = base / 'logs' / (label + '-' + str(time.time_ns()) + '.log')
        print(label + ': ' + str(log.relative_to(ROOT)), flush=True)
        with log.open('w') as output:
            output.write(json.dumps({'argv': list(map(str, command)), 'cwd': str(cwd or ROOT)}) + '\n'); output.flush()
            result = subprocess.run(list(map(str, command)), cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
        require(result.returncode == 0, label + ' failed: ' + str(log))
    source = qemu / 'src/qemu'
    for name in ('virtio-gpu-virgl.c', 'virtio-gpu-gl.c'):
        original = source / 'hw/display' / name; protected[str(original)] = sha(original)
    text = (source / 'hw/display/virtio-gpu-virgl.c').read_text()
    text = replace(text, '#include "qemu/osdep.h"', '#include "qemu/osdep.h"\n#include "qemu-live.h"')
    text = replace(text, '    type = virgl_renderer_create_handle_for_scanout(ss->resource_id,',
        '    if (perp_live_qemu_select(g,scanout->con,ss->scanout_id,ss->resource_id,ss->width,ss->height,\n'
        '                              ss->r.x,ss->r.y,ss->r.width,ss->r.height)) {\n'
        '        scanout->resource_id=ss->resource_id;return true;\n    }\n\n'
        '    type = virgl_renderer_create_handle_for_scanout(ss->resource_id,')
    text = replace(text, '        virtio_gpu_rect_update(g, i, rf.r.x, rf.r.y, rf.r.width, rf.r.height);',
        '        if (!perp_live_qemu_flush(g,i,rf.resource_id))\n'
        '            virtio_gpu_rect_update(g, i, rf.r.x, rf.r.y, rf.r.width, rf.r.height);')
    text = replace(text, '    if (ss.resource_id == 0) {\n        virtio_gpu_disable_scanout(g, ss.scanout_id);',
        '    if (ss.resource_id == 0) {\n        if (!ss.scanout_id) perp_live_qemu_reset(g);\n        virtio_gpu_disable_scanout(g, ss.scanout_id);')
    for name in ('virtio_gpu_virgl_reset_scanout', 'virtio_gpu_virgl_reset'):
        anchor = 'void ' + name + '(VirtIOGPU *g)\n{'
        text = replace(text, anchor, anchor + '\n    perp_live_qemu_reset(g);')
    (copied / 'virtio-gpu-virgl.c').write_text(text)
    text = (source / 'hw/display/virtio-gpu-gl.c').read_text()
    text = replace(text, '#include "qemu/osdep.h"', '#include "qemu/osdep.h"\n#include "qemu-live.h"')
    anchor = 'static void virtio_gpu_gl_class_init(ObjectClass *klass, void *data)\n{'
    text = replace(text, anchor, 'static char *perp_sync_stats(Object *obj, Error **errp) {return perp_live_qemu_stats();}\n' +
        anchor + '\n    object_class_property_add_str(klass,"perp-live-stats",perp_sync_stats,NULL);')
    (copied / 'virtio-gpu-gl.c').write_text(text)
    shutil.copyfile(sink, copied / sink.name)
    shutil.copyfile(qheader, copied / qheader.name)
    shutil.copyfile(pheader, copied / pheader.name)
    private = sync / 'src/virglrenderer/src/perp-sync'
    for name in ('live.h', 'wire1-layout.h', 'broker.h'):
        protected[str(private / name)] = sha(private / name)
        shutil.copyfile(private / name, copied / name)
    save(base / 'protected.json', protected)
    build = qemu / 'build'
    def recipe(target):
        commands = subprocess.check_output([str(TOOLS / 'ninja'), '-t', 'commands', target], cwd=build, env=env, text=True)
        return shlex.split(commands.splitlines()[-1])
    objects = []
    for name, target in [('virtio-gpu-virgl.c', 'libcommon.a.p/hw_display_virtio-gpu-virgl.c.o'),
                         ('virtio-gpu-gl.c', 'libcommon.a.p/hw_display_virtio-gpu-gl.c.o'),
                         (sink.name, 'libcommon.a.p/ui_cocoa.m.o')]:
        argv = recipe(target); obj = base / (name + '.o'); objects.append(obj)
        argv[argv.index('-c')+1] = str(copied / name)
        for option in ('-o', '-MQ', '-MF'):
            argv[argv.index(option)+1] = str(obj) + ('.d' if option == '-MF' else '')
        argv.extend(['-I'+str(copied), '-I'+str(source / 'hw/display'), '-I'+str(build / 'hw/display'),
            '-I'+str(Path(plan['backend']) / 'prefix/include'), '-Wno-unused-parameter'])
        run('compile-'+name, argv, build)
    link = recipe('qemu-system-aarch64-unsigned')
    candidate = base / 'qemu-system-aarch64'
    link[link.index('-o')+1] = str(candidate)
    for old, new in zip(('libcommon.a.p/hw_display_virtio-gpu-virgl.c.o', 'libcommon.a.p/hw_display_virtio-gpu-gl.c.o'), objects):
        require(link.count(old) == 1, 'GPU link edge changed'); link[link.index(old)] = str(new)
    matching = [i for i, arg in enumerate(link) if arg.endswith(('/libvirglrenderer.dylib', '/libvirglrenderer.1.dylib'))]
    require(len(matching) == 1, 'Renderer link identity changed'); link[matching[0]] = str(library)
    link.insert(3, str(objects[2])); link.extend(['-Wl,-rpath,'+str(library.parent)])
    # Bind every reused explicit object/archive/library in the actual link
    # recipe, rather than treating a Ninja file hash as their byte identity.
    for arg in link[1:]:
        if arg.startswith('-') or arg == str(candidate): continue
        p = Path(arg) if Path(arg).is_absolute() else build / arg
        if p.is_file() and p.suffix in ('.o', '.a', '.dylib') and not p.resolve().is_relative_to(base):
            protected[str(p.resolve())] = sha(p)
    save(base / 'protected.json', protected)
    run('link', link, build)
    entitlement = source / 'accel/hvf/entitlements.plist'
    require(plistlib.loads(entitlement.read_bytes()) == {'com.apple.security.hypervisor': True}, 'Unexpected entitlement')
    run('sign', ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', '--entitlements', entitlement, candidate])
    run('signature', ['/usr/bin/codesign', '--verify', '--strict', candidate])
    require(subprocess.check_output(['/usr/bin/lipo', '-archs', str(candidate)], text=True).strip() == 'arm64', 'Expected arm64')
    actual = subprocess.check_output(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(candidate)], stderr=subprocess.DEVNULL)
    require(plistlib.loads(actual) == {'com.apple.security.hypervisor': True}, 'Actual entitlement changed')
    verify()
    save(base / 'build.json', {'result': 'built_not_runtime_verified', 'qemu_profile': str(qemu), 'sync_renderer': str(sync),
        'candidate': str(candidate), 'candidate_sha256': sha(candidate), 'recipe_sha256': sha(Path(__file__)),
        'sources': {str(p.relative_to(base)): sha(p) for p in copied.iterdir()}, 'installed_app_unchanged': True,
        'VM_started': False, 'scope': 'Worker GPU snapshot plus native-publisher GPU copy; no PBO/readback, no Windows qualification'})
    print('Private synchronization QEMU linked; runtime qualification remains pending.', flush=True)


if __name__ == '__main__':
    try: main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('Synchronization QEMU build stopped: ' + str(error), file=sys.stderr); sys.exit(1)
