#!/usr/bin/env python3
"""Owned diskless, paused Cocoa/Neptune/TPM configuration fixture. No live VM."""
import argparse
import hashlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
sys.dont_write_bytecode=True

REPO=Path(__file__).resolve().parents[2]
BASE=REPO/'.tools/graphics-experiment'
OUT=BASE/'build/cocoa-neptune'
BINARY=BASE/'prefix/bin/qemu-system-aarch64'
spec=importlib.util.spec_from_file_location('live_fixture',REPO/'experimental/neptune-live/test-live.py')
live=importlib.util.module_from_spec(spec);spec.loader.exec_module(live)
headless=live.headless
# Same real modern VirtIO queue driver, with only PCI slot changed to normal7.
source=textwrap.dedent(inspect.getsource(live.GPU.__init__))
assert source.count('+(1<<15)')==1
namespace=dict(live.__dict__);exec(compile(source.replace('+(1<<15)','+(7<<15)'),__file__,'exec'),namespace)
GPU=type('CocoaGPU',(live.GPU,),{'__init__':namespace['__init__']})


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def stop_group(process):
    if process is None:return
    if process.poll() is None:
        process.terminate()
        try:process.wait(timeout=4)
        except subprocess.TimeoutExpired:process.kill();process.wait(timeout=4)
    # The session/process group was created solely for this fixture; renderer
    # children inherit it. No existing VM, app or unrelated PID is targeted.
    try:os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError:pass


