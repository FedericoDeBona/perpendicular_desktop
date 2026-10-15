#!/usr/bin/env python3
"""Real QEMU callback/Metal/PBO/DisplaySurface/VNC test, machine none, no disks."""
import argparse
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

BASE=Path(__file__).resolve().parents[2]/'.tools/graphics-experiment'


def exact(sock, size):
    data=bytearray()
    while len(data)<size:
        part=sock.recv(min(size-len(data),1024*1024))
        if not part: raise AssertionError('Unexpected socket EOF')
        data.extend(part)
    return bytes(data)


def connect(path, process):
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
        if process.poll() is not None: raise AssertionError('Test QEMU exited early')
        try:
            s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
            s.settimeout(4); s.connect(str(path)); return s
        except (FileNotFoundError,ConnectionRefusedError):
            s.close(); time.sleep(.05)
    raise AssertionError('Private test socket did not appear')


class QMP:
    def __init__(self,sock):
        self.sock=sock; self.stream=sock.makefile('rb'); self.sequence=0
        assert 'QMP' in self.line()
        self.call('qmp_capabilities')

    def line(self):
        raw=self.stream.readline(1024*1024)
        assert raw and raw.endswith(b'\n'), 'Invalid QMP framing'
        return json.loads(raw)

    def call(self,op,args=None,allow_error=False):
        self.sequence+=1
        payload={'execute':op,'id':self.sequence}
        if args is not None: payload['arguments']=args
        self.sock.sendall(json.dumps(payload).encode()+b'\n')
        while True:
            response=self.line()
            if response.get('id')!=self.sequence: continue
            if 'error' in response:
                if allow_error: return response
                raise AssertionError(response)
            return response['return']

    def get(self):
        return json.loads(self.call('qom-get',{'path':'/machine/peripheral/pixels','property':'stats'}))

    def set(self,prop,value,allow_error=False):
        return self.call('qom-set',{'path':'/machine/peripheral/pixels','property':prop,'value':value},allow_error)

    def await_state(self,predicate):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            state=self.get()
            if predicate(state): return state
            time.sleep(.03)
        raise AssertionError('Callback state timeout: '+str(state))


class VNC:
    def __init__(self,sock):
        self.sock=sock
        assert exact(sock,12)==b'RFB 003.008\n'
        sock.sendall(b'RFB 003.008\n')
        offered=exact(sock,exact(sock,1)[0]); assert 1 in offered
        sock.sendall(b'\1'); assert exact(sock,4)==b'\0'*4
        sock.sendall(b'\1')
        initial=exact(sock,24)
        self.width,self.height=struct.unpack('!HH',initial[:4])
        name_length=struct.unpack('!I',initial[20:24])[0]
        assert name_length<=4096; exact(sock,name_length)
        # BGRA/X byte memory for little-endian truecolor RGB888.
        pixel_format=struct.pack('!BBBBHHHBBB3x',32,24,0,1,255,255,255,16,8,0)
        sock.sendall(b'\0\0\0\0'+pixel_format)
        sock.sendall(struct.pack('!BBHii',2,0,2,0,-223))
        self.buffer=bytearray(self.width*self.height*4)

    def snapshot(self):
        for attempt in range(4):
            self.sock.sendall(struct.pack('!BBHHHH',3,0,0,0,self.width,self.height))
            resized=False
            while True:
                kind=exact(self.sock,1)[0]
                if kind==2: continue
                if kind==3:
                    cut=exact(self.sock,7); length=struct.unpack('!I',cut[3:])[0]
                    assert length<=1048576; exact(self.sock,length); continue
                assert kind==0, 'Unexpected server message '+str(kind)
                count=struct.unpack('!xH',exact(self.sock,3))[0]
                for rectangle in range(count):
                    x,y,w,h,encoding=struct.unpack('!HHHHi',exact(self.sock,12))
                    if encoding==-223:
                        assert 0<w<=4096 and 0<h<=4096 and w*h<=8*1024*1024
                        self.width,self.height=w,h
                        self.buffer=bytearray(w*h*4); resized=True
                    else:
                        assert encoding==0 and x+w<=self.width and y+h<=self.height
                        pixels=exact(self.sock,w*h*4)
                        for row in range(h):
                            start=((y+row)*self.width+x)*4
                            self.buffer[start:start+w*4]=pixels[row*w*4:(row+1)*w*4]
                break
            if not resized:
                data=bytearray(self.buffer)
                data[3::4]=b'\0'*(self.width*self.height)
                return self.width,self.height,bytes(data)
        raise AssertionError('Resize did not settle')


