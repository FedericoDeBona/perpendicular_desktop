#!/usr/bin/env python3
"""Actual QEMU PCI virtqueue -> proxy -> server worker -> Neptune -> VNC.

Only a stopped, diskless 128 MiB machine is created. Every COM object is made
by its normal Neptune wire decoder; no native fixture/bootstrap entry point.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'.tools/graphics-experiment'
BUILD=BASE/'build/neptune-live'
SPEC=importlib.util.spec_from_file_location('headless',ROOT/'experimental/metal-headless/test-headless.py')
headless=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(headless)
DEFS=(BASE/'src/virglrenderer/src/neptune/neptune-protocol/npt_protocol_defs.h').read_text()


def pack(fmt,*values):return struct.pack('<'+fmt,*values)


def constant(name):
    value=re.search(r'^#define '+re.escape(name)+r'\s+(?:\(\(uint16_t\))?([0-9]+)',DEFS,re.M)
    assert value,name
    return int(value[1])


def iid(name):
    block=re.search(r'static const GUID NPT_IID_'+name+r' = \{(.*?)\};',DEFS,re.S)[1]
    values=[int(v,16) for v in re.findall(r'0x([0-9a-fA-F]+)',block)]
    assert len(values)==11
    return pack('IHH8B',*values)


def method(interface,name):
    return 0xff000000 | constant('NPT_IFACE_ID_'+interface)<<8 | constant('NPT_METHOD_'+interface+'_'+name)


def command(kind,object_id=0,body=b'',reply=False):
    return pack('IIQII',kind,int(reply),object_id,24+len(body),0)+body


class QTest:
    def __init__(self,sock):self.sock=sock;self.stream=sock.makefile('rb')
    def call(self,text):
        self.sock.sendall(text.encode()+b'\n')
        while True:
            line=self.stream.readline(4*1024*1024).decode().strip()
            assert line,'qtest EOF'
            if line.startswith('IRQ '):continue
            assert line=='OK' or line.startswith('OK '),(text,line)
            return line[3:]
    def read(self,address,size):
        if size>1024*1024:
            return b''.join(self.read(address+i,min(1024*1024,size-i)) for i in range(0,size,1024*1024))
        value=self.call(f'read {address:#x} {size:#x}')
        data=bytes.fromhex(value.removeprefix('0x'));assert len(data)==size
        return data
    def write(self,address,data):self.call(f'write {address:#x} {len(data):#x} 0x'+data.hex())
    def load(self,address,size=4):return int(self.call(f'read'+{1:'b',2:'w',4:'l',8:'q'}[size]+f' {address:#x}'),0)
    def store(self,address,value,size=4):self.call(f'write'+{1:'b',2:'w',4:'l',8:'q'}[size]+f' {address:#x} {value:#x}')


class GPU:
    def __init__(self,t):
        self.t=t;self.config=0x3f000000+(1<<15);self.sequence=0;self.bar={}
        assert t.load(self.config,2)==0x1af4,'Actual PCI GPU not found'
        # Deliberately assign only this isolated device's BARs. No firmware,
        # platform PCI enumeration or guest CPU is involved.
        for index,address in ((0,0x10000000),(1,0x11000000),(2,0x12000000),(4,0x20000000)):
            offset=self.config+0x10+index*4;original=t.load(offset)
            t.store(offset,0xffffffff);mask=t.load(offset);t.store(offset,original)
            if not mask:continue
            assert not mask&1,'Unexpected I/O BAR'
            t.store(offset,address|(original&15));self.bar[index]=address
            if original&6==4:t.store(offset+4,0)
        t.store(self.config+4,6,2)
        caps={};offset=t.load(self.config+0x34,1);visited=set()
        while offset:
            assert offset not in visited and len(visited)<48;visited.add(offset)
            if t.load(self.config+offset,1)==9:
                kind=t.load(self.config+offset+3,1);bar=t.load(self.config+offset+4,1)
                if kind in (1,2):
                    caps[kind]=self.bar[bar]+t.load(self.config+offset+8)
                    if kind==2:self.multiplier=t.load(self.config+offset+16)
            offset=t.load(self.config+offset+1,1)
        self.common=caps[1];self.notify=caps[2];c=self.common
        t.store(c+20,0,1);t.store(c+20,3,1)
        features=[]
        for page in range(2):t.store(c,page);features.append(t.load(c+4))
        assert features[0]&0x19==0x19 and features[1]&1,(features,'Required GPU features absent')
        for page,value in ((0,features[0]&0x1f),(1,1)):
            t.store(c+8,page);t.store(c+12,value)
        t.store(c+20,11,1);assert t.load(c+20,1)&8
        t.store(c+22,0,2);assert t.load(c+24,2)>=8
        t.store(c+24,8,2)
        self.desc=0x40010000;self.avail=0x40011000;self.used=0x40012000
        self.request=0x40020000;self.response=0x40030000
        t.write(self.desc,b'\0'*128);t.write(self.avail,b'\0'*32);t.write(self.used,b'\0'*128)
        for offset,address in ((32,self.desc),(40,self.avail),(48,self.used)):t.store(c+offset,address,8)
        self.notification=self.notify+t.load(c+30,2)*self.multiplier
        t.store(c+28,1,2);t.store(c+20,15,1)

    def send(self,kind,body=b'',context=1):
        packet=pack('IIQIB3x',kind,0,0,context,0)+body
        assert len(packet)<65536
        t=self.t;t.write(self.request,packet);t.write(self.response,b'\0'*512)
        t.write(self.desc,pack('QIHH',self.request,len(packet),1,1)+pack('QIHH',self.response,512,2,0))
        t.store(self.avail+4+(self.sequence%8)*2,0,2);self.sequence+=1;t.store(self.avail+2,self.sequence,2)
        t.store(self.notification,0,2)
        deadline=time.monotonic()+10
        while t.load(self.used+2,2)!=self.sequence:
            assert time.monotonic()<deadline,('Actual virtqueue completion timeout',hex(kind))
            time.sleep(.005)
        data=t.read(self.response,512);result=struct.unpack_from('<I',data)[0]
        assert 0x1100<=result<0x1200,('Actual virtio command rejected',hex(kind),hex(result))
        return data

    def submit(self,data):self.send(0x207,pack('II',len(data),0)+data)
    def create_blob(self,resource,blob,size):self.send(0x10c,pack('IIIIQQ',resource,2,3,0,blob,size))
    def map_blob(self,resource,offset):self.send(0x208,pack('IIQ',resource,0,offset));return self.bar[4]+offset
    def scanout(self,resource,width,height):
        self.send(0x10d,pack('10I',0,0,width,height,0,resource,width,height,1,0)+pack('8I',width*4,0,0,0,0,0,0,0))
    def flush(self,resource,width,height):self.send(0x104,pack('6I',0,0,width,height,resource,0))


class Neptune:
    def __init__(self,gpu):
        self.gpu=gpu;self.t=gpu.t
        gpu.send(0x200,pack('II',9,7)+b'live-wire'+b'\0'*55)
        gpu.create_blob(9,0,16384);self.memory=gpu.map_blob(9,0)
        gpu.create_blob(10,0,131072);self.ring=gpu.map_blob(10,0x3000000);self.tail=0;self.vq_sequence=0
        body=pack('Q8IQ4I',1,10,0,4,8,4096,65536,128,128,1000000,0,0,0,0)
        gpu.submit(command(0x10000,body=body))
    def drained(self):
        deadline=time.monotonic()+10
        while self.t.load(self.ring)!=self.tail:
            assert not self.t.load(self.ring+8)&2,'Actual Neptune ring fatal'
            assert time.monotonic()<deadline,'Actual Neptune ring did not drain'
            time.sleep(.002)
    def emit(self,data):
        assert 0<len(data)<65536
        head=self.t.load(self.ring);assert self.tail-head+len(data)<=65536
        offset=self.tail&65535;first=min(len(data),65536-offset)
        self.t.write(self.ring+4096+offset,data[:first])
        if first<len(data):self.t.write(self.ring+4096,data[first:])
        self.tail+=len(data);self.t.store(self.ring+4,self.tail)
        self.gpu.submit(command(0x10002,body=pack('Q',1)))
    def call(self,kind,object_id=0,body=b''):
        self.drained()
        self.t.write(self.memory,b'\0'*256)
        # This is the pinned transport's real context -> ring ordering edge.
        # Do not assume SUBMIT_3D completion means worker dispatch completed.
        self.vq_sequence+=1;edge=pack('QII',1,self.vq_sequence,0)
        self.gpu.submit(command(0x10005,body=edge))
        self.emit(command(0x10006,body=edge)+command(0,body=pack('4I',9,0,4096,0))+
            command(kind,object_id,body,True))
        deadline=time.monotonic()+10
        while True:
            reply=self.t.read(self.memory,32);cmd,result=struct.unpack_from('<II',reply)
            if cmd:
                # Reply header precedes its payload in the encoder. The
                # ring head's completion is required before reading values.
                self.drained();reply=self.t.read(self.memory,32);cmd,result=struct.unpack_from('<II',reply)
                assert cmd==kind and result==0,('Actual Neptune reply',hex(kind),hex(cmd),hex(result))
                return reply
            assert time.monotonic()<deadline,('Actual Neptune reply timeout',hex(kind))
            time.sleep(.005)
    def query(self,object_id,interface,guest_id):
        reply=self.call(0x20001,object_id,iid(interface)+pack('Q',guest_id))
        actual=struct.unpack_from('<Q',reply,8)[0];assert actual
        return actual
    def create(self,width=800,height=600):
        self.call(0x02000000,body=pack('QIQIQIIQQ',0,1,0,0x20,0,0,7,10,11))
        device5=self.query(10,'ID3D11Device5',12);self.writer=self.query(11,'ID3D11DeviceContext4',1)
        self.call(method('ID3D11Device5','CreateFence'),device5,pack('QIQ',0,0,1)+iid('ID3D11Fence')+pack('Q',2))
        self.originals=[]
        for index in range(2):
            texture=20+index;view=30+index;blob=100+index;resource=200+index
            description=pack('11I',width,height,1,1,87,1,0,0,0x28,0,0x2|0x40000000)
            self.call(method('ID3D11Device','CreateTexture2D'),10,pack('Q',1)+description+pack('QQ',0,texture))
            self.call(method('ID3D11Device','CreateRenderTargetView'),10,pack('QQQ',texture,0,view))
            self.call(0x40000,texture,pack('QII',blob,9,8192))
            metadata=self.t.read(self.memory+8192,88)
            allocation=struct.unpack_from('<Q',metadata,8)[0];assert 0<allocation<=64*1024*1024
            self.gpu.create_blob(resource,blob,allocation)
            address=self.gpu.map_blob(resource,0x1000000*(index+1))
            offset,pitch=struct.unpack_from('<QQ',metadata,24)
            assert pitch>=width*4 and offset+(height-1)*pitch+width*4<=allocation
            self.originals.append((address+offset,pitch))
        return width,height
    def clear(self,index,rgba,width,height,rect=None):
        body=pack('QQ4fQ4iI',30+index,4,*rgba,1,*(rect or (0,0,width,height)),1)
        self.emit(command(method('ID3D11DeviceContext1','ClearView'),self.writer,body))
    def pattern(self,index,width,height,inverted):
        colors=[(1,0,0,1),(0,1,0,1),(0,0,1,1),(1,1,1,1)]
        if inverted:colors=[colors[3],colors[2],colors[1],colors[0]]
        rects=[(0,0,width//2,height//2),(width//2,0,width,height//2),
            (0,height//2,width//2,height),(width//2,height//2,width,height)]
        for color,rect in zip(colors,rects):self.clear(index,color,width,height,rect)
        for rect in [(width//2,0,width//2+1,height),(0,height//2,width,height//2+1)]:
            self.clear(index,(17/255,136/255,204/255,1),width,height,rect)
    def overwrite(self,width,height):
        for index in range(2):self.clear(index,(1,0,1,1),width,height)
        self.emit(command(method('ID3D11DeviceContext','Flush'),self.writer));self.drained()
        expected=bytes((255,0,255,255))*width;deadline=time.monotonic()+10
        for address,pitch in self.originals:
            while True:
                data=self.t.read(address,pitch*height)
                if all(data[y*pitch:y*pitch+width*4]==expected for y in range(height)):break
                assert time.monotonic()<deadline,'Original texture GPU overwrite did not complete'
                time.sleep(.005)
    def signal(self,value):
        self.emit(command(method('ID3D11DeviceContext4','Signal'),self.writer,pack('QQ',2,value)))
        self.emit(command(method('ID3D11DeviceContext','Flush'),self.writer));self.drained()


def run(mode='baseline',library_dir=None):
    library_dir=library_dir or BUILD/'lib'
    assert library_dir.resolve().is_relative_to(BUILD.resolve())
    env=os.environ.copy();env['DYLD_LIBRARY_PATH']=str(library_dir)+':'+str(BASE/'prefix/lib')+':'+str(BASE/'prefix/ANGLE.xcarchive/Products/usr/local/lib')
    env['DYLD_FALLBACK_LIBRARY_PATH']=env['DYLD_LIBRARY_PATH'];env['RENDER_SERVER_EXEC_PATH']=str(BUILD/'virgl_render_server')
    env.update(PERP_NEPTUNE_SCANOUT_BROKER='1',NPT_BACKEND='dxmt',ANGLE_DEFAULT_PLATFORM='metal',DXMT_LOG_PATH=str(BASE/'logs'))
    env.pop('PERP_LIVE_TEST_WITHHOLD',None)
    if mode=='withheld':env['PERP_LIVE_TEST_WITHHOLD']='1'
    label='neptune-live-'+mode+('-'+library_dir.parent.name if library_dir!=BUILD/'lib' else '')
    with tempfile.TemporaryDirectory(prefix='perp-live-',dir='/tmp') as tmp,(BASE/('logs/'+label+'.log')).open('w') as log:
        runtime=Path(tmp)
        argv=[str(BUILD/'qemu-system-aarch64-neptune-live'),'-L',str(BASE/'prefix/share/qemu'),'-no-user-config','-nodefaults',
            '-machine','virt,highmem=off','-accel','tcg','-m','128M','-S','-display','egl-headless',
            '-device','virtio-gpu-gl-pci,id=pixels,addr=1,disable-legacy=on,neptune=on,blob=on,hostmem=128M',
            '-qtest','unix:'+str(runtime/'qtest.sock')+',server=on,wait=off','-qtest-log','/dev/null',
            '-qmp','unix:'+str(runtime/'qmp.sock')+',server=on,wait=off','-vnc','unix:'+str(runtime/'vnc.sock'),'-monitor','none','-serial','none']
        process=subprocess.Popen(argv,env=env,stdout=log,stderr=subprocess.STDOUT)
        try:
            q=headless.QMP(headless.connect(runtime/'qmp.sock',process));assert q.call('query-block')==[]
            assert q.call('query-status')['status']=='prelaunch'
            t=QTest(headless.connect(runtime/'qtest.sock',process));g=GPU(t);n=Neptune(g)
            dimensions=n.create();print(json.dumps({'stage':'actual_wire_device_two_textures_fence','dimensions':dimensions}),flush=True)
            path='/machine/peripheral/pixels/virtio-backend'
            def stats():return json.loads(q.call('qom-get',{'path':path,'property':'perp-live-stats'}))
            def hold(value):q.call('qom-set',{'path':path,'property':'perp-live-hold-read','value':value})
            def option(name,value):q.call('qom-set',{'path':path,'property':'perp-live-'+name,'value':value})
            def await_stats(predicate):
                deadline=time.monotonic()+10
                while True:
                    state=stats()
                    if predicate(state):return state
                    assert not state['renderer']['closed'] and not state['renderer']['rejected'],state
                    assert time.monotonic()<deadline,('Live callback timeout',state)
                    time.sleep(.005)
            hold(True);width,height=dimensions;g.scanout(200,width,height)
            await_stats(lambda s:s['renderer']['active_context']==1)
            v=headless.VNC(headless.connect(runtime/'vnc.sock',process));records=[]
            if mode=='late-completion':
                option('delay-done',True);option('hold-adapter',True)
                for candidate in range(2):n.pattern(candidate,width,height,bool(candidate))
                n.signal(1);g.scanout(201,width,height);g.flush(201,width,height);hold(False)
                old=await_stats(lambda s:s['console_active'] and s['adapter']['active_leases']==1)
                assert old['reads']==0 and old['delayed_done']==0,old
                t.store(g.common+20,0,1)
                cancelled=await_stats(lambda s:s['delayed_done']==1 and not s['console_active'])
                assert cancelled['reads']==0 and cancelled['adapter']['active_leases']==0,cancelled
                g=GPU(t);g.send(0x100,context=0);n=Neptune(g);assert n.create()==dimensions
                hold(True);g.scanout(201,width,height);await_stats(lambda s:s['renderer']['active_context']==1)
                assert stats()['configuration_generation']>old['configuration_generation'],'Configuration generation reused after reset'
                for candidate in range(2):n.pattern(candidate,width,height,bool(candidate))
                n.signal(1);g.flush(201,width,height);hold(False)
                new=await_stats(lambda s:s['console_active'] and s['adapter']['active_leases']==1)
                assert new['delayed_done']==1 and new['reads']==0,new
                option('delay-done',False)
                after=stats()
                assert after['delayed_done']==0 and after['console_active'] and after['adapter']['active_leases']==1,('Stale completion cleared the new console lease',after)
                option('hold-adapter',False)
                final=await_stats(lambda s:s['reads']==1 and s['renderer']['pending']==0 and not s['console_active'])
                w,h,pixels=v.snapshot();assert (w,h)==dimensions
                expected=bytearray(headless.expected(w,h));colors={bytes((0,0,255,0)):bytes((255,255,255,0)),bytes((255,255,255,0)):bytes((0,0,255,0)),
                    bytes((0,255,0,0)):bytes((255,0,0,0)),bytes((255,0,0,0)):bytes((0,255,0,0))}
                for offset in range(0,len(expected),4):expected[offset:offset+4]=colors.get(bytes(expected[offset:offset+4]),expected[offset:offset+4])
                assert pixels==expected,'New epoch pixels differ after stale completion'
                g.scanout(0,width,height);final=await_stats(lambda s:s['renderer']['active_context']==0)
                assert final['native_released']==2 and final['mappings_released']==2 and final['cancelled']==1,final
                report={'result':'pass','mode':mode,'old_generation':old['configuration_generation'],'new_generation':new['configuration_generation'],
                    'late_old_continuation_preserved_new_lease':True,'exact_pixels':w*h,'final':final,'guest_cpu_executed':False,'guest_disks':False}
                (BASE/('provenance/'+label+'.json')).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report),flush=True)
                q.call('quit');assert process.wait(timeout=10)==0;return report
            if mode=='withheld':
                for candidate in range(2):n.pattern(candidate,width,height,bool(candidate))
                n.signal(1);g.scanout(201,width,height);g.flush(201,width,height)
                await_stats(lambda s:s['renderer']['received']==2)
                n.overwrite(width,height)
                value=n.call(method('ID3D11Fence','GetCompletedValue'),2)
                assert struct.unpack_from('<Q',value,8)[0]>=1,'Actual GPU fence did not finish'
                hold(False);deadline=time.monotonic()+5
                while not stats()['renderer']['closed']:
                    assert stats()['reads']==0,'Unready producer token was published'
                    assert time.monotonic()<deadline,'Withheld-token timeout guard did not close'
                    time.sleep(.01)
                state=stats()
                assert state['reads']==0 and state['renderer']['pending']==0 and state['adapter']['submitted']==0,state
                assert state['adapter']['peak_readback_bytes']==0,state
                g.scanout(0,width,height)
                report={'result':'pass','mode':mode,'gpu_fence_completed':True,'originals_overwritten_pixels':2*width*height,
                    'consumer_token_ready':False,'final':stats(),'guest_cpu_executed':False,'guest_disks':False}
                (BASE/('provenance/'+label+'.json')).write_text(json.dumps(report,indent=2)+'\n')
                print(json.dumps(report),flush=True)
                q.call('quit');assert process.wait(timeout=10)==0
                return report
            if mode=='reset-pending':
                for candidate in range(2):n.pattern(candidate,width,height,bool(candidate))
                n.signal(1);g.scanout(201,width,height);g.flush(201,width,height)
                await_stats(lambda s:s['renderer']['received']==2)
                n.overwrite(width,height)
                t.store(g.common+20,0,1)
                reset=await_stats(lambda s:s['renderer']['pending']==0 and s['renderer']['selected']==0)
                assert reset['reads']==0 and reset['adapter']['active_leases']==0,reset
                # QEMU deliberately defers virgl_renderer_reset until the
                # next command, after its GL/BQL context is available again.
                g=GPU(t);g.send(0x100,context=0)
                assert stats()['renderer']['active_context']==0,stats()
                n=Neptune(g);assert n.create()==dimensions
                hold(True);g.scanout(200,width,height);await_stats(lambda s:s['renderer']['active_context']==1)
            for sequence,index in enumerate([1,0,1,0],1):
                hold(True)
                for candidate in range(2):n.pattern(candidate,width,height,bool(candidate))
                n.signal(sequence)
                # The actual producer Signal has already been decoded. The
                # actual guest SET_SCANOUT now chooses a different backbuffer.
                g.scanout(200+index,width,height);g.flush(200+index,width,height)
                await_stats(lambda s:s['renderer']['received']>=sequence*2+(2 if mode=='reset-pending' else 0))
                n.overwrite(width,height)
                before=stats();assert before['reads']==sequence-1,before
                hold(False)
                state=await_stats(lambda s:s['reads']>=sequence)
                assert state['reads']==sequence,'Unexpected extra resource snapshot publication'
                w,h,pixels=v.snapshot();assert (w,h)==(width,height)
                expected=bytearray(headless.expected(width,height))
                if index:
                    colors={bytes((0,0,255,0)):bytes((255,255,255,0)),bytes((255,255,255,0)):bytes((0,0,255,0)),
                        bytes((0,255,0,0)):bytes((255,0,0,0)),bytes((255,0,0,0)):bytes((0,255,0,0))}
                    for offset in range(0,len(expected),4):expected[offset:offset+4]=colors.get(bytes(expected[offset:offset+4]),expected[offset:offset+4])
                assert pixels==expected,('Actual guest-resource/VNC pixels differ',sequence,index,pixels[:32].hex())
                state=await_stats(lambda s:s['renderer']['pending']==0 or s['reads']>sequence)
                if state['reads']>sequence:
                    w,h,pixels=v.snapshot()
                    assert pixels==expected,('Actual guest-resource/VNC pixels differ',sequence,index,'extra publication')
                    raise AssertionError('Unexpected extra resource snapshot publication')
                records.append({'frame':sequence,'resource':200+index,'exact_pixels':w*h,'originals_overwritten_pixels':2*w*h})
                print(json.dumps({'stage':'actual_vnc_frame',**records[-1],'state':state}),flush=True)
            if mode=='reused-fence':
                hold(True);n.signal(4);deadline=time.monotonic()+5
                while not stats()['renderer']['closed']:
                    assert time.monotonic()<deadline,'Reused producer-fence value was not rejected'
                    time.sleep(.01)
                state=stats();assert state['reads']==4 and state['renderer']['received']==8,state
            g.scanout(0,width,height)
            final=stats() if mode=='reused-fence' else await_stats(lambda s:s['renderer']['active_context']==0)
            assert final['adapter']['active_leases']==0,final
            report={'result':'pass','mode':mode,'records':records,'final':final,'guest_cpu_executed':False,'guest_disks':False,
                'native_fixture_bootstrap':False,'wire_format_version':constant('NPT_PROTOCOL_WIRE_VERSION'),
                'exact_pixels':sum(x['exact_pixels'] for x in records),'full_source_overwrite_pixels':sum(x['originals_overwritten_pixels'] for x in records)}
            (BASE/('provenance/'+label+'.json')).write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(report),flush=True)
            q.call('quit');assert process.wait(timeout=10)==0
        finally:
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=['baseline','withheld','reused-fence','reset-pending','late-completion'],default='baseline')
    parser.add_argument('--library-dir',type=Path)
    args=parser.parse_args();run(args.mode,args.library_dir)