def run(args):
    case=OUT/args.label
    case.mkdir(parents=True,exist_ok=False)
    angle=BASE/'prefix/ANGLE.xcarchive/Products/usr/local/lib'
    selected={'DYLD_FALLBACK_LIBRARY_PATH':str(BASE/'prefix/lib')+':'+str(angle),
              'ANGLE_DEFAULT_PLATFORM':'metal','NPT_BACKEND':'dxmt',
              'RENDER_SERVER_EXEC_PATH':str(BASE/'prefix/libexec/virgl_render_server'),
              'DXMT_LOG_PATH':str(case/'dxmt'),'DYLD_PRINT_LIBRARIES':'1'}
    if not args.fallback_only:selected['DYLD_LIBRARY_PATH']=selected['DYLD_FALLBACK_LIBRARY_PATH']
    if args.explicit_d3d:
        for name in ('NPT_D3D11_LIBRARY_PATH','NPT_DXGI_LIBRARY_PATH','NPT_D3D12_LIBRARY_PATH'):
            selected[name]=str(BASE/'prefix/lib/libdxmt-native.dylib')
    env={key:value for key,value in os.environ.items()
         if not key.startswith(('DYLD_','QEMU_','VIRGL_','GALLIUM_','NPT_','ANGLE_','PERP_'))
         and key not in ('LD_PRELOAD','LD_LIBRARY_PATH','RENDER_SERVER_EXEC_PATH','DXMT_LOG_PATH')}
    env.update(selected)
    before={str(path.relative_to(REPO)):digest(path) for path in [BINARY,BASE/'prefix/lib/libvirglrenderer.1.dylib',BASE/'prefix/libexec/virgl_render_server',BASE/'prefix/lib/libdxmt-native.dylib']}
    record={'label':args.label,'environment':selected,'protected_hashes':before,'guest_disks':False,'firmware_payload':False,'guest_CPU_executed':False,'args':vars(args).copy()}
    processes=[];peers=[];q=None;child=None
    with tempfile.TemporaryDirectory(prefix='perp-cocoa-',dir='/tmp') as temporary,(case/'qemu.log').open('w') as qlog,(case/'swtpm.log').open('w') as tlog:
        temporary=Path(temporary)
        try:
            command=[str(BINARY),'-L',str(BASE/'prefix/share/qemu'),'-no-user-config','-nodefaults','-name','Perpendicular isolated Cocoa probe',
                     '-machine','virt,gic-version=3,highmem='+args.highmem,'-accel',args.accel,'-cpu','host' if args.accel=='hvf' else 'cortex-a72',
                     '-m','128M','-smp','1','-S','-nic','none','-vga','none','-display','cocoa,gl='+args.gl,
                     '-device','virtio-ramfb-gl,id=pixels,addr=7,disable-legacy=on,neptune=on,blob=on,hostmem=256M',
                     '-qmp','unix:'+str(temporary/'qmp.sock')+',server=on,wait=off',
                     '-qtest','unix:'+str(temporary/'qtest.sock')+',server=on,wait=off','-qtest-log','/dev/null','-monitor','none','-serial','none']
            if args.vnc:command+=['-vnc','unix:'+str(temporary/'vnc.sock')]
            if args.tpm:
                state=temporary/'tpm';state.mkdir(mode=0o700)
                tpm=subprocess.Popen(['/opt/homebrew/bin/swtpm','socket','--tpm2','--tpmstate','dir='+str(state),
                    '--ctrl','type=unixio,path='+str(temporary/'tpm.sock'),'--flags','not-need-init,startup-clear'],env=env,stdout=tlog,stderr=subprocess.STDOUT,start_new_session=True)
                processes.append(tpm)
                deadline=time.monotonic()+5
                while not (temporary/'tpm.sock').exists():
                    assert tpm.poll() is None and time.monotonic()<deadline,'Owned swtpm startup failed'
                    time.sleep(.02)
                command+=['-chardev','socket,id=chrtpm,path='+str(temporary/'tpm.sock'),'-tpmdev','emulator,id=tpm0,chardev=chrtpm',
                          '-device','tpm-tis-device,tpmdev=tpm0'+(',ppi=off' if args.ppi_off else '')]
            record['command']=command
            child=subprocess.Popen(command,env=env,stdout=qlog,stderr=subprocess.STDOUT,start_new_session=True);processes.append(child)
            peer=headless.connect(temporary/'qmp.sock',child);peers.append(peer);q=headless.QMP(peer)
            record['status']=q.call('query-status');assert record['status']['status']=='prelaunch'
            assert q.call('query-block')==[]
            record['tpm']=q.call('query-tpm')
            record['pci']=[device for bus in q.call('query-pci') for device in bus['devices'] if device.get('qdev_id')=='pixels']
            assert record['pci'][0]['slot']==7
            record['qmp_ready']=True
            if args.render:
                assert args.highmem=='off','The isolated fixture queue driver requires low ECAM; highmem=on is a startup-only check'
                peer=headless.connect(temporary/'qtest.sock',child);peers.append(peer)
                t=live.QTest(peer);gpu=GPU(t)
                caps=[]
                for index in range(8):
                    data=gpu.send(0x108,live.pack('II',index,0))
                    values=__import__('struct').unpack_from('<IIII',data,24)
                    caps.append(values)
                    if values[0]==7:break
                record['capsets']=caps
                assert any(cap[0]==7 for cap in caps),'Actual Neptune capset was not advertised'
                capset=gpu.send(0x109,live.pack('II',7,0))
                wire,flags=__import__('struct').unpack_from('<II',capset,24)
                record['neptune_capset']={'wire_format_version':wire,'caps_flags':flags}
                assert wire==2 and flags==0xb6,'Actual native DXMT capabilities differ from the pinned backend'
                n=live.Neptune(gpu);width,height=n.create(64,64)
                n.clear(0,(1,0,0,1),width,height);n.clear(1,(0,1,0,1),width,height);n.signal(1)
                for index,(address,pitch) in enumerate(n.originals):
                    expected=bytes((0,0,255,255) if index==0 else (0,255,0,255))*width
                    deadline=time.monotonic()+10
                    while True:
                        data=t.read(address,pitch*height)
                        if all(data[y*pitch:y*pitch+width*4]==expected for y in range(height)):break
                        assert time.monotonic()<deadline,'Real D3D texture pixels did not complete'
                        time.sleep(.01)
                record['actual_GPU_matched_pixels']=width*height*2
                gpu.scanout(200,width,height);gpu.flush(200,width,height)
                record['set_scanout_blob_completed']=True
                time.sleep(.25)
                record['Cocoa_display_pixels_verified']=False
            q.call('quit');child.wait(timeout=5);record['exit_code']=child.returncode
            record['result']='pass' if child.returncode==0 else 'nonzero_exit'
        except BaseException as error:
            record['result']='failed';record['error']=str(error);record['exit_code']=child.poll() if child else None
        finally:
            if child is not None and child.poll() is None and q is not None:
                try:q.call('quit');child.wait(timeout=3)
                except BaseException:pass
            for process in reversed(processes):stop_group(process)
            if child is not None:record['final_exit_code']=child.returncode
            for peer in peers:peer.close()
    for name,value in before.items():assert digest(REPO/name)==value,'Protected graphics artifact changed'
    log=(case/'qemu.log').read_text(errors='replace')
    record['loaded_library_lines']=[line for line in log.splitlines() if 'dyld[' in line and any(word in line for word in ('libvirglrenderer','libdxmt-native','libEGL','libGLES','virgl_render_server'))]
    record['diagnostic_tail']=log.splitlines()[-25:]
    (case/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps({'label':args.label,'result':record['result'],'qmp_ready':record.get('qmp_ready',False),'matched_pixels':record.get('actual_GPU_matched_pixels',0),'exit':record.get('final_exit_code'),'error':record.get('error'),'receipt':str((case/'result.json').relative_to(REPO))},indent=2))
    return record['result']=='pass'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label',required=True);parser.add_argument('--accel',choices=('hvf','tcg'),default='hvf')
    parser.add_argument('--gl',choices=('es','on','off'),default='es')
    parser.add_argument('--highmem',choices=('on','off'),default='off')
    parser.add_argument('--render',action='store_true');parser.add_argument('--tpm',action='store_true');parser.add_argument('--ppi-off',action='store_true')
    parser.add_argument('--vnc',action='store_true');parser.add_argument('--fallback-only',action='store_true');parser.add_argument('--explicit-d3d',action='store_true')
    args=parser.parse_args();assert args.label and args.label.replace('-','').isalnum()
    raise SystemExit(0 if run(args) else 1)


if __name__=='__main__':main()
