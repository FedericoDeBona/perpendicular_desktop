#!/usr/bin/env python3
"""Build a separate real-worker broker fixture; no stable runtime or guest."""
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
SOURCE=build.REPO/'experimental/neptune-broker'
FROZEN=build.REPO/'experimental/neptune-snapshot'
OUTPUT=build.BUILD/'neptune-broker'


def compile_source(source,output,env,target='src/libvirgl.a.p/neptune_npt_shared.c.o'):
    args=previous.recipe(target,env)
    args[args.index('-c')+1]=str(source)
    for option in ('-o','-MQ','-MF'):
        args[args.index(option)+1]=str(output)+('.d' if option=='-MF' else '')
    args.extend(['-I'+str(SOURCE),'-I'+str(FROZEN),'-I'+str(build.SRC/'virglrenderer/server'),'-Werror','-Wno-unused-parameter'])
    build.command(args,env,'broker-'+output.stem,build.BUILD/'renderer')


def patched_sources():
    copied=OUTPUT/'source';copied.mkdir(parents=True,exist_ok=True)
    root=build.SRC/'virglrenderer'
    # Derive separate copies of the frozen applicator's exact original edits.
    old_output=previous.OUTPUT
    try:
        previous.OUTPUT=OUTPUT
        sources=previous.patched_sources()
    finally:
        previous.OUTPUT=old_output
    changes={
        'npt_context.c':[
            ('#include "snapshot.h"','#include "snapshot.h"\n#include "broker.h"'),
            ('   perp_snapshot_context_created(ctx);','   perp_snapshot_context_created(ctx);\n   perp_worker_created(ctx);'),
            ('   perp_snapshot_context_destroying(ctx);','   perp_snapshot_context_destroying(ctx);\n   perp_worker_destroying(ctx);')],
        'npt_shared.c':[
            ('#include "snapshot.h"','#include "snapshot.h"\n#include "broker.h"'),
            ('   if (NPT_SUCCEEDED(hr) && !nt_handle)\n      perp_snapshot_export(ctx, texture_id, blob_id, texture, (const void *)(uintptr_t)handle);',
             '   if (NPT_SUCCEEDED(hr) && !nt_handle) {\n      perp_snapshot_export(ctx, texture_id, blob_id, texture, (const void *)(uintptr_t)handle);\n'
             '      perp_worker_export(ctx, texture_id, blob_id);\n   }')],
    }
    for source in sources:
        text=source.read_text()
        for before,after in changes.get(source.name,[]):text=previous.replace_once(text,before,after)
        source.write_text(text)
    snapshot=(FROZEN/'snapshot.c').read_text()
    snapshot=previous.replace_once(snapshot,'#include "snapshot.h"','#include "snapshot.h"\n#include "broker.h"')
    snapshot=previous.replace_once(snapshot,'    if(admitted!=ctx || contexts!=1 || invalid_scope || atomic_load(&ctx->multi_ring)) {',
        '    if(!perp_worker_capture_allowed(ctx,entry?entry->blob_id:0,entry?entry->object_id:0) ||\n'
        '       admitted!=ctx || contexts!=1 || invalid_scope || atomic_load(&ctx->multi_ring)) {')
    (copied/'snapshot.c').write_text(snapshot);sources.append(copied/'snapshot.c')
    context=(root/'server/render_context.c').read_text()
    context=previous.replace_once(context,'#include "render_context.h"','#include "render_context.h"\n#include "broker.h"')
    context=previous.replace_once(context,'   render_state_destroy_resource(ctx->ctx_id, req->destroy_resource.res_id);',
        '   perp_worker_resource(ctx->ctx_id, req->destroy_resource.res_id, true);\n'
        '   render_state_destroy_resource(ctx->ctx_id, req->destroy_resource.res_id);')
    context=previous.replace_once(context,'   return render_state_import_resource(ctx->ctx_id, req->res_id, req->fd_type, fds[0],',
        '   perp_worker_resource(ctx->ctx_id, req->res_id, false);\n'
        '   bool ok = render_state_import_resource(ctx->ctx_id, req->res_id, req->fd_type, fds[0],')
    context=previous.replace_once(context,'                                       req->size);\n}',
        '                                       req->size);\n'
        '   perp_worker_import_result(ctx->ctx_id, req->res_id, ok);\n   return ok;\n}')
    context=previous.replace_once(context,'   bool ok = render_state_create_resource(ctx->ctx_id, req->res_id, req->blob_id,',
        '   perp_worker_claim(ctx->ctx_id, req->res_id, req->blob_id, false, true);\n'
        '   bool ok = render_state_create_resource(ctx->ctx_id, req->res_id, req->blob_id,')
    context=previous.replace_once(context,'   if (!ok)\n      return render_socket_send_reply(&ctx->socket, &reply, sizeof(reply));',
        '   perp_worker_claim(ctx->ctx_id, req->res_id, req->blob_id, ok, false);\n'
        '   if (!ok)\n      return render_socket_send_reply(&ctx->socket, &reply, sizeof(reply));')
    context=previous.replace_once(context,'   if (req.header.op >= RENDER_CONTEXT_OP_COUNT) {',
        '   if ((uint32_t)req.header.op == PERP_BROKER_MAGIC) {\n'
        '      if (req_fd_count) goto fail;\n'
        '      return perp_worker_command(ctx->ctx_id, &req, req_size);\n'
        '   }\n   if (req.header.op >= RENDER_CONTEXT_OP_COUNT) {')
    context=previous.replace_once(context,'   render_state_destroy_context(ctx->ctx_id);',
        '   if (ctx->backend != RENDER_BACKEND_NONE)\n      render_state_destroy_context(ctx->ctx_id);')
    (copied/'render_context.c').write_text(context)
    socket=(root/'server/render_socket.c').read_text()
    # The pinned Darwin reader assigns an unchecked frame length to the
    # caller's iovec. This private worker additionally enforces that capacity.
    receive,marker,send=socket.partition('static bool\nrender_socket_sendmsg(')
    if not marker:raise RuntimeError('Pinned socket split changed')
    receive=previous.replace_once(receive,'         want = ntohl(hdr.length);\n         _msg.msg_iov[0].iov_base = msg->msg_iov[0].iov_base;',
        '         want = ntohl(hdr.length);\n'
        '         if (!want || (size_t)want > msg->msg_iov[0].iov_len) {\n'
        '            int count; const int *fds = get_received_fds(&msg[0], &count);\n'
        '            for (int i=0; i<count; i++) close(fds[i]);\n'
        '            render_log("bounded worker rejected frame length"); return false;\n'
        '         }\n         _msg.msg_iov[0].iov_base = msg->msg_iov[0].iov_base;')
    socket=receive+marker+send
    (copied/'render_socket.c').write_text(socket)
    return sources


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--test',action='store_true')
    parser.add_argument('--causality',action='store_true');args=parser.parse_args()
    env=build.prerequisites(optimization='0')
    env['DYLD_FALLBACK_LIBRARY_PATH']=str(build.PREFIX/'lib')+':'+str(build.PREFIX/'ANGLE.xcarchive/Products/usr/local/lib')
    env['NPT_BACKEND']='dxmt';env['DXMT_LOG_PATH']=str(build.LOGS);env['ZERO_AR_DATE']='1'
    build.command([build.sys.executable,build.REPO/'scripts/graphics-fetch.py','--verify'],env,'broker-verify-sources')
    OUTPUT.mkdir(parents=True,exist_ok=True)
    frozen=[Path(__file__).with_name('graphics-neptune.py'),*[p for p in FROZEN.glob('*') if p.is_file()],
        build.BUILD/'neptune-snapshot/qemu-system-aarch64-neptune-snapshot']
    frozen_hashes={str(p):build.file_hash(p) for p in frozen}
    base=build.BUILD/'renderer/src/libvirgl.a';base_hash=build.file_hash(base)
    objects=[]
    for source in patched_sources():
        obj=OUTPUT/(('neptune_'+source.name if source.name.startswith('npt_') else source.stem)+'.o')
        compile_source(source,obj,env);objects.append(obj)
    archive=OUTPUT/'libvirgl-broker.a';shutil.copyfile(base,archive)
    build.command(['ar','-r',archive,*objects],env,'broker-overlay-archive')
    worker=OUTPUT/'worker.o';compile_source(SOURCE/'worker.c',worker,env)
    server_objects=[worker]
    for name in ('render_context','render_socket'):
        obj=OUTPUT/(name+'.o');compile_source(OUTPUT/'source'/(name+'.c'),obj,env,
            'server/virgl_render_server.p/'+name+'.c.o');server_objects.append(obj)
    link=previous.recipe('server/virgl_render_server',env)
    keep=('render_common.c.o','render_state.c.o','meson-generated_.._.._src_gallium_u_format_table.c.o')
    link=[arg for arg in link if not (arg.startswith('server/') and arg.endswith('.o') and not arg.endswith(keep))]
    link[link.index('-o')+1]=str(OUTPUT/'worker');link[3:3]=[str(p) for p in server_objects]
    link=[str(archive) if arg=='src/libvirgl.a' else arg for arg in link]
    build.command(link,env,'broker-worker-link',build.BUILD/'renderer')
    build.command(['clang','-std=c11','-Wall','-Wextra','-Werror','-O0','-dynamiclib',
        SOURCE/'ring-atomic.c','-o',OUTPUT/'ring-atomic.dylib'],env,'broker-ring-atomic')
    if args.test or args.causality:build.command([build.sys.executable,SOURCE/'test-broker.py'],env,'broker-tests')
    if args.causality:
        cases=[('ignore-consumer-generation','generation!=self.consumer_sequences.get(worker.epoch)','False','Old consumer ACK was accepted'),
            ('ignore-producer-token',"if not events:raise BlockingIOError('Actual producer fence is not ready')",
             "if not events:events=[(message.fds[1],select.POLLIN)]",'Withheld producer token was bridged')]
        results=[]
        for name,before,after,expected in cases:
            folder=OUTPUT/'mutants'/name;folder.mkdir(parents=True,exist_ok=True)
            module=previous.replace_once((SOURCE/'broker.py').read_text(),before,after)
            (folder/'broker.py').write_text(module)
            test=previous.replace_once((SOURCE/'test-broker.py').read_text(),'ROOT=Path(__file__).resolve().parents[2]',
                'ROOT=Path('+json.dumps(str(build.REPO))+')')
            (folder/'test-broker.py').write_text(test)
            mutant_env=env.copy();mutant_env['PERP_BROKER_TEST_LABEL']='broker-mutant-'+name
            result=subprocess.run([build.sys.executable,str(folder/'test-broker.py')],env=mutant_env,
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=45)
            (build.LOGS/('broker-mutant-'+name+'.log')).write_text(result.stdout)
            if result.returncode==0 or expected not in result.stdout:
                raise RuntimeError('Broker causal mutant did not fail for expected cause: '+name)
            results.append({'mutation':name,'expected_failure':expected,'result':'pass','module_sha256':build.file_hash(folder/'broker.py')})
        (build.BASE/'provenance/neptune-broker-causality.json').write_text(json.dumps({'result':'pass','cases':results,
            'safety':'Original GPU overwrite is complete and pixel-verified before either mutant can bypass a guard; no unfinished GPU write is read'},indent=2)+'\n')
    if build.file_hash(base)!=base_hash:raise RuntimeError('Base renderer changed')
    if any(build.file_hash(Path(p))!=digest for p,digest in frozen_hashes.items()):raise RuntimeError('Frozen checkpoint changed')
    receipt={'result':'built','base_archive_sha256':base_hash,'archive_sha256':build.file_hash(archive),
        'worker_sha256':build.file_hash(OUTPUT/'worker'),'compiler_jobs':1,'frozen_dependency_sha256':frozen_hashes,
        'inputs':[{'path':str(p.relative_to(build.REPO)),'sha256':build.file_hash(p)}
            for p in [Path(__file__).resolve(),*sorted(SOURCE.glob('*'))] if p.is_file()]}
    (build.BASE/'provenance/neptune-broker-build.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))


if __name__=='__main__':main()
