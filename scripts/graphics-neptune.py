#!/usr/bin/env python3
"""Build a separate Neptune snapshot overlay from pristine pinned objects."""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess

SPEC=importlib.util.spec_from_file_location('graphics_build',Path(__file__).with_name('graphics-build.py'))
build=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
SOURCE=build.REPO/'experimental/neptune-snapshot'
OUTPUT=build.BUILD/'neptune-snapshot'


def recipe(target,env):
    text=subprocess.run(['ninja','-t','commands',target],env=env,cwd=build.BUILD/'renderer',
        text=True,capture_output=True,check=True).stdout
    return shlex.split(text.splitlines()[-1])


def replace_once(text,before,after):
    if text.count(before)!=1: raise RuntimeError('Pinned patch context changed: '+before[:80])
    return text.replace(before,after)


def patched_sources():
    copied=OUTPUT/'source'; copied.mkdir(parents=True,exist_ok=True)
    root=build.SRC/'virglrenderer/src/neptune'
    patches={
        'npt_context.c':[
            ('#include "npt_context.h"','#include "npt_context.h"\n#include "snapshot.h"'),
            ('   npt_context_init_dispatch(ctx);','   npt_context_init_dispatch(ctx);\n   perp_snapshot_context_created(ctx);'),
            ('   mtx_destroy(&ctx->sync_queues_mutex);\n\n   /* Retire fences',
             '   mtx_destroy(&ctx->sync_queues_mutex);\n   perp_snapshot_context_destroying(ctx);\n\n   /* Retire fences')],
        'npt_shared.c':[
            ('#include "npt_shared.h"','#include "npt_shared.h"\n#include "snapshot.h"'),
            ('   hr = npt_shared_export_handle(ctx, blob_id, data_res_id, data_off, handle);',
             '   hr = npt_shared_export_handle(ctx, blob_id, data_res_id, data_off, handle);\n'
             '   if (NPT_SUCCEEDED(hr) && !nt_handle)\n'
             '      perp_snapshot_export(ctx, texture_id, blob_id, texture, (const void *)(uintptr_t)handle);'),
            ('npt_shared_open_res(struct npt_context *ctx, uint64_t device_id,\n                    const struct npt_cmd_shared_open_res *cmd)\n{',
             'npt_shared_open_res(struct npt_context *ctx, uint64_t device_id,\n                    const struct npt_cmd_shared_open_res *cmd)\n{\n'
             '   perp_snapshot_import(ctx, cmd->res_id);')],
        'npt_overrides_d3d11_fence.c':[
            ('#include "npt_context.h"','#include "npt_context.h"\n#include "snapshot.h"'),
            ('   args->ret = original(args->_self, args->pFence, args->Value);',
             '   args->ret = perp_snapshot_signal(npt_context_from_dispatch(dctx), args->_self,\n'
             '                                     args->pFence, args->Value, original);')],
    }
    results=[]
    for name,changes in patches.items():
        text=(root/name).read_text()
        for before,after in changes: text=replace_once(text,before,after)
        output=copied/name; output.write_text(text); results.append(output)
    return results


def compile_source(source,output,env):
    args=recipe('src/libvirgl.a.p/neptune_npt_shared.c.o',env)
    args[args.index('-c')+1]=str(source)
    for option in ('-o','-MQ','-MF'):
        args[args.index(option)+1]=str(output)+('.d' if option=='-MF' else '')
    # Generated protocol helpers intentionally have unused scalar parameters.
    args.extend(['-I'+str(SOURCE),'-Werror','-Wno-unused-parameter'])
    build.command(args,env,'neptune-'+output.stem,build.BUILD/'renderer')


def qemu_overlay(env,device_source=None,destination=OUTPUT,label='neptune'):
    destination.mkdir(parents=True,exist_ok=True)
    qemu=build.BUILD/'qemu'
    def command(target):
        result=subprocess.run(['ninja','-t','commands',target],env=env,cwd=qemu,text=True,capture_output=True,check=True)
        return shlex.split(result.stdout.splitlines()[-1])
    compiler=command('libcommon.a.p/ui_cocoa.m.o')
    sources=[build.REPO/'experimental/metal-headless/adapter.m',device_source or SOURCE/'qemu-device.m',SOURCE/'wire.c']
    objects=[]
    for source in sources:
        obj=destination/('qemu-'+source.stem+'.o'); args=compiler.copy()
        args[args.index('-c')+1]=str(source)
        for option in ('-o','-MQ','-MF'):
            args[args.index(option)+1]=str(obj)+('.d' if option=='-MF' else '')
        args.extend(['-I'+str(SOURCE),'-I'+str(build.REPO/'experimental/metal-headless'),'-Werror'])
        build.command(args,env,label+'-'+obj.stem,qemu); objects.append(obj)
    binary=destination/'qemu-system-aarch64-neptune-snapshot'
    link=command('qemu-system-aarch64-unsigned'); link[link.index('-o')+1]=str(binary)
    link[3:3]=[str(p) for p in objects]; link.extend(['-framework','Metal'])
    build.command(link,env,label+'-qemu-link',qemu)
    build.command(['codesign','--force','--sign','-','--timestamp=none','--identifier','org.perpendicular.graphics-experiment.neptune-snapshot',
        '--entitlements',build.SRC/'qemu/accel/hvf/entitlements.plist',binary],env,label+'-qemu-sign')
    build.command(['codesign','--verify','--strict',binary],env,label+'-qemu-sign-verify')
    return binary


