#!/usr/bin/env python3
"""Real renderer workers, asynchronous rings, native GPU, restart and VNC."""
import array
import ctypes
from dataclasses import replace
import importlib.util
import json
import mmap
import os
from pathlib import Path
import secrets
import select
import socket
import struct
import subprocess
import tempfile
import time

from broker import *

ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'.tools/graphics-experiment'
BUILD=BASE/'build/neptune-broker'
ENV=os.environ.copy()
ENV.update(DYLD_FALLBACK_LIBRARY_PATH=str(BASE/'prefix/lib')+':'+str(BASE/'prefix/ANGLE.xcarchive/Products/usr/local/lib'),
    NPT_BACKEND='dxmt',ANGLE_DEFAULT_PLATFORM='metal',DXMT_LOG_PATH=str(BASE/'logs'))
LABEL=os.environ.get('PERP_BROKER_TEST_LABEL','broker')
assert LABEL.replace('-','').isalnum()
SPEC=importlib.util.spec_from_file_location('pipeline',ROOT/'experimental/neptune-snapshot/test-pipeline.py')
pipeline=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(pipeline)
fixture=pipeline.fixture
SCHEMA=json.loads(subprocess.run([str(BUILD/'worker'),'--schema'],env=ENV,capture_output=True,text=True,check=True).stdout)
ATOMIC=ctypes.CDLL(str(BUILD/'ring-atomic.dylib'))
ATOMIC.perp_ring_publish.argtypes=[ctypes.c_void_p,ctypes.c_uint32]
ATOMIC.perp_ring_load.argtypes=[ctypes.c_void_p];ATOMIC.perp_ring_load.restype=ctypes.c_uint32


def exact(channel,size):
    out=bytearray()
    while len(out)<size:
        data=channel.recv(size-len(out))
        if not data:raise EOFError('Truncated stream')
        out.extend(data)
    return bytes(out)


def command(kind,object_id,body=b''):
    return struct.pack('<IIQII',kind,0,object_id,24+len(body),0)+body


