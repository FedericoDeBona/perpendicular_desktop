#!/usr/bin/env python3
"""Private, host-only DXMT producer/ANGLE consumer over Unix SCM_RIGHTS."""
import importlib.util
import json
from pathlib import Path
import socket
import subprocess

SPEC=importlib.util.spec_from_file_location('graphics_build',Path(__file__).with_name('graphics-build.py'))
build=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
SOURCE=build.REPO/'experimental/producer-sync'
OUTPUT=build.BUILD/'producer-sync'


def main():
    env=build.prerequisites(optimization='0')
    OUTPUT.mkdir(parents=True,exist_ok=True)
    env['DXMT_LOG_PATH']=str(build.BASE/'logs')
    env['ANGLE_DEFAULT_PLATFORM']='metal'
    build.command([build.sys.executable,build.REPO/'scripts/graphics-fetch.py','--verify'],env,'producer-verify-sources')
    angle=build.PREFIX/'ANGLE.xcarchive/Products/usr/local/lib'
    env['DYLD_FALLBACK_LIBRARY_PATH']=str(build.PREFIX/'lib')+':'+str(angle)
    headers=build.SRC/'WebKit/Source/ThirdParty/ANGLE/include'
    common=['xcrun','--sdk','macosx','clang++','-std=c++17','-O0','-Wall','-Wextra','-Werror',
        '-I'+str(build.PREFIX/'include'),'-I'+str(SOURCE)]
    producer=OUTPUT/'dxmt-producer'
    build.command([*common,'-isystem',build.SRC/'dxmt/include/native/windows',
        '-isystem',build.SRC/'dxmt/include/native/directx',SOURCE/'producer.cpp',
        '-L'+str(build.PREFIX/'lib'),'-ldxmt-native','-Wl,-rpath,'+str(build.PREFIX/'lib'),
        '-o',producer],env,'producer-compile')
    consumer=OUTPUT/'angle-consumer'
    build.command([*common,'-fobjc-arc','-I'+str(headers),SOURCE/'consumer.mm',
        '-L'+str(angle),'-lEGL','-Wl,-rpath,'+str(angle),'-framework','Foundation','-framework','Metal',
        '-o',consumer],env,'producer-consumer-compile')
    def pair(label,withhold=False):
        left,right=socket.socketpair(socket.AF_UNIX,socket.SOCK_STREAM)
        processes=[]
        try:
            with (build.BASE/('logs/'+label+'-run.log')).open('w') as producer_log, \
                 (build.BASE/('logs/'+label+'-consumer-run.log')).open('w') as consumer_log:
                p=subprocess.Popen([str(producer),str(left.fileno()),*(['--withhold-first'] if withhold else [])],
                    env=env,pass_fds=(left.fileno(),),stdout=producer_log,stderr=subprocess.STDOUT)
                processes.append(p)
                c=subprocess.Popen([str(consumer),str(right.fileno())],env=env,pass_fds=(right.fileno(),),stdout=consumer_log,stderr=subprocess.STDOUT)
                processes.append(c); left.close(); right.close()
                c_return=c.wait(timeout=60); p_return=p.wait(timeout=15)
            producer_text=(build.BASE/('logs/'+label+'-run.log')).read_text()
            consumer_text=(build.BASE/('logs/'+label+'-consumer-run.log')).read_text()
            if withhold:
                if not p_return or not c_return or 'deliberately withholds producer Signal' not in producer_text or \
                    'Producer completion fd failed or timed out' not in consumer_text or 'consumer_frame' in consumer_text:
                    raise RuntimeError('Missing-fence negative fixture failed for unexpected reason')
            elif c_return or p_return:
                raise RuntimeError('Producer/consumer failed; inspect private producer logs')
            return producer_text,consumer_text
        finally:
            left.close(); right.close()
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
    producer_text,consumer_text=pair('producer')
    producer_rows=[json.loads(line) for line in producer_text.splitlines() if line.startswith('{')]
    consumer_rows=[json.loads(line) for line in consumer_text.splitlines() if line.startswith('{')]
    pair('producer-withheld',True)
    if not producer_rows or not consumer_rows or producer_rows[-1].get('result')!='pass' or consumer_rows[-1].get('result')!='pass':
        raise RuntimeError('Missing successful producer/consumer receipt')
    report={'result':'pass','producer':producer_rows,'consumer':consumer_rows,
        'negative_checks':['missing_producer_signal_rejected_before_pixel_read'],
        'compiler_jobs':1,'guest_or_vm_started':False,'tcp':False,
        'pins':{'dxmt':'2a7dd3e7d22541611433441b82894ec5bca75ca2','directx-native':'52fb0875e5717119becd89e7c4f258321aeec427'},
        'inputs':[{'path':str(p.relative_to(build.REPO)),'sha256':build.file_hash(p)} for p in [Path(__file__).resolve(),*sorted(SOURCE.glob('*'))] if p.is_file()],
        'binaries':[{'path':str(p),'sha256':build.file_hash(p)} for p in (producer,consumer)]}
    (build.BASE/'provenance/producer-sync.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':
    main()
