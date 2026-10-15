#!/usr/bin/env python3
"""Separate overlay of actual renderer proxy/server and QEMU scanout ingress."""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess

SPEC=importlib.util.spec_from_file_location('graphics_neptune',Path(__file__).with_name('graphics-neptune.py'))
previous=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(previous)
build=previous.build
SOURCE=build.REPO/'experimental/neptune-live'
FROZEN=build.REPO/'experimental/neptune-snapshot'
BROKER=build.REPO/'experimental/neptune-broker'
OUTPUT=build.BUILD/'neptune-live'
replace=previous.replace_once


def compile_source(source,output,env,target,folder='renderer',extra=()):
    cwd=build.BUILD/folder
    text=subprocess.check_output(['ninja','-t','commands',target],env=env,cwd=cwd,text=True)
    args=shlex.split(text.splitlines()[-1]);args[args.index('-c')+1]=str(source)
    for option in ('-o','-MQ','-MF'):
        args[args.index(option)+1]=str(output)+('.d' if option=='-MF' else '')
    args.extend(['-I'+str(OUTPUT/'source'),'-I'+str(SOURCE),'-I'+str(BROKER),'-I'+str(FROZEN),
        '-I'+str(build.PREFIX/'include'),
        '-I'+str(build.SRC/'virglrenderer/src/proxy'),'-I'+str(build.SRC/'virglrenderer/server'),
        '-I'+str(build.SRC/'qemu/hw/display'),'-Werror',*extra])
    build.command(args,env,'live-'+output.stem,cwd)