def control_send(channel,data,fds=(),fragment=False):
    packet=struct.pack('>I',len(data))+data
    rights=[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',fds))] if fds else []
    # Also cover real Darwin frame-header fragmentation, with transferred
    # rights attached only to the first fragment.
    first=packet[:2] if fragment else packet
    sent=channel.sendmsg([first],rights)
    if sent<len(packet):channel.sendall(packet[sent:])


def control_receive(channel):
    data,ancillary,flags,_=channel.recvmsg(4,socket.CMSG_SPACE(2*array.array('i').itemsize))
    fds=[]
    for level,kind,raw in ancillary:
        assert (level,kind)==(socket.SOL_SOCKET,socket.SCM_RIGHTS)
        values=array.array('i');values.frombytes(raw);fds.extend(values)
    try:
        assert not flags&socket.MSG_CTRUNC
        data+=exact(channel,4-len(data));size=struct.unpack('>I',data)[0]
        assert 0<size<=256
        return exact(channel,size),fds
    except BaseException:close_rights(fds);raise


class Worker:
    def __init__(self,broker,epoch,context=1,width=800,height=600,delay=0,withheld=False):
        self.broker=broker;self.epoch=epoch;self.context=context;self.width=width;self.height=height
        self.records=[];self.mappings=[];self.tail=0;self.value=0;self.closed=False
        self.control,child=socket.socketpair();self.channel,other=socket.socketpair()
        self.control.settimeout(8);self.channel.settimeout(8)
        self.log=(BASE/f'logs/{LABEL}-worker-{epoch}.log').open('w')
        env=ENV.copy()
        if delay:env['PERP_BROKER_EXPORT_DELAY_US']=str(delay)
        if withheld:env['PERP_SNAPSHOT_WITHHOLD']='1'
        self.process=subprocess.Popen([str(BUILD/'worker'),str(child.fileno()),str(other.fileno()),str(broker.session),str(epoch),
            str(context),str(width),str(height),'host-fixture-only'],env=env,pass_fds=(child.fileno(),other.fileno()),stdout=self.log,stderr=subprocess.STDOUT)
        child.close();other.close();broker.add(self)
        self.timelines=tempfile.TemporaryFile();self.timelines.truncate(256)
        control_send(self.control,struct.pack('<IIQ',1,7,256),(self.timelines.fileno(),),True)
        self.await_kind(HELLO)
        for resource,size in ((9,16384),(10,131072)):
            fd=self.create(resource,0,size);assert fd is not None
            mapping=mmap.mmap(fd,size);os.close(fd);self.mappings.append(mapping)
        self.ring=self.mappings[1]
        self.address=ctypes.addressof(ctypes.c_char.from_buffer(self.ring))
        body=struct.pack('<Q8IQ4I',1,10,0,4,8,4096,65536,128,128,1000000,0,0,0,0)
        packet=command(SCHEMA['ring_create'],0,body);assert len(packet)==SCHEMA['create_ring_size']
        self.submit(packet)

    def command(self,message):control_send(self.control,message.pack())

    def observe(self):
        message=receive(self.channel,self.broker.session,self.epoch,self.context)
        self.records.append(message.kind);return self.broker.observe(self,message)

    def await_kind(self,kind):
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            message=self.observe()
            if message.kind==kind:return message
        raise TimeoutError('Worker operation '+str(kind))

    def create(self,resource,blob,size=0):
        control_send(self.control,struct.pack('<IIQQI4x',2,resource,blob,size,0))
        reply,fds=control_receive(self.control)
        assert len(fds)<=1
        return fds[0] if fds else None

    def submit(self,packet):
        assert len(packet)<=256
        control_send(self.control,struct.pack('<II',5,len(packet))+packet.ljust(256,b'\0'))

    def import_resource(self,resource,fd):
        size=os.fstat(fd).st_size;assert 0<size<=64*1024*1024
        control_send(self.control,struct.pack('<III4xQ',3,resource,2,size),(fd,))
        result=self.await_kind(IMPORT_RESULT)
        assert result.status==1,'Actual cross-worker import failed'
        assert self.stats()['contexts']==1 and self.process.poll() is None,'Import worker did not remain live'

    def write_ring(self,packet):
        assert len(packet)<65536
        assert self.tail-ATOMIC.perp_ring_load(self.address)+len(packet)<=65536,'Fixture ring capacity'
        index=self.tail&65535;first=min(len(packet),65536-index)
        self.ring[4096+index:4096+index+first]=packet[:first]
        if first<len(packet):self.ring[4096:4096+len(packet)-first]=packet[first:]
        self.tail+=len(packet);ATOMIC.perp_ring_publish(self.address+4,self.tail)
        self.submit(command(SCHEMA['ring_notify'],0,struct.pack('<Q',1)))

    def drained(self):
        deadline=time.monotonic()+8
        while ATOMIC.perp_ring_load(self.address)!=self.tail:
            assert self.process.poll() is None,'Actual renderer worker exited'
            if time.monotonic()>deadline:raise TimeoutError('Actual ring head did not drain')
            time.sleep(.002)

    def export(self,blob=100):
        self.write_ring(command(SCHEMA['export'],4,struct.pack('<QII',blob,9,0)))

    def claim(self,resource=77,blob=100):return self.create(resource,blob)

    def signal(self):
        self.value+=10
        self.write_ring(command(SCHEMA['signal'],1,struct.pack('<QQ',2,self.value)))

    def clear(self,color,rect):
        body=struct.pack('<QQ4fQ4iI',3,4,*color,1,*rect,1)
        self.write_ring(command(SCHEMA['clear'],1,body))

    def draw(self,inverted=False):
        colors=((1,0,0,1),(0,1,0,1),(0,0,1,1),(1,1,1,1))
        for q in range(4):
            rect=(self.width//2 if q%2 else 0,self.height//2 if q//2 else 0,
                self.width if q%2 else self.width//2,self.height if q//2 else self.height//2)
            self.clear(colors[3-q if inverted else q],rect)
        cross=(17/255,136/255,204/255,1)
        self.clear(cross,(self.width//2,0,self.width//2+1,self.height))
        self.clear(cross,(0,self.height//2,self.width,self.height//2+1))
        self.signal();self.signal() # Busy lease is never rewritten.
        self.clear((1,0,1,1),(0,0,self.width,self.height));self.drained()
        self.command(Message(VERIFY,self.broker.session,self.epoch,self.context))
        self.await_kind(VERIFIED)
        assert self.epoch in self.broker.pending,'No actual Signal snapshot'

    def stats(self):
        self.command(Message(STATUS,self.broker.session,self.epoch,self.context));self.await_kind(STATS)
        self.log.flush()
        rows=[json.loads(line) for line in (BASE/f'logs/{LABEL}-worker-{self.epoch}.log').read_text().splitlines() if line.startswith('{')]
        return rows[-1]['registry']

    def close(self,kill=False):
        if self.closed:return
        self.closed=True
        if kill:self.process.kill()
        self.control.close()
        try:self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:self.process.kill();self.process.wait();raise
        self.broker.died(self);self.channel.close();self.log.close();self.timelines.close()
        for mapping in self.mappings:mapping.close()


def setup_export(worker,control_first=False):
    if control_first:
        # Actual control arrives before any ring export: no fabricated binding.
        assert worker.claim() is None
        try:worker.broker.bind(worker,77)
        except ValueError:pass
        else:raise AssertionError('Missing ring export admitted')
    worker.export()
    if control_first:
        # The test worker delays its export notification after publishing the
        # real pending blob. Retry only the real failed get_blob operation.
        deadline=time.monotonic()+4
        while True:
            fd=worker.claim()
            if fd is not None:break
            assert time.monotonic()<deadline;time.sleep(.002)
    else:
        worker.await_kind(EXPORT);fd=worker.claim();assert fd is not None
    while not worker.broker.workers[worker.epoch]['claims'].get(77):worker.observe()
    if control_first:assert EXPORT not in worker.records,'Control/export reorder not induced'
    while 100 not in worker.broker.workers[worker.epoch]['exports']:worker.observe()
    worker.drained()
    worker.signal();worker.drained()
    # This Signal precedes admission and must not create a frame.
    assert worker.stats()['captures']==0
    binding=worker.broker.bind(worker,77)
    return fd,binding


def parser_checks():
    session,epoch,context=11,22,3
    message=Message(HELLO,session,epoch,context).pack()
    left,right=socket.socketpair();right.sendall(message[:3]);right.sendall(message[3:17]);right.sendall(message[17:])
    assert receive(left,session,epoch,context).kind==HELLO;left.close();right.close()
    checks=[]
    variants={'wrong_version':replace(Message(HELLO,session,epoch,context)).pack()[:4]+struct.pack('<H',2)+message[6:],
        'stale_epoch':Message(HELLO,session,epoch-1,context).pack(),
        'oversized':message[:8]+struct.pack('<I',249)+message[12:],
        'truncated':message[:20], 'unexpected_body':Message(HELLO,session,epoch,context,body=b'x').pack()}
    for name,packet in variants.items():
        left,right=socket.socketpair();right.sendall(packet);right.shutdown(socket.SHUT_WR)
        try:receive(left,session,epoch,context)
        except (ValueError,EOFError):checks.append(name)
        else:raise AssertionError('Malformed parser input accepted: '+name)
        finally:left.close();right.close()
    for count in (1,3):
        left,right=socket.socketpair()
        with tempfile.TemporaryFile() as file:
            before=len(os.listdir('/dev/fd'))
            right.sendmsg([message],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',[file.fileno()]*count))])
            try:receive(left,session,epoch,context)
            except ValueError:pass
            else:raise AssertionError('Unexpected rights accepted')
            assert len(os.listdir('/dev/fd'))==before,'Rejected rights leaked'
        left.close();right.close();checks.append('unexpected_rights_closed_'+str(count))
    return checks


def worker_early_eof(session):
    control,child=socket.socketpair();channel,other=socket.socketpair()
    try:
        with (BASE/f'logs/{LABEL}-worker-early-eof.log').open('w') as log:
            process=subprocess.Popen([str(BUILD/'worker'),str(child.fileno()),str(other.fileno()),str(session),'43','1','800','600',
                'host-fixture-only'],env=ENV,pass_fds=(child.fileno(),other.fileno()),stdout=log,stderr=subprocess.STDOUT)
            child.close();other.close();control.close()
            try:assert process.wait(timeout=8)==0,'Worker EOF before INIT was not clean'
            finally:
                if process.poll() is None:process.kill();process.wait()
    finally:control.close();child.close();channel.close();other.close()


def run():
    broker=Broker(secrets.randbits(63) or 1);workers=[];records=[];checks=parser_checks()
    consumer,child=socket.socketpair();consumer.settimeout(8)
    with tempfile.TemporaryDirectory(prefix='perp-broker-',dir='/tmp') as temporary, (BASE/f'logs/{LABEL}-qemu.log').open('w') as qlog:
        runtime=Path(temporary);qemu=None
        try:
            binary=BASE/'build/neptune-snapshot/qemu-system-aarch64-neptune-snapshot'
            qemu=subprocess.Popen([str(binary),'-L',str(BASE/'prefix/share/qemu'),'-no-user-config','-nodefaults','-machine','none','-m','16M','-S',
                '-display','egl-headless','-device','perp-neptune-test,id=pixels,channel='+str(child.fileno()),'-vnc','unix:'+str(runtime/'vnc.sock'),
                '-qmp','unix:'+str(runtime/'qmp.sock')+',server=on,wait=off','-monitor','none','-serial','none'],env=ENV,
                pass_fds=(child.fileno(),),stdout=qlog,stderr=subprocess.STDOUT)
            child.close();q=fixture.QMP(fixture.connect(runtime/'qmp.sock',qemu));v=fixture.VNC(fixture.connect(runtime/'vnc.sock',qemu))
            assert q.call('query-cpus-fast')==[] and q.call('query-block')==[]
            previous_ack=None
            for index,(width,height) in enumerate(((800,600),(803,607),(1280,720)),1):
                epoch=(1,2,21)[index-1]
                w=Worker(broker,epoch,width=width,height=height,delay=200000 if index==1 else 0);workers.append(w)
                resource_fd,binding=setup_export(w,index==1)
                w.draw(index%2==0)
                if index==3:
                    control_send(w.control,struct.pack('<II',4,77));w.await_kind(DESTROY)
                    checks.append('real_destroy_while_snapshot_pending')
                deadline=time.monotonic()+5
                while True:
                    try:packet,fds,scanout=broker.consumer_packet(w);break
                    except BlockingIOError:
                        assert time.monotonic()<deadline;time.sleep(.002)
                if previous_ack:
                    try:broker.ack(w,previous_ack,0)
                    except ValueError:
                        assert w.epoch in broker.pending,'Stale ACK released the current lease'
                        assert w.stats()['active']==1,'Stale ACK reached producer'
                        checks.append('stale_consumer_ack_while_new_worker_pending')
                    else:raise AssertionError('Old consumer ACK was accepted')
                # First worker dies after original overwrite is verified but
                # before consumer read/ACK. OS-owned shm rights remain valid.
                if index==1:w.close(kill=True)
                sent=consumer.sendmsg([packet],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',fds))])
                assert sent==len(packet);consumer.sendall(b'O')
                q.await_state(lambda s:s['completed']==index)
                actual_width,actual_height,data=v.snapshot()
                assert (actual_width,actual_height)==(width,height) and data==pipeline.pixels(width,height,index%2==0),'Broker VNC exact pixels'
                magic,generation,status,reserved=struct.unpack('<4I',exact(consumer,16))
                assert magic==0x50534E50 and not reserved and status==0 and generation==scanout
                replay=None
                if index==2:
                    original=broker.pending[w.epoch]
                    replay=replace(original,fds=tuple(os.dup(fd) for fd in original.fds))
                broker.ack(w,generation,status)
                if index!=1:
                    w.await_kind(ACKED)
                    stats=w.stats();assert stats['captures']==1 and stats['acked']==1 and stats['active']==0 and stats['dropped_busy']==1,stats
                    if index==3:assert stats['exports']==0,'Destroyed export was retained beyond ACK'
                if replay:
                    try:broker.observe(w,replay)
                    except ValueError:pass
                    else:raise AssertionError('Replayed producer generation was accepted')
                    for fd in replay.fds:
                        try:os.fstat(fd)
                        except OSError as error:assert error.errno==9
                        else:raise AssertionError('Rejected replay descriptor leaked')
                    checks.append('replayed_producer_generation_rejected_and_rights_closed')
                previous_ack=generation
                records.append({'worker_epoch':epoch,'context_id':w.context,'resource_id':77,'resource_epoch':binding.resource_epoch,
                    'producer_generation':1,'consumer_generation':generation,'width':width,'height':height,'exact_pixels':width*height,
                    'control_before_export':index==1,'worker_killed_before_read':index==1})
                if index==2:
                    # Real second live worker imports the first worker's actual
                    # exported fd under the same VM resource ID. Revoke and wait
                    # for the producer barrier before forwarding the import.
                    other=Worker(broker,20,context=2);workers.append(other)
                    broker.import_resource(other,77,resource_fd)
                    w.signal();w.drained();assert w.stats()['captures']==1,'Imported resource still captured'
                    checks.append('real_cross_worker_import_revokes_writer');other.close()
                os.close(resource_fd)
                if not w.closed:w.close()
            # New process, same guest context/resource ID, stale host epoch
            # must terminate that worker before any capture or rebinding.
            stale=Worker(broker,30);workers.append(stale)
            fd,_=setup_export(stale);os.close(fd);stale.draw()
            old=broker.pending[stale.epoch]
            stale.command(replace(old,kind=ACK,body=b'',fds=(),worker_epoch=29))
            stale.process.wait(timeout=8);assert stale.process.returncode==0
            checks.append('real_worker_rejects_previous_epoch');stale.close()
            bounded=Worker(broker,31);workers.append(bounded)
            bounded.control.sendall(struct.pack('>I',0x7fffffff));bounded.process.wait(timeout=8)
            assert bounded.process.returncode==0;checks.append('real_worker_rejects_oversized_frame');bounded.close()
            unready=Worker(broker,40,withheld=True);workers.append(unready)
            fd,_=setup_export(unready);os.close(fd);unready.draw()
            for _ in range(3):
                try:broker.consumer_packet(unready)
                except BlockingIOError:pass
                else:raise AssertionError('Withheld producer token was bridged')
                time.sleep(.02)
            assert unready.epoch not in broker.ready_leases
            broker.cancel_unpublished(unready)
            stats=unready.stats();assert stats['captures']==1 and stats['acked']==1 and stats['active']==0
            assert q.get()['frames']==3,'Unready broker frame reached QEMU'
            checks.append('real_withheld_token_never_published');unready.close()
            badack=Worker(broker,41);workers.append(badack)
            fd,_=setup_export(badack);os.close(fd);badack.draw()
            pending=broker.pending[badack.epoch]
            badack.command(replace(pending,kind=ACK,body=b'',fds=(),resource_epoch=pending.resource_epoch+1))
            badack.process.wait(timeout=8);assert badack.process.returncode==0
            badack.close();assert badack.epoch not in broker.pending
            checks.append('real_worker_rejects_wrong_resource_ack')
            lost=Worker(broker,42,withheld=True);workers.append(lost)
            fd,_=setup_export(lost);os.close(fd);lost.draw()
            proofs=broker.producer_readiness_proven;lost.close(kill=True)
            assert lost.epoch not in broker.pending and lost.epoch not in broker.ready_leases and lost.epoch not in broker.workers
            assert broker.producer_readiness_proven==proofs and q.get()['frames']==3
            checks.append('real_unready_worker_death_drops_unpublished_lease')
            worker_early_eof(broker.session);checks.append('real_worker_eof_before_init')
            q.set('closed',True);final=q.get()
            assert final['completed']==3 and final['native_released']==3 and final['mappings_released']==3 and final['backend']['active_leases']==0,final
            assert not broker.pending and not broker.resources
            q.call('quit');assert qemu.wait(timeout=5)==0
            report={'result':'pass','real_worker_processes':len(workers)+1,'initialized_renderer_contexts':len(workers),
                'asynchronous_neptune_ring':True,'records':records,
                'checks':checks,'exact_pixels':sum(x['exact_pixels'] for x in records),'max_pending':broker.max_pending,
                'stale_acks_rejected_or_discarded':broker.stale_acks,'dead_worker_cleanups':broker.dead_cleanups,
                'producer_readiness_proven_before_handoff':broker.producer_readiness_proven,
                'unpublished_failure_cleanups':broker.unpublished_failure_cleanups,
                'final':final,'guest_cpu':False,'guest_disks':False,'windows':False,'tcp':False}
            receipt='neptune-broker' if LABEL=='broker' else 'neptune-'+LABEL
            (BASE/f'provenance/{receipt}.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
        finally:
            for worker in reversed(workers):worker.close()
            broker.close();consumer.close();child.close()
            if qemu and qemu.poll() is None:
                qemu.terminate()
                try:qemu.wait(timeout=5)
                except subprocess.TimeoutExpired:qemu.kill();qemu.wait()


if __name__=='__main__':run()
