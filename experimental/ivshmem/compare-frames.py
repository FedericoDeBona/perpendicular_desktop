#!/usr/bin/env python3
"""Three short comparisons on one scratch ClassicNotepad in the private clone.

Uses existing authenticated control; no new guest port. Each run updates the
same scratch edit 48 times at 100ms. Reports capture-selection-to-Metal-callback times,
clock uncertainty, CPU deltas and frame sequence counts. No optical latency claim.
"""
import argparse
import ctypes
import mmap
import os
import json
from pathlib import Path
import socket
import statistics
import struct
import subprocess
import time


def exact(s,n):
    result=b''
    while len(result)<n:
        chunk=s.recv(n-len(result))
        if not chunk:raise RuntimeError('Control closed')
        result+=chunk
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--pid',type=int,required=True)
    parser.add_argument('--creation',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--order',choices=['ivshmem,raw,lz4','lz4,raw,ivshmem'],default='ivshmem,raw,lz4')
    args=parser.parse_args()
    assert not args.output.exists(), 'New report required'
    root=args.root.resolve();endpoint=root/'Control/control.sock';trace=root/'frame-events.jsonl'
    def request(command,**fields):
        data=json.dumps(dict(command=command,**fields)).encode()
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(70);s.connect(str(endpoint));s.sendall(struct.pack('<I',len(data))+data)
            n=struct.unpack('<I',exact(s,4))[0];assert 0<n<=1048576
            reply=json.loads(exact(s,n))
        if not reply['ok']:raise RuntimeError(reply)
        return reply['result']
    def clock():return request('trial_clock')
    def clocks():return [clock() for _ in range(3)]
    def events():return [json.loads(line) for line in trace.read_text().splitlines() if line]
    def geometry():
        windows=request('geometry_snapshot')['windows']
        assert len(windows)==1, 'One scratch window required'
        assert windows[0]['guest']['captureDevice']['hardwareDevice'] is True
        assert windows[0]['guest']['captureDevice']['softwareRecovery'] is False
        return windows[0]
    def host_cpu():
        rows=[]
        for line in subprocess.check_output(['ps','-axo','pid=,time=,comm='],text=True).splitlines():
            parts=line.strip().split(None,2)
            if len(parts)!=3:continue
            pid,cpu,path=parts
            if ('Perpendicular IVSHMEM.app/Contents/MacOS/Perpendicular' not in path and
                not (str(root/'Runtimes')+'/' in path and Path(path).name in ('qemu-system-aarch64','virgl_render_server'))):continue
            fields=cpu.split(':');seconds=sum(float(v)*60**i for i,v in enumerate(reversed(fields)))
            rows.append({'pid':int(pid),'kind':Path(path).name,'seconds':seconds})
        return rows
    def stimulus(count,interval):
        reply=request('execute',executable='C:\\ProgramData\\PerpendicularIVSHMEM\\frame-stimulus.exe',
                      args=[str(args.pid),args.creation,str(count),str(interval)],timeoutSeconds=30)
        assert reply['exitCode']==0 and not reply['timedOut'] and not reply['outputTruncated'],reply
        return json.loads(reply['stdout'])
    def ready():
        deadline=time.monotonic()+15
        while True:
            try:
                if request('status')['connected'] and request('status')['frameChannel']:return clock()
            except (RuntimeError,OSError):pass
            if time.monotonic()>deadline:raise RuntimeError('Trial guest did not reconnect')
            time.sleep(0.25)
    def enable_unused_region():
        config=json.loads((root/'machine.json').read_text())
        path=f"/tmp/perpendicular-{os.getuid()}-{config['id'][:8]}.sock"
        with socket.socket(socket.AF_UNIX) as qmp:
            qmp.settimeout(5);qmp.connect(path);stream=qmp.makefile('rwb');json.loads(stream.readline())
            def operation(name,arguments=None):
                stream.write((json.dumps({'execute':name,'arguments':arguments or {}})+'\n').encode());stream.flush()
                while True:
                    reply=json.loads(stream.readline())
                    if 'error' in reply:raise RuntimeError(reply['error'])
                    if 'return' in reply:return reply['return']
            operation('qmp_capabilities');assert operation('query-uuid')['UUID']==config['id']
            backing=Path(operation('qom-get',{'path':'/objects/ivshmem','property':'mem-path'}))
        assert backing.resolve().is_relative_to(root) and backing.stat().st_size==64*1024*1024
        with backing.open('r+b') as file,mmap.mmap(file.fileno(),0) as memory:
            assert struct.unpack_from('<I',memory,0)[0]==0x49565331 and struct.unpack_from('<I',memory,4)[0]==0
            slot=((len(memory)-4096)//3)//4096*4096
            assert all(struct.unpack_from('<II',memory,4096+i*slot)==(0,0) for i in range(3)), 'Only a never-used region can be enabled'
            ctypes.CDLL('/usr/lib/libSystem.B.dylib').OSMemoryBarrier()
            struct.pack_into('<I',memory,4,1)
    report={'definition':'actual frame selection before readback to Metal presented callback; no optical input-to-photon claim',
            'modes':[],'scratchPID':args.pid,'scratchCreation':args.creation,'order':args.order}
    previous_mode=None
    for mode in args.order.split(','):
        (root/'frame-mode').write_text(mode)
        if previous_mode is not None:
            if mode=='ivshmem':enable_unused_region()
            request('ivshmem_disable' if previous_mode=='ivshmem' else 'trial_reconnect');ready()
        previous_mode=mode
        stimulus(3,200);time.sleep(0.75)
        start=geometry();start_index=len(events());cal_before=clocks();host_before=host_cpu()
        stimulus_result=stimulus(48,100)
        time.sleep(0.75)
        host_after=host_cpu();cal_after=clocks();end=geometry()
        selected=events()[start_index:]
        expected={'ivshmem':'ivshmem-raw','raw':'tcp-raw','lz4':'tcp-lz4'}[mode]
        selected=[e for e in selected if e['header'].get('window')==start['id']]
        assert start['id']==end['id'] and (start['guest']['width'],start['guest']['height'])==(end['guest']['width'],end['guest']['height'])
        assert selected and all(e['header'].get('transport')==expected for e in selected), 'Mixed/missing transport'
        received={e['header']['sequence']:e for e in selected if e['event']=='received'}
        presented={}
        for e in selected:
            if e['event']=='presented':presented.setdefault(e['header']['sequence'],e)
        # Counters/events are sampled at separate boundaries (up to one frame).
        # Sequence gaps and explicit drop counters are the direct loss evidence.
        # RPC samples provide offset intervals, not an assumed common clock.
        samples=cal_before+cal_after
        bounds=[(c['hostBefore']-c['guest']['qpc']/c['guest']['frequency'],c['hostAfter']-c['guest']['qpc']/c['guest']['frequency']) for c in samples]
        low=max(b[0] for b in bounds);high=min(b[1] for b in bounds)
        assert low<=high, 'Clock-offset intervals do not overlap'
        offset=(low+high)/2;uncertainty=(high-low)*500
        latencies=[];invalid=[]
        for sequence,e in presented.items():
            h=e['header'];source=h.get('guestCaptureSelectedQPC')
            if source is None:invalid.append({'sequence':sequence,'reason':'capture selection timestamp missing'});continue
            ms=(e['hostTime']-offset-source/cal_before[0]['guest']['frequency'])*1000
            if ms< -uncertainty or ms>5000:invalid.append({'sequence':sequence,'reason':'timestamp outside physical bounds','ms':ms});continue
            latencies.append(ms)
        c0=cal_before[0]['guest'];c1=cal_after[-1]['guest'];elapsed=(c1['qpc']-c0['qpc'])/c0['frequency']
        worker_cpu=(c1['workerCPU100ns']-c0['workerCPU100ns'])/1e7
        system_busy=((c1['systemKernel100ns']+c1['systemUser100ns']-c1['systemIdle100ns'])-(c0['systemKernel100ns']+c0['systemUser100ns']-c0['systemIdle100ns']))/1e7
        previous={r['pid']:r for r in host_before};cpu={}
        for row in host_after:
            if row['pid'] in previous:cpu[row['kind']]=cpu.get(row['kind'],0)+row['seconds']-previous[row['pid']]['seconds']
        produced=end['guest']['captureFrames']-start['guest']['captureFrames']
        assert len(received)<=produced+1, 'Counter boundary mismatch beyond one frame'
        sizes={e['header']['bytes'] for e in received.values()};assert len(sizes)==1
        result={'mode':mode,'window':start['id'],'width':start['guest']['width'],'height':start['guest']['height'],
                'bytesPerFrame':sizes.pop(),'stimulus':stimulus_result,'elapsedSeconds':elapsed,
                'captureFramesDelta':produced,'receivedUnique':len(received),'presentedUnique':len(presented),
                'captureCounterMinusReceived':produced-len(received),'counterBoundaryToleranceFrames':1,
                'receivedSequenceGaps':max(received)-min(received)+1-len(received),
                'ivshmemDropsMaximum':max(e['header'].get('ivshmemDropped',0) for e in received.values()),
                'receivedNotPresented':len(set(received)-set(presented)),
                'wireBytes':sum(e['header'].get('wireBytes',0) for e in received.values()),
                'captureProgressBefore':start['guest']['captureProgress'],'captureProgressAfter':end['guest']['captureProgress'],
                'clockOffsetBounds':bounds,'clockOffsetSeconds':offset,'clockUncertaintyMilliseconds':uncertainty,
                'acquiredFramesDelta':end['guest']['captureProgress']['acquired']-start['guest']['captureProgress']['acquired'],
                'latencyMilliseconds':latencies,'invalidLatencySamples':invalid,
                'workerCPUSeconds':worker_cpu,'guestBusyCPUSeconds':system_busy,
                'hostCPUSecondsByKind':cpu,'hostBefore':host_before,'hostAfter':host_after,
                'calibrationBefore':cal_before,'calibrationAfter':cal_after,'events':selected}
        result['latencyMedianMs']=statistics.median(latencies) if latencies else None
        if len(latencies)>=20:result['latencyP95Ms']=sorted(latencies)[int((len(latencies)-1)*0.95)]
        report['modes'].append(result);args.output.write_text(json.dumps(report,indent=2)+'\n')
        print(mode,{k:result[k] for k in ('captureFramesDelta','receivedUnique','presentedUnique','latencyMedianMs','workerCPUSeconds','guestBusyCPUSeconds')},flush=True)
    print('Comparison saved',args.output)


if __name__=='__main__':main()