def patch_renderer():
    copied=OUTPUT/'source';copied.mkdir(parents=True,exist_ok=True)
    old_output=previous.OUTPUT
    try:previous.OUTPUT=OUTPUT;sources=previous.patched_sources()
    finally:previous.OUTPUT=old_output
    context=sources[0];text=context.read_text()
    text=replace(text,'#include "snapshot.h"','#include "snapshot.h"\n#include "live.h"')
    text=replace(text,'   perp_snapshot_context_created(ctx);','   perp_snapshot_context_created(ctx);\n   perp_live_worker_created(ctx);')
    text=replace(text,'   perp_snapshot_context_destroying(ctx);','   perp_snapshot_context_destroying(ctx);\n   perp_live_worker_stopped(ctx);')
    context.write_text(text)
    shared=copied/'npt_shared.c';text=shared.read_text()
    text=replace(text,'#include "snapshot.h"','#include "snapshot.h"\n#include "live.h"')
    text=replace(text,'   if (NPT_SUCCEEDED(hr) && !nt_handle)\n      perp_snapshot_export(ctx, texture_id, blob_id, texture, (const void *)(uintptr_t)handle);',
        '   if (NPT_SUCCEEDED(hr) && !nt_handle) {\n      perp_snapshot_export(ctx, texture_id, blob_id, texture, (const void *)(uintptr_t)handle);\n'
        '      perp_live_worker_export(ctx, texture_id, blob_id);\n   }')
    shared.write_text(text)
    snapshot=(FROZEN/'snapshot.c').read_text()
    snapshot=replace(snapshot,'#define MAX_EXPORTS 8','#define MAX_EXPORTS 4')
    snapshot=replace(snapshot,'#include <unistd.h>','#include <unistd.h>\n#include "worker-prefix.inc"')
    snapshot=replace(snapshot,'perp_snapshot_fixture_admit(','perp_snapshot_worker_admit(')
    snapshot=replace(snapshot,'    release((void **)&entry->fence); release(&entry->snapshot);',
        '    release((void **)&entry->fence);\n    if(entry->snapshot)live_snapshot_bytes-=entry->layout.size;\n    release(&entry->snapshot);')
    snapshot=replace(snapshot,'    entry->layout=*layout; return true;',
        '    if(layout->size>LIVE_MAX_BYTES-live_snapshot_bytes)goto invalid;\n'
        '    entry->layout=*layout; live_snapshot_bytes+=layout->size; return true;')
    snapshot=replace(snapshot,'    lock(); invalid_scope=true; rejected_import++; unlock();',
        '    lock(); invalid_scope=true; rejected_import++; live_fault_locked(); unlock();')
    snapshot=replace(snapshot,'    if(!entry) { rejected_layout++; unlock(); return; }',
        '    if(!entry) { rejected_layout++; live_fault_locked(); unlock(); return; }')
    snapshot=replace(snapshot,'        if(entries[i].ctx==ctx && entries[i].blob_id==blob_id) {',
        '        if(entries[i].ctx==ctx && entries[i].blob_id!=blob_id && identical(entries[i].texture,texture)) {\n'
        '            rejected_owner++;live_fault_locked();unlock();return;\n        }\n'
        '        if(entries[i].ctx==ctx && entries[i].blob_id==blob_id) {')
    begin=snapshot.index('HRESULT perp_snapshot_signal(');end=snapshot.index('\nchar *perp_snapshot_stats',begin)
    snapshot=snapshot[:begin]+(SOURCE/'worker-signal.inc').read_text()+snapshot[end:]+'\n#include "worker-suffix.inc"\n'
    (copied/'snapshot.c').write_text(snapshot)
    (copied/'snapshot.h').write_text((FROZEN/'snapshot.h').read_text().replace('perp_snapshot_fixture_admit','perp_snapshot_worker_admit'))
    sources.append(copied/'snapshot.c')
    root=build.SRC/'virglrenderer'
    text=(root/'src/proxy/proxy_context.c').read_text()
    text=replace(text,'#include "proxy_context.h"','#include "proxy_context.h"\n#include "live.h"')
    text=replace(text,'   return &ctx->base;','   perp_live_context_start(ctx_id, capset_id, &ctx->socket);\n   return &ctx->base;')
    text=replace(text,'   /* ask the server process to terminate the context process */',
        '   perp_live_context_stop(ctx->base.ctx_id);\n\n   /* ask the server process to terminate the context process */')
    text=replace(text,'   /* The current render protocol only supports importing dma-buf, shm or pipe resource',
        '   if (!perp_live_before_import(ctx->base.ctx_id, res_id)) return;\n\n'
        '   /* The current render protocol only supports importing dma-buf, shm or pipe resource')
    (copied/'proxy_context.c').write_text(text);sources.append(copied/'proxy_context.c')
    text=(root/'src/virglrenderer.c').read_text()
    text=replace(text,'#include "virglrenderer.h"','#include "virglrenderer.h"\n#include "live.h"')
    text=replace(text,'   res->map_info = blob.map_info;\n   res->map_size = args->size;\n\n   return 0;',
        '   res->map_info = blob.map_info;\n   res->map_size = args->size;\n'
        '   perp_live_resource_created(args->res_handle,args->ctx_id,args->blob_id,args->size);\n\n   return 0;')
    text=replace(text,'void virgl_renderer_resource_unref(uint32_t res_handle)\n{',
        'void virgl_renderer_resource_unref(uint32_t res_handle)\n{\n   perp_live_resource_destroy(res_handle);')
    text=replace(text,'   if (state.proxy_initialized)\n      proxy_renderer_reset();',
        '   if (state.proxy_initialized) {\n      proxy_renderer_reset();\n      perp_live_renderer_reset();\n   }')
    text=replace(text,'   if (state.proxy_initialized)\n      proxy_renderer_fini();',
        '   if (state.proxy_initialized) {\n      perp_live_renderer_reset();\n      proxy_renderer_fini();\n   }')
    (copied/'virglrenderer.c').write_text(text)
    text=(root/'server/render_context.c').read_text()
    text=replace(text,'#include "render_context.h"','#include "render_context.h"\n#include "live.h"')
    text=replace(text,'   render_state_destroy_context(ctx->ctx_id);','   if (ctx->backend != RENDER_BACKEND_NONE)\n      render_state_destroy_context(ctx->ctx_id);')
    text=replace(text,'   if (req.header.op >= RENDER_CONTEXT_OP_COUNT) {',
        '   if ((uint32_t)req.header.op == PERP_BROKER_MAGIC) {\n'
        '      if (perp_live_worker_command(ctx->ctx_id,&req,req_size,req_fds,req_fd_count)) return true;\n'
        '      goto fail;\n   }\n\n   if (req.header.op >= RENDER_CONTEXT_OP_COUNT) {')
    text=replace(text,'   if (!ok)\n      return render_socket_send_reply(&ctx->socket, &reply, sizeof(reply));',
        '   if (ok)perp_live_worker_claim(ctx->ctx_id,req->res_id,req->blob_id);\n'
        '   if (!ok)\n      return render_socket_send_reply(&ctx->socket, &reply, sizeof(reply));')
    text=replace(text,'   render_state_destroy_resource(ctx->ctx_id, req->destroy_resource.res_id);',
        '   perp_live_worker_resource_destroy(ctx->ctx_id,req->destroy_resource.res_id);\n'
        '   render_state_destroy_resource(ctx->ctx_id, req->destroy_resource.res_id);')
    (copied/'render_context.c').write_text(text)
    text=(root/'server/render_socket.c').read_text();receive,marker,send=text.partition('static bool\nrender_socket_sendmsg(')
    if not marker:raise RuntimeError('Pinned socket split changed')
    receive=replace(receive,'         want = ntohl(hdr.length);',
        '         want = ntohl(hdr.length);\n'
        '         if (!want || (size_t)want > msg->msg_iov[0].iov_len) {\n'
        '            int count; const int *fds = get_received_fds(msg, &count);\n'
        '            for (int i=0; i<count; i++) close(fds[i]);\n'
        '            render_log("live worker rejected frame length"); return false;\n         }')
    (copied/'render_socket.c').write_text(receive+marker+send)
    return sources