def expected(width,height,crop=False,solid=False):
    if solid: return bytes((204,136,17,0))*(width*height)
    origin_x,origin_y=(7,11) if crop else (0,0)
    backing_width=width+(22 if crop else 0)
    backing_height=height+(26 if crop else 0)
    out=bytearray()
    for y in range(height):
        physical_y=y+origin_y
        if physical_y==backing_height//2:
            row=bytearray(bytes((204,136,17,0))*backing_width)
        else:
            left,right=((0,0,255,0),(0,255,0,0)) if physical_y<backing_height//2 else ((255,0,0,0),(255,255,255,0))
            row=bytearray(bytes(left)*(backing_width//2)+bytes(right)*(backing_width-backing_width//2))
            row[(backing_width//2)*4:(backing_width//2+1)*4]=bytes((204,136,17,0))
        out.extend(row[origin_x*4:(origin_x+width)*4])
    return bytes(out)


def run(binary,label='headless'):
    records=[]
    assert label.replace('-','').isalnum(), 'Invalid log label'
    log=BASE/('logs/'+label+'-process.log')
    with tempfile.TemporaryDirectory(prefix='perp-gfx-',dir='/tmp') as temporary,log.open('w') as output:
        runtime=Path(temporary)
        # No firmware, disk, network device, guest CPU or Hypervisor invocation.
        argv=[binary,'-L',str(BASE/'prefix/share/qemu'),'-no-user-config','-nodefaults','-machine','none','-m','16M','-S',
            '-display','egl-headless','-device','perp-metal-test,id=pixels',
            '-vnc','unix:'+str(runtime/'vnc.sock'),
            '-qmp','unix:'+str(runtime/'qmp.sock')+',server=on,wait=off',
            '-monitor','none','-serial','none']
        process=subprocess.Popen(argv,stdout=output,stderr=subprocess.STDOUT)
        try:
            qmp_socket=connect(runtime/'qmp.sock',process); q=QMP(qmp_socket)
            assert q.call('query-cpus-fast')==[], 'Host fixture must have no guest CPU'
            assert q.call('query-block')==[], 'Host fixture must have no guest disks'
            vnc_socket=connect(runtime/'vnc.sock',process); v=VNC(vnc_socket)
            def scene(name,width,height,crop=False,solid=False):
                old=q.get()['backend']['completed']
                q.set('scene',name)
                if not solid: q.await_state(lambda s:s['backend']['completed']==old+1)
                w,h,data=v.snapshot()
                assert (w,h)==(width,height),(name,w,h)
                target=expected(w,h,crop,solid)
                assert data==target, name+' framebuffer colors/orientation/crop mismatch'
                records.append({'scene':name,'width':w,'height':h,'exact_pixels':w*h})
                return w,h,data
            scene('2d',320,200,solid=True)
            scene('private',800,600)
            scene('linear',1920,1080)
            scene('crop',803,607,crop=True)
            reference=scene('private',800,600)
            # No producer lease/fence: must preserve the old CPU surface.
            old=q.get()['backend']['rejected']; q.set('scene','no-fence')
            q.await_state(lambda s:s['backend']['rejected']>old)
            assert v.snapshot()==reference
            old=q.get()['backend']['rejected']; q.set('scene','invalid-crop')
            q.await_state(lambda s:s['backend']['rejected']>old)
            assert v.snapshot()==reference
            # A pending producer must not be read, and must not block QMP/VNC.
            old=q.get()['backend']['completed']; q.set('scene','delayed')
            assert q.get()['backend']['completed']==old, 'Read occurred before producer token'
            assert v.snapshot()==reference
            assert q.get()['backend']['completed']==old, 'Read occurred before producer token'
            q.set('ready',True)
            q.await_state(lambda s:s['backend']['completed']==old+1)
            assert v.snapshot()==reference
            # Stalled GPU completion: bounded cancellation, no guessed fence.
            old=q.get()['backend']['timed_out']; q.set('scene','timeout')
            q.await_state(lambda s:s['backend']['timed_out']==old+1)
            assert v.snapshot()==reference
            # A resize supersedes a pending read lease before releasing native handles.
            old=q.get()['abandoned']; q.set('scene','delayed')
            scene('crop',803,607,crop=True)
            assert q.get()['abandoned']>old
            scene('2d',320,200,solid=True)
            scene('private',800,600)
            q.set('scene','delayed'); q.set('closed',True)
            final=q.get(); assert final['backend']['closed'] and final['backend']['active_leases']==0
            for key,value in {'submitted':11,'completed':7,'cancelled':4,
                'timed_out':1,'superseded':1,'invalidated':1,'shutdown_cancelled':1,
                'max_pending_leases':1,'peak_readback_bytes':1920*1080*8}.items():
                assert final['backend'][key]==value, (key,final['backend'])
            assert (final['done'],final['abandoned'],final['native_cleanups'])==(7,4,12), final
            assert 'error' in q.set('scene','private',allow_error=True)
            q.call('quit'); assert process.wait(timeout=5)==0
            report={'result':'pass','records':records,'final_state':final,
                'exact_pixels':sum(r['exact_pixels'] for r in records),
                'negative_checks':['missing_fence','invalid_crop','pending_no_early_read',
                    'stalled_fence_timeout','superseded_read_lease','2d_fallback','shutdown_lease_cancel'],
                'guest_cpu':False,'guest_disks':False,'tcp':False}
            (BASE/('provenance/'+label+'-tests.json')).write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(report))
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('--label',default='headless')
    args=parser.parse_args()
    run(args.binary,args.label)
