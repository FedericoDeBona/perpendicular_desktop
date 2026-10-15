#!/usr/bin/env python3
"""Compile/link a separate Metal-headless QEMU overlay; never patch pristine pins."""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess

SPEC = importlib.util.spec_from_file_location('graphics_build', Path(__file__).with_name('graphics-build.py'))
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
ROOT = build.REPO
SOURCE = ROOT/'experimental/metal-headless'
OUTPUT = build.BUILD/'metal-headless'


def ninja_command(target, env):
    commands = subprocess.run(
        ['ninja', '-t', 'commands', target], cwd=build.BUILD/'qemu', env=env,
        text=True, capture_output=True, check=True).stdout
    return shlex.split(commands.splitlines()[-1])


def compile_overlay(source,output,label,env):
    output.mkdir(parents=True,exist_ok=True)
    recipe=ninja_command('libcommon.a.p/ui_cocoa.m.o',env)
    if '-c' not in recipe or any(option not in recipe for option in ('-o','-MQ','-MF')):
        raise RuntimeError('Pinned QEMU compiler recipe changed')
    source_index=recipe.index('-c')+1
    objects=[]
    for name in ('adapter','test-device'):
        command=recipe.copy()
        command[source_index]=str(source/(name+'.m'))
        for option in ('-o','-MQ','-MF'):
            position=command.index(option)+1
            command[position]=str(output/(name+('.o.d' if option=='-MF' else '.o')))
        command.extend(['-I'+str(source),'-Werror'])
        build.command(command,env,label+'-'+name+'-compile',build.BUILD/'qemu')
        objects.append(output/(name+'.o'))
    link=ninja_command('qemu-system-aarch64-unsigned',env)
    if '-o' not in link or 'qemu-system-aarch64-unsigned' not in link[link.index('-o')+1]:
        raise RuntimeError('Pinned QEMU linker recipe changed')
    binary=output/'qemu-system-aarch64-metal-headless'
    link[link.index('-o')+1]=str(binary)
    link[3:3]=[str(x) for x in objects]
    link.extend(['-framework','Metal'])
    build.command(link,env,label+'-link',build.BUILD/'qemu')
    entitlement=build.SRC/'qemu/accel/hvf/entitlements.plist'
    build.command(['codesign','--force','--sign','-','--timestamp=none',
        '--identifier','org.perpendicular.graphics-experiment.metal-headless',
        '--entitlements',entitlement,binary],env,label+'-sign')
    build.command(['codesign','--verify','--strict',binary],env,label+'-sign-verify')
    return binary


def causal_checks(env):
    original=(SOURCE/'adapter.m').read_text()
    unbind='''    if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
        error_report("perp-metal: failed to release initialization thread context"); exit(1);
    }'''
    channels='''dst[x] = 0xff000000u | (uint32_t)src[0] << 16 |
                     (uint32_t)src[1] << 8 | src[2];'''
    mutations=[('thread-handoff',unbind,'    /* Causal mutant: leave context current on initialization thread. */',
        'Callback state timeout','read context unavailable (allocation=1 EGL=0x3002)'),
        ('color-channels',channels,'''dst[x] = 0xff000000u | (uint32_t)src[2] << 16 |
                     (uint32_t)src[1] << 8 | src[0];''',
        'private framebuffer colors/orientation/crop mismatch',None)]
    results=[]
    for name,before,after,expected,process_expected in mutations:
        if original.count(before)!=1:
            raise RuntimeError('Causal mutation target changed: '+name)
        variant=OUTPUT/'mutants'/name
        variant_source=variant/'source'
        variant_source.mkdir(parents=True,exist_ok=True)
        for filename in ('adapter.h','test-device.m'):
            shutil.copyfile(SOURCE/filename,variant_source/filename)
        (variant_source/'adapter.m').write_text(original.replace(before,after))
        label='headless-mutant-'+name
        binary=compile_overlay(variant_source,variant,label,env)
        result=subprocess.run([build.sys.executable,str(SOURCE/'test-headless.py'),str(binary),
            '--label',label],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
        (build.BASE/('logs/'+label+'-tests.log')).write_text(result.stdout)
        process_log=(build.BASE/('logs/'+label+'-process.log')).read_text()
        if result.returncode==0 or expected not in result.stdout or (process_expected and process_expected not in process_log):
            raise RuntimeError('Causal mutant did not fail for its expected reason: '+name)
        results.append({'mutation':name,'expected_failure':expected,'exit_code':result.returncode,
            'source_sha256':build.file_hash(variant_source/'adapter.m'),
            'binary_sha256':build.file_hash(binary),'result':'expected_failure'})
    (build.BASE/'provenance/headless-causality.json').write_text(json.dumps(
        {'result':'pass','mutations':results,'guest_cpu':False,'guest_disks':False},indent=2)+'\n')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test',action='store_true',help='run host-only QMP/VNC callback checks')
    parser.add_argument('--causality',action='store_true',help='also require two deliberately broken variants to fail')
    args=parser.parse_args()
    env=build.prerequisites(optimization='0')
    angle=build.PREFIX/'ANGLE.xcarchive/Products/usr/local/lib'
    env['DYLD_FALLBACK_LIBRARY_PATH']=str(build.PREFIX/'lib')+':'+str(angle)
    env['ANGLE_DEFAULT_PLATFORM']='metal'
    build.command([build.sys.executable, ROOT/'scripts/graphics-fetch.py','--verify','--qemu-wraps'],env,'headless-verify-sources')
    protected=[build.BUILD/'qemu/qemu-system-aarch64-unsigned',build.PREFIX/'bin/qemu-system-aarch64']
    before={str(p):build.file_hash(p) for p in protected}
    binary=compile_overlay(SOURCE,OUTPUT,'headless',env)
    build.command([binary,'-display','help'],env,'headless-display-help')
    files=[Path(__file__).resolve(),*sorted(SOURCE.glob('*'))]
    receipt={'base_qemu_pin':'88e5ee7ec6703662fec7b638cca74c4769e683d6',
        'binary':str(binary),'binary_sha256':build.file_hash(binary),
        'inputs':[{'path':str(p.relative_to(ROOT)),'sha256':build.file_hash(p)} for p in files if p.is_file()],
        'method':'Extra native objects in pinned Ninja link recipe; source trees and base binaries unchanged',
        'compiler_jobs':1,'guest_or_disks':False}
    (build.BASE/'provenance/headless-build.json').write_text(json.dumps(receipt,indent=2)+'\n')
    if args.test or args.causality:
        build.command([build.sys.executable,SOURCE/'test-headless.py',str(binary)],env,'headless-callback-tests')
    if args.causality:
        causal_checks(env)
    after={str(p):build.file_hash(p) for p in protected}
    if before!=after:
        raise RuntimeError('Protected base QEMU binary changed')
    receipt['protected_base_binaries']=before
    (build.BASE/'provenance/headless-build.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('Private overlay built: '+str(binary))


if __name__=='__main__':
    main()