def build_renderer(env):
    sources=patch_renderer();objects=[]
    original=build.BUILD/'renderer/src/libvirgl.a';original_hash=build.file_hash(original)
    for source in sources:
        if source.name.startswith('npt_'):name='neptune_'+source.name+'.o';target='src/libvirgl.a.p/neptune_'+source.name+'.o'
        elif source.name=='proxy_context.c':name='proxy_proxy_context.c.o';target='src/libvirgl.a.p/'+name
        else:name='snapshot-live.o';target='src/libvirgl.a.p/neptune_npt_shared.c.o'
        obj=OUTPUT/name;compile_source(source,obj,env,target,extra=['-Wno-unused-parameter']);objects.append(obj)
    proxy=OUTPUT/'proxy-broker.o';compile_source(SOURCE/'proxy-broker.c',proxy,env,'src/libvirgl.a.p/proxy_proxy_context.c.o',extra=['-Wno-unused-parameter']);objects.append(proxy)
    archive=OUTPUT/'libvirgl-live.a';shutil.copyfile(original,archive);build.command(['ar','-r',archive,*objects],env,'live-archive')
    public=OUTPUT/'virglrenderer.o';compile_source(OUTPUT/'source/virglrenderer.c',public,env,'src/libvirglrenderer.1.dylib.p/virglrenderer.c.o',extra=['-Wno-unused-parameter'])
    library=OUTPUT/'lib/libvirglrenderer.1.dylib';library.parent.mkdir(exist_ok=True)
    link=previous.recipe('src/libvirglrenderer.1.dylib',env);link[link.index('-o')+1]=str(library)
    link=[str(public) if arg=='src/libvirglrenderer.1.dylib.p/virglrenderer.c.o' else str(archive) if arg=='src/libvirgl.a' else arg for arg in link]
    build.command(link,env,'live-renderer-link',build.BUILD/'renderer')
    server=OUTPUT/'virgl_render_server';link=previous.recipe('server/virgl_render_server',env);link[link.index('-o')+1]=str(server)
    for name in ('render_context','render_socket'):
        obj=OUTPUT/(name+'.o');compile_source(OUTPUT/'source'/(name+'.c'),obj,env,'server/virgl_render_server.p/'+name+'.c.o')
        link=[str(obj) if arg=='server/virgl_render_server.p/'+name+'.c.o' else arg for arg in link]
    link=[str(library) if arg=='src/libvirglrenderer.1.dylib' else str(archive) if arg=='src/libvirgl.a' else arg for arg in link]
    link.append('-Wl,-rpath,'+str(library.parent));build.command(link,env,'live-server-link',build.BUILD/'renderer')
    if build.file_hash(original)!=original_hash:raise RuntimeError('Base archive changed')
    return library,server


