#!/usr/bin/env python3
"""Actual Neptune decoder/DXMT snapshot to QEMU DisplaySurface and Unix VNC."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'.tools/graphics-experiment'
BUILD=BASE/'build/neptune-snapshot'
SPEC=importlib.util.spec_from_file_location('headless_fixture',ROOT/'experimental/metal-headless/test-headless.py')
fixture=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


def pixels(width,height,inverted):
    target=bytearray(fixture.expected(width,height))
    if inverted:
        swap={bytes((0,0,255,0)):bytes((255,255,255,0)),bytes((255,255,255,0)):bytes((0,0,255,0)),
            bytes((0,255,0,0)):bytes((255,0,0,0)),bytes((255,0,0,0)):bytes((0,255,0,0))}
        for index in range(0,len(target),4):
            old=bytes(target[index:index+4]); target[index:index+4]=swap.get(old,old)
    return bytes(target)


def run(withheld=False,qemu_binary=None,label=None):
    env=os.environ.copy()
    env['DYLD_FALLBACK_LIBRARY_PATH']=str(BASE/'prefix/lib')+':'+str(BASE/'prefix/ANGLE.xcarchive/Products/usr/local/lib')
    env['DXMT_LOG_PATH']=str(BASE/'logs'); env['ANGLE_DEFAULT_PLATFORM']='metal'; env['NPT_BACKEND']='dxmt'
    if withheld: env['PERP_SNAPSHOT_WITHHOLD']='1'
    else: env.pop('PERP_SNAPSHOT_WITHHOLD',None)
    label=label or ('neptune-pipeline-withheld' if withheld else 'neptune-pipeline')
    assert label.replace('-','').isalnum()
    qemu_binary=qemu_binary or BUILD/'qemu-system-aarch64-neptune-snapshot'
    assert qemu_binary.resolve().is_relative_to(BUILD.resolve())
    processes=[]; records=[]
    left,right=socket.socketpair(socket.AF_UNIX,socket.SOCK_STREAM)
    with tempfile.TemporaryDirectory(prefix='perp-npt-',dir='/tmp') as temporary, \
         (BASE/('logs/'+label+'-qemu.log')).open('w') as qlog, \
         (BASE/('logs/'+label+'-producer.log')).open('w') as plog:
        runtime=Path(temporary)
        argv=[str(qemu_binary),'-L',str(BASE/'prefix/share/qemu'),
            '-no-user-config','-nodefaults','-machine','none','-m','16M','-S','-display','egl-headless',
            '-device','perp-neptune-test,id=pixels,channel='+str(right.fileno()),
            '-vnc','unix:'+str(runtime/'vnc.sock'),'-qmp','unix:'+str(runtime/'qmp.sock')+',server=on,wait=off',
            '-monitor','none','-serial','none']
        try:
            qemu=subprocess.Popen(argv,env=env,pass_fds=(right.fileno(),),stdout=qlog,stderr=subprocess.STDOUT)
            processes.append(qemu); right.close()
            qmp_socket=fixture.connect(runtime/'qmp.sock',qemu); q=fixture.QMP(qmp_socket)
            assert q.call('query-cpus-fast')==[] and q.call('query-block')==[]
            vnc_socket=fixture.connect(runtime/'vnc.sock',qemu); v=fixture.VNC(vnc_socket)
            producer=subprocess.Popen([str(BUILD/'decoder-fixture'),str(left.fileno())],env=env,pass_fds=(left.fileno(),),stdout=plog,stderr=subprocess.STDOUT)
            processes.append(producer); left.close()
            for sequence,(width,height) in enumerate([(800,600),(800,600),(1920,1080),(1920,1080),(803,607),(803,607),(800,600),(800,600)],1):
                q.set('advance',True)
                if withheld:
                    state=q.await_state(lambda s:s['cancelled']==1)
                    assert state['completed']==0 and state['backend']['completed']==0 and state['backend']['timed_out']==1,state
                    assert state['backend']['peak_readback_bytes']==0 and state['backend']['max_readback_us']==0,state
                    w,h,data=v.snapshot()
                    assert (w,h)==(800,600) and data!=pixels(w,h,False),'Unready snapshot exposed expected producer pixels'
                    break
                state=q.await_state(lambda s:s['completed']==sequence)
                assert state['error'] is None,state
                w,h,data=v.snapshot()
                assert (w,h)==(width,height),(sequence,w,h)
                assert data==pixels(w,h,sequence%2==0),'Real Neptune/VNC snapshot mismatch at frame '+str(sequence)
                records.append({'frame':sequence,'width':w,'height':h,'exact_pixels':w*h})
            assert producer.wait(timeout=5)==0,'Real decoder producer failed'
            producer_rows=[json.loads(line) for line in (BASE/('logs/'+label+'-producer.log')).read_text().splitlines() if line.startswith('{')]
            final_registry=producer_rows[-1]['registry']
            expected_frames=1 if withheld else 8
            assert final_registry['captures']==expected_frames and final_registry['acked']==expected_frames and final_registry['active']==0,final_registry
            assert final_registry['dropped_busy']==expected_frames and final_registry['exports']==0 and final_registry['contexts']==0,final_registry
            q.set('closed',True)
            final=q.get()
            assert final['active'] is False and final['native_released']==expected_frames and final['mappings_released']==expected_frames,final
            assert final['backend']['active_leases']==0 and final['backend']['closed'],final
            q.call('quit'); assert qemu.wait(timeout=5)==0
            report={'result':'pass','withheld':withheld,'records':records,'final':final,
                'registry':final_registry,
                'exact_pixels':sum(x['exact_pixels'] for x in records),'guest_cpu':False,'guest_disks':False,'tcp':False}
            (BASE/('provenance/'+label+'.json')).write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(report))
        finally:
            left.close(); right.close()
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--withheld',action='store_true')
    parser.add_argument('--qemu-binary',type=Path)
    parser.add_argument('--label')
    args=parser.parse_args()
    run(args.withheld,args.qemu_binary,args.label)
