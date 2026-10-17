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
    parser.add_argument('--headless', action='store_true', help='Also link the native Metal pbuffer backend; host v3 only')
    parser.add_argument('--headless-keep-context', action='store_true', help='Unsafe private thread-handoff negative control; requires --headless')
    parser.add_argument('--vm-runtime', action='store_true', help='Carry the pinned HID backpressure patch and default-off reviewed STP PCI-hole handler')
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
    require(not args.headless_keep_context or args.headless,'Handoff negative control requires --headless')
    require(not args.headless or plan['host_transport_version']==3,'Native headless requires immutable host-v3 leases')
    require(not args.vm_runtime or (args.headless and not args.headless_keep_context),'VM runtime requires the normal native headless backend')
    require(qreceipt['plan']['qemu_pin'] == '88e5ee7ec6703662fec7b638cca74c4769e683d6' and
            qreceipt['plan']['renderer'] == plan['renderer'] and qreceipt['plan']['backend'] == plan['backend'] and
            plan['host_transport_version'] in (2,3) and plan['guest_wire_version'] == 1, 'Matched host/guest profiles required')
    require(sha(sync / 'plan.json') == sreceipt['plan_sha256'] and
            sha(sync / 'source-files.json') == sreceipt['source_inventory_sha256'], 'Sync build identity changed')
    library = sync / 'prefix/lib/libvirglrenderer.1.dylib'
    protected = {**json.loads((sync / 'protected.json').read_text()),
        **json.loads((qemu / 'protected.json').read_text()), **qreceipt['plan']['dependencies'],
        **sreceipt['binaries'], qreceipt['candidate']: qreceipt['candidate_sha256']}
    sink = ROOT / 'experimental/neptune-live/qemu-native-sync.m'
    qheader = ROOT / 'experimental/neptune-live/qemu-live.h'
    pheader = ROOT / 'experimental/cocoa-native-display/publisher.h'
    nheader = ROOT / 'experimental/native-display-transport/ndt.h'
    publisher = ROOT / 'experimental/cocoa-native-display/publisher.m'
    for p in (Path(__file__), qemu / 'build.json', sync / 'build.json', sink, qheader, pheader, nheader,
              qemu / 'build/build.ninja', qemu / 'build/compile_commands.json'):
        protected[str(p)] = sha(p)
    if plan['host_transport_version'] == 3: protected[str(publisher)] = sha(publisher)
    headless=ROOT / 'experimental/native-metal-headless'
    if args.headless:
        for name in ('backend.h','backend.m'): protected[str(headless / name)]=sha(headless / name)
    input_patch=ROOT / 'experimental/input-backpressure'
    stp=ROOT / 'experimental/hvf-stp-pci-hole'
    abort_diagnostic=ROOT / 'experimental/hvf-invalid-syndrome/diagnostic.inc.c'
    if args.vm_runtime:
        protected[str(abort_diagnostic)]=sha(abort_diagnostic)
        for p in (input_patch / 'source-hashes.json',input_patch / 'qemu-10.0.12-backpressure.patch',
                  stp / 'prepare.py',stp / 'emulate.h',stp / 'decode.h'):protected[str(p)]=sha(p)
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
    if args.headless:
        text=replace(text,'#include "qemu-live.h"','#include "qemu-live.h"\n#include "backend.h"')
        text=replace(text,anchor,'static char *perp_headless_stats(Object *obj, Error **errp) {return perp_native_headless_stats();}\n'+anchor+
            '\n    object_class_property_add_str(klass,"perp-headless-stats",perp_headless_stats,NULL);')
    (copied / 'virtio-gpu-gl.c').write_text(text)
    shutil.copyfile(sink, copied / sink.name)
    shutil.copyfile(qheader, copied / qheader.name)
    shutil.copyfile(pheader, copied / pheader.name)
    shutil.copyfile(nheader, copied / nheader.name)
    if args.headless:
        for name in ('backend.h','backend.m'): shutil.copyfile(headless / name,copied / name)
        if args.headless_keep_context:
            path=copied / 'backend.m';text=path.read_text()
            path.write_text(replace(text,'    if(!eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT))fatal_egl("release initialization context");',
                '    /* Unsafe private causal control: keep context current on init thread. */'))
    private = sync / 'src/virglrenderer/src/perp-sync'
    for name in ('live.h', 'wire1-layout.h', 'broker.h'):
        protected[str(private / name)] = sha(private / name)
        shutil.copyfile(private / name, copied / name)
    save(base / 'protected.json', protected)
    build = qemu / 'build'
    def recipe(target):
        commands = subprocess.check_output([str(TOOLS / 'ninja'), '-t', 'commands', target], cwd=build, env=env, text=True)
        return shlex.split(commands.splitlines()[-1])
    vm_targets=[]
    if args.vm_runtime:
        vm=copied / 'vm';vm.mkdir()
        pins=json.loads((input_patch / 'source-hashes.json').read_text())
        require(pins['source_revision']==qreceipt['plan']['qemu_pin'],'Input patch source revision mismatch')
        for name,digest in pins['files'].items():
            original=source / name;require(sha(original)==digest,'Input patch base changed: '+name)
            protected[str(original)]=digest
            destination=vm / name;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(original,destination)
        run('patch-input',['/usr/bin/patch','--batch','-p1','-i',input_patch / 'qemu-10.0.12-backpressure.patch'],vm)
        for name,digest in pins['patched_files'].items():require(sha(vm / name)==digest,'Input patch output changed: '+name)
        original=source / 'target/arm/hvf/hvf.c';protected[str(original)]=sha(original)
        hvf=original.read_text();hook=load('stp_carry',stp / 'prepare.py').HOOK
        hvf=replace(hvf,'#include "gdbstub/enums.h"','#include "gdbstub/enums.h"\n#include "perp-stp/emulate.h"')
        # Log the unsupported exit before retaining the original assertion.
        # This is observation only; it does not emulate or skip the access.
        hvf=replace(hvf,'        assert(isv);',hook+abort_diagnostic.read_text()+'\n        assert(isv);')
        destination=vm / 'target/arm/hvf/hvf.c';destination.parent.mkdir(parents=True,exist_ok=True);destination.write_text(hvf)
        (vm / 'perp-stp').mkdir()
        for name in ('decode.h','emulate.h'):shutil.copyfile(stp / name,vm / 'perp-stp' / name)
        original_link=recipe('qemu-system-aarch64-unsigned')
        entries=json.loads((build / 'compile_commands.json').read_text())
        for entry in entries:
            original=(Path(entry['directory']) / entry['file']).resolve()
            if not original.is_relative_to(source):continue
            name=original.relative_to(source).as_posix()
            if name not in ('ui/input.c','hw/input/hid.c','target/arm/hvf/hvf.c') and not (name.startswith('ui/vnc') and name.endswith('.c')):continue
            argv=shlex.split(entry['command']);target=argv[argv.index('-o')+1]
            if target not in original_link:continue
            require(original_link.count(target)==1,'Input/HVF link edge changed: '+name)
            destination=vm / name
            if not destination.exists():shutil.copyfile(original,destination)
            protected[str(original)]=sha(original)
            vm_targets.append(('vm/'+name,target))
        require({'vm/ui/input.c','vm/hw/input/hid.c','vm/target/arm/hvf/hvf.c','vm/ui/vnc.c'} <= {p[0] for p in vm_targets},'Required input/HVF units absent')
        save(base / 'protected.json',protected)
    objects = []
    targets=[('virtio-gpu-virgl.c', 'libcommon.a.p/hw_display_virtio-gpu-virgl.c.o'),
                         ('virtio-gpu-gl.c', 'libcommon.a.p/hw_display_virtio-gpu-gl.c.o'),
                         (sink.name, 'libcommon.a.p/ui_cocoa.m.o')]
    if args.headless:targets.append(('backend.m','libcommon.a.p/ui_cocoa.m.o'))
    targets.extend(vm_targets)
    for name,target in targets:
        argv = recipe(target); obj = base / (name + '.o'); objects.append(obj)
        obj.parent.mkdir(parents=True,exist_ok=True)
        argv[argv.index('-c')+1] = str(copied / name)
        for option in ('-o', '-MQ', '-MF'):
            argv[argv.index(option)+1] = str(obj) + ('.d' if option == '-MF' else '')
        argv.extend(['-I'+str(copied), '-I'+str(source / 'hw/display'), '-I'+str(build / 'hw/display'),
            '-I'+str(Path(plan['backend']) / 'prefix/include'), '-Wno-unused-parameter'])
        if name.startswith('vm/'):
            relative=name.removeprefix('vm/')
            argv[1:1]=['-iquote',str(copied / 'vm/include'),'-iquote',str(copied / 'vm'),
                '-iquote',str((source / relative).parent)]
        run('compile-'+name.replace('/','_'), argv, build)
    link = recipe('qemu-system-aarch64-unsigned')
    candidate = base / 'qemu-system-aarch64'
    link[link.index('-o')+1] = str(candidate)
    for old, new in zip(('libcommon.a.p/hw_display_virtio-gpu-virgl.c.o', 'libcommon.a.p/hw_display_virtio-gpu-gl.c.o'), objects):
        require(link.count(old) == 1, 'GPU link edge changed'); link[link.index(old)] = str(new)
    for (name,target),obj in zip(vm_targets,objects[3+int(args.headless):]):
        require(link.count(target)==1,'Input/HVF link edge changed');link[link.index(target)]=str(obj)
    matching = [i for i, arg in enumerate(link) if arg.endswith(('/libvirglrenderer.dylib', '/libvirglrenderer.1.dylib'))]
    require(len(matching) == 1, 'Renderer link identity changed'); link[matching[0]] = str(library)
    link.insert(3, str(objects[2])); link.extend(['-Wl,-rpath,'+str(library.parent)])
    if args.headless:
        require(not any(arg.endswith('/ui_egl-headless.c.o') for arg in link),'Another egl-headless backend is already linked')
        link.insert(3,str(objects[3]))
    if plan['host_transport_version'] == 3:
        # The base QEMU archive predates external retirement callbacks. Build
        # the current ARC publisher and replace precisely that one link edge.
        shutil.copyfile(publisher,copied / publisher.name)
        pubobj=base / 'publisher.o'; archive=base / 'libperp-native-publisher.a'
        run('compile-publisher',['xcrun','clang','-target','arm64-apple-macosx14.0','-O3','-fobjc-arc',
            '-std=gnu11','-Wall','-Wextra','-Werror','-I'+str(copied),'-c',copied / publisher.name,'-o',pubobj])
        run('archive-publisher',['xcrun','ar','rcs',archive,pubobj])
        edges=[i for i,arg in enumerate(link) if arg.endswith('/libperp-native-publisher.a')]
        require(len(edges)==1,'Native publisher archive identity changed');link[edges[0]]=str(archive)
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
        'sources': {str(p.relative_to(base)): sha(p) for p in copied.rglob('*') if p.is_file()}, 'installed_app_unchanged': True,
        'host_transport_version':plan['host_transport_version'],
        'native_headless_available':args.headless,'unsafe_test_keep_context':args.headless_keep_context,
        'input_backpressure':args.vm_runtime,'hvf_stp_hole_default_off':args.vm_runtime,
        'VM_started': False, 'scope': ('Worker immutable snapshot FD directly to native publisher; cropped scanouts retain GPU-copy fallback'
            if plan['host_transport_version']==3 else 'Worker GPU snapshot plus native-publisher GPU copy') + '; no Windows qualification'})
    print('Private synchronization QEMU linked; runtime qualification remains pending.', flush=True)


if __name__ == '__main__':
    try: main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('Synchronization QEMU build stopped: ' + str(error), file=sys.stderr); sys.exit(1)