def build_qemu(env,library):
    root=build.SRC/'qemu';copied=OUTPUT/'source'
    text=(root/'hw/display/virtio-gpu-virgl.c').read_text()
    text=replace(text,'#include "qemu/osdep.h"','#include "qemu/osdep.h"\n#include "qemu-live.h"')
    text=replace(text,'    type = virgl_renderer_create_handle_for_scanout(ss->resource_id,',
        '    if (perp_live_qemu_select(g,scanout->con,ss->scanout_id,ss->resource_id,ss->width,ss->height,\n'
        '                              ss->r.x,ss->r.y,ss->r.width,ss->r.height)) {\n'
        '        scanout->resource_id=ss->resource_id;return true;\n    }\n\n'
        '    type = virgl_renderer_create_handle_for_scanout(ss->resource_id,')
    text=replace(text,'        virtio_gpu_rect_update(g, i, rf.r.x, rf.r.y, rf.r.width, rf.r.height);',
        '        if (!perp_live_qemu_flush(g,i,rf.resource_id))\n'
        '            virtio_gpu_rect_update(g, i, rf.r.x, rf.r.y, rf.r.width, rf.r.height);')
    text=replace(text,'    if (ss.resource_id == 0) {\n        virtio_gpu_disable_scanout(g, ss.scanout_id);',
        '    if (ss.resource_id == 0) {\n        if (!ss.scanout_id) perp_live_qemu_reset(g);\n        virtio_gpu_disable_scanout(g, ss.scanout_id);')
    text=replace(text,'void virtio_gpu_virgl_reset_scanout(VirtIOGPU *g)\n{',
        'void virtio_gpu_virgl_reset_scanout(VirtIOGPU *g)\n{\n    perp_live_qemu_reset(g);')
    text=replace(text,'void virtio_gpu_virgl_reset(VirtIOGPU *g)\n{',
        'void virtio_gpu_virgl_reset(VirtIOGPU *g)\n{\n    perp_live_qemu_reset(g);')
    (copied/'virtio-gpu-virgl.c').write_text(text)
    text=(root/'hw/display/virtio-gpu-gl.c').read_text()
    text=replace(text,'#include "qemu/osdep.h"','#include "qemu/osdep.h"\n#include "qemu-live.h"')
    marker='static void virtio_gpu_gl_class_init(ObjectClass *klass, void *data)\n{'
    text=replace(text,marker,'static char *perp_live_property(Object *obj, Error **errp) {return perp_live_qemu_stats();}\n'
        'static bool perp_live_hold(Object *obj, Error **errp) {return perp_live_qemu_hold_read();}\n'
        'static void perp_live_set_hold(Object *obj, bool hold, Error **errp) {perp_live_qemu_set_hold_read(hold);}\n\n'+marker+
        '\n    object_class_property_add_str(klass,"perp-live-stats",perp_live_property,NULL);'
        '\n    object_class_property_add_bool(klass,"perp-live-hold-read",perp_live_hold,perp_live_set_hold);')
    for name,stem in [('delay-done','delay_done'),('hold-adapter','hold_adapter')]:
        text=replace(text,'static char *perp_live_property',
            'static bool perp_live_'+stem+'(Object *obj, Error **errp) {return perp_live_qemu_'+stem+'();}\n'
            'static void perp_live_set_'+stem+'(Object *obj, bool value, Error **errp) {perp_live_qemu_set_'+stem+'(value);}\n'
            'static char *perp_live_property')
        text=replace(text,marker,marker+'\n    object_class_property_add_bool(klass,"perp-live-'+name+'",perp_live_'+stem+',perp_live_set_'+stem+');')
    (copied/'virtio-gpu-gl.c').write_text(text)
    objects=[]
    for name in ('virtio-gpu-virgl','virtio-gpu-gl'):
        obj=OUTPUT/(name+'.o');compile_source(copied/(name+'.c'),obj,env,'libcommon.a.p/hw_display_'+name+'.c.o','qemu');objects.append(obj)
    extra=['-I'+str(build.REPO/'experimental/metal-headless'),'-I'+str(build.PREFIX/'include')]
    for source in (SOURCE/'qemu-scanout.m',build.REPO/'experimental/metal-headless/adapter.m'):
        obj=OUTPUT/(source.stem+'.o');compile_source(source,obj,env,'libcommon.a.p/ui_cocoa.m.o','qemu',extra);objects.append(obj)
    cwd=build.BUILD/'qemu';text=subprocess.check_output(['ninja','-t','commands','qemu-system-aarch64-unsigned'],env=env,cwd=cwd,text=True)
    link=shlex.split(text.splitlines()[-1]);binary=OUTPUT/'qemu-system-aarch64-neptune-live';link[link.index('-o')+1]=str(binary)
    replacements={'libcommon.a.p/hw_display_virtio-gpu-virgl.c.o':str(objects[0]),'libcommon.a.p/hw_display_virtio-gpu-gl.c.o':str(objects[1]),
        str(build.PREFIX/'lib/libvirglrenderer.dylib'):str(library)}
    for key in replacements:
        if link.count(key)!=1:raise RuntimeError('QEMU pinned link input changed: '+key)
    link=[replacements.get(arg,arg) for arg in link];link[3:3]=[str(p) for p in objects[2:]]
    link.extend(['-framework','Metal','-Wl,-rpath,'+str(library.parent)])
    build.command(link,env,'live-qemu-link',cwd)
    build.command(['codesign','--force','--sign','-','--timestamp=none','--identifier','org.perpendicular.graphics-experiment.neptune-live',
        '--entitlements',build.SRC/'qemu/accel/hvf/entitlements.plist',binary],env,'live-qemu-sign')
    build.command(['codesign','--verify','--strict',binary],env,'live-qemu-sign-verify');return binary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test',action='store_true',help='Run stopped, diskless real virtqueue/renderer/VNC checks')
    parser.add_argument('--causality',action='store_true',help='Also require isolated unsafe mutations to fail the real-path tests')
    args=parser.parse_args()
    env=build.prerequisites(optimization='0');env['ZERO_AR_DATE']='1'
    protected=[build.BUILD/'renderer/src/libvirgl.a',build.PREFIX/'bin/qemu-system-aarch64',
        Path(__file__).with_name('graphics-neptune.py'),Path(__file__).with_name('graphics-build.py')]
    for folder in (FROZEN,BROKER,build.REPO/'experimental/metal-headless'):
        protected.extend(p for p in sorted(folder.glob('*')) if p.is_file())
    protected_hashes={str(p):build.file_hash(p) for p in protected}
    build.command([build.sys.executable,build.REPO/'scripts/graphics-fetch.py','--verify'],env,'live-verify-sources')
    OUTPUT.mkdir(parents=True,exist_ok=True)
    library,server=build_renderer(env);binary=build_qemu(env,library)
    receipt={'result':'built_not_guest_verified','compiler_jobs':1,'library_sha256':build.file_hash(library),
        'server_sha256':build.file_hash(server),'qemu_sha256':build.file_hash(binary),
        'inputs':[{'path':str(p.relative_to(build.REPO)),'sha256':build.file_hash(p)} for p in [Path(__file__).resolve(),*sorted(SOURCE.glob('*'))] if p.is_file()]}
    (build.BASE/'provenance/neptune-live-build.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
    if args.test or args.causality:
        for mode in ('baseline','withheld','reused-fence','reset-pending','late-completion'):
            build.command([build.sys.executable,SOURCE/'test-live.py','--mode',mode],env,'live-test-'+mode)
    if args.causality:causality(env)
    if any(build.file_hash(Path(p))!=digest for p,digest in protected_hashes.items()):raise RuntimeError('Protected base input changed during live overlay build/test')
    receipt['protected_inputs_unchanged']=protected_hashes
    receipt['real_path_tests_passed']=['baseline','withheld','reused-fence','reset-pending','late-completion'] if args.test or args.causality else []
    receipt['causal_mutations_passed']=args.causality
    (build.BASE/'provenance/neptune-live-build.json').write_text(json.dumps(receipt,indent=2)+'\n')


def causality(env):
    # These mutations only replace the consumer registry in a copied archive
    # and copied dylib. QEMU/server/worker use the same real entry points.
    mutations=[('ignore-ready','return result==1 && (p.revents&POLLIN) && !(p.revents&(POLLHUP|POLLERR|POLLNVAL));',
        'return result>=0;', 'withheld',('Unready producer token was published',)),
        ('ignore-resource','frames[i].header.resource_id==id && ready(&frames[i])',
        'frames[i].header.resource_id!=0 && ready(&frames[i])','baseline',
        ('Actual guest-resource/VNC pixels differ','Unexpected extra resource snapshot publication'))]
    results=[];original=(SOURCE/'proxy-broker.c').read_text()
    for name,before,after,mode,causes in mutations:
        directory=OUTPUT/name;directory.mkdir(exist_ok=True)
        source=directory/'proxy-broker.c';source.write_text(replace(original,before,after))
        obj=directory/'proxy-broker.o';compile_source(source,obj,env,'src/libvirgl.a.p/proxy_proxy_context.c.o',extra=['-Wno-unused-parameter'])
        archive=directory/'libvirgl-live.a';shutil.copyfile(OUTPUT/'libvirgl-live.a',archive)
        build.command(['ar','-r',archive,obj],env,'live-mutant-'+name+'-archive')
        libdir=directory/'lib';libdir.mkdir(exist_ok=True);library=libdir/'libvirglrenderer.1.dylib'
        link=previous.recipe('src/libvirglrenderer.1.dylib',env);link[link.index('-o')+1]=str(library)
        link=[str(OUTPUT/'virglrenderer.o') if arg=='src/libvirglrenderer.1.dylib.p/virglrenderer.c.o' else str(archive) if arg=='src/libvirgl.a' else arg for arg in link]
        build.command(link,env,'live-mutant-'+name+'-link',build.BUILD/'renderer')
        process=subprocess.run([build.sys.executable,SOURCE/'test-live.py','--mode',mode,'--library-dir',libdir],env=env,cwd=build.REPO,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
        (build.BASE/('logs/live-causality-'+name+'.log')).write_text(process.stdout)
        matched=next((cause for cause in causes if cause in process.stdout),None)
        if process.returncode==0 or not matched:raise RuntimeError('Mutation did not fail at required boundary: '+name+'\n'+process.stdout[-2000:])
        results.append({'mutation':name,'expected_failure':matched,'exit_code':process.returncode,'library_sha256':build.file_hash(library)})
    report={'result':'pass','mutations':results,'base_library_sha256':build.file_hash(OUTPUT/'lib/libvirglrenderer.1.dylib')}
    (build.BASE/'provenance/neptune-live-causality.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))


if __name__=='__main__':main()