def causal_reader(env):
    directory=OUTPUT/'mutants/ignore-ready'; directory.mkdir(parents=True,exist_ok=True)
    original=(SOURCE/'qemu-device.m').read_text()
    mutated=replace_once(original,'if(poll(&fd,1,0)>0)','if(poll(&fd,1,0)>=0)')
    mutated=replace_once(mutated,'else if(s->overwritten && fd.revents&POLLIN)','else if(s->overwritten)')
    source=directory/'qemu-device.m'; source.write_text(mutated)
    binary=qemu_overlay(env,source,directory,'neptune-mutant-ignore-ready')
    result=subprocess.run([build.sys.executable,str(SOURCE/'test-pipeline.py'),'--withheld',
        '--qemu-binary',str(binary),'--label','neptune-mutant-ignore-ready'],env=env,
        stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=45)
    (build.LOGS/'neptune-mutant-ignore-ready-tests.log').write_text(result.stdout)
    if result.returncode==0 or 'Callback state timeout' not in result.stdout or "'completed': 1" not in result.stdout:
        raise RuntimeError('Ready-fd causal mutant did not fail for expected early-read cause')
    receipt={'result':'pass','mutation':'ignore producer ready fd after verified original overwrite',
        'expected_failure':'Consumer read occurs despite withheld token',
        'source_sha256':build.file_hash(source),'binary_sha256':build.file_hash(binary),
        'safety':'Overwrite has completed and been pixel-verified before mutant reads; no unfinished GPU producer is raced'}
    (build.BASE/'provenance/neptune-causality.json').write_text(json.dumps(receipt,indent=2)+'\n')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--registry-only',action='store_true')
    parser.add_argument('--test',action='store_true')
    parser.add_argument('--causality',action='store_true')
    args=parser.parse_args()
    env=build.prerequisites(optimization='0')
    env['DYLD_FALLBACK_LIBRARY_PATH']=str(build.PREFIX/'lib')+':'+str(build.PREFIX/'ANGLE.xcarchive/Products/usr/local/lib')
    env['NPT_BACKEND']='dxmt'; env['DXMT_LOG_PATH']=str(build.LOGS); env['ZERO_AR_DATE']='1'
    build.command([build.sys.executable,build.REPO/'scripts/graphics-fetch.py','--verify'],env,'neptune-verify-sources')
    OUTPUT.mkdir(parents=True,exist_ok=True)
    original=build.BUILD/'renderer/src/libvirgl.a'; original_hash=build.file_hash(original)
    objects=[]
    for source in patched_sources():
        obj=OUTPUT/('neptune_'+source.name+'.o'); compile_source(source,obj,env); objects.append(obj)
    for name in ('snapshot','wire'):
        obj=OUTPUT/(name+'.o'); compile_source(SOURCE/(name+'.c'),obj,env); objects.append(obj)
    archive=OUTPUT/'libvirgl-snapshot.a'; shutil.copyfile(original,archive)
    build.command(['ar','-r',archive,*objects],env,'neptune-overlay-archive')
    if not args.registry_only:
        fixture=OUTPUT/'decoder-fixture.o'; compile_source(SOURCE/'decoder-fixture.c',fixture,env)
        link=recipe('server/virgl_render_server',env)
        link=[x for x in link if not (x.startswith('server/') and x.endswith('.o'))]
        link[link.index('-o')+1]=str(OUTPUT/'decoder-fixture')
        link.insert(3,str(fixture))
        link=[str(archive) if x=='src/libvirgl.a' else x for x in link]
        build.command(link,env,'neptune-decoder-link',build.BUILD/'renderer')
        qemu_overlay(env)
        if args.test or args.causality:
            build.command([build.sys.executable,SOURCE/'test-pipeline.py'],env,'neptune-pipeline-tests')
            build.command([build.sys.executable,SOURCE/'test-pipeline.py','--withheld'],env,'neptune-pipeline-withheld-tests')
            build.command([build.sys.executable,SOURCE/'test-guards.py'],env,'neptune-guard-tests')
        if args.causality:
            causal_reader(env)
    if build.file_hash(original)!=original_hash: raise RuntimeError('Base renderer archive changed')
    report={'result':'registry_built','base_archive_sha256':original_hash,'archive_sha256':build.file_hash(archive),
        'compiler_jobs':1,'qemu_pin':'88e5ee7ec6703662fec7b638cca74c4769e683d6',
        'renderer_pin':'e83b630ea14c9e8be33955462c80272f44927031',
        'source_changes':'Verified edits in three private source copies; original pins unchanged',
        'inputs':[{'path':str(p.relative_to(build.REPO)),'sha256':build.file_hash(p)}
            for p in [Path(__file__).resolve(),*sorted(SOURCE.glob('*'))] if p.is_file()]}
    (build.BASE/'provenance/neptune-snapshot-build.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':
    main()
