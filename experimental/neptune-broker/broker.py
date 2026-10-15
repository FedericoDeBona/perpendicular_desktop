#!/usr/bin/env python3
"""Original development supervisor; not a replacement for the renderer proxy.

All resource ingress in this closed fixture goes through this broker. A real
VM integration must put these checks at every proxy attach/create/destroy and
worker lifetime entry point, before granting the same ownership assertion.
"""
import array
from dataclasses import dataclass,replace
import os
import socket
import struct
import select

MAGIC=0x5042524B
HEADER=struct.Struct('<IHHIIQQIIQQQII')
HELLO,EXPORT,CLAIM,DESTROY,IMPORT,FRAME,BOUND,ACKED,VERIFIED,STATS,ERROR,CLAIM_BEGIN=range(1,13)
IMPORT_RESULT=13
BIND,ACK,VERIFY,STATUS,UNBIND=range(100,105)


@dataclass(frozen=True)
class Message:
    kind:int
    session:int
    worker_epoch:int
    context_id:int
    resource_id:int=0
    resource_epoch:int=0
    blob_id:int=0
    object_id:int=0
    snapshot_generation:int=0
    status:int=0
    body:bytes=b''
    fds:tuple=()

    def pack(self):
        assert len(self.body)<=176 and len(self.fds)<=2
        return HEADER.pack(MAGIC,1,self.kind,HEADER.size+len(self.body),len(self.fds),
            self.session,self.worker_epoch,self.context_id,self.resource_id,self.resource_epoch,
            self.blob_id,self.object_id,self.snapshot_generation,self.status)+self.body


def close_rights(fds):
    for fd in fds:
        os.close(fd)


def receive(channel,session,epoch,context):
    """Bounded stream parser: rights belong to the first byte of one frame.

    No allocation from untrusted length, at most 248 bytes and two descriptors.
    Fragmentation is accepted; truncated, oversized or misplaced rights close.
    """
    payload=bytearray();fds=[];wanted=HEADER.size
    try:
        while len(payload)<wanted:
            data,ancillary,flags,_=channel.recvmsg(wanted-len(payload),socket.CMSG_SPACE(3*array.array('i').itemsize))
            rights=[]
            for level,kind,raw in ancillary:
                if level!=socket.SOL_SOCKET or kind!=socket.SCM_RIGHTS:raise ValueError('Unexpected ancillary record')
                values=array.array('i');values.frombytes(raw[:len(raw)//values.itemsize*values.itemsize]);rights.extend(values)
            fds.extend(rights)
            if flags&socket.MSG_CTRUNC or len(fds)>2 or (rights and payload):raise ValueError('Truncated/excess/misplaced rights')
            if not data:raise EOFError('Worker channel closed mid-frame' if payload else 'Worker channel closed')
            payload.extend(data)
            if len(payload)==HEADER.size and wanted==HEADER.size:
                fields=HEADER.unpack(payload)
                if fields[0]!=MAGIC or fields[1]!=1 or fields[3]<HEADER.size or fields[3]>248 or fields[4]>2:
                    raise ValueError('Invalid bounded broker header')
                wanted=fields[3]
        fields=HEADER.unpack(payload[:HEADER.size])
        _,_,kind,_,fd_count,s,e,c,r,re,b,o,g,status=fields
        if (s,e,c)!=(session,epoch,context) or fd_count!=len(fds):raise ValueError('Stale worker identity or descriptor count')
        if kind==FRAME:
            if len(payload)!=248 or len(fds)!=2 or not re or not r or not b or not o or not g or status:
                raise ValueError('Invalid snapshot envelope')
        elif len(payload)!=HEADER.size or fds:raise ValueError('Unexpected broker body/rights')
        return Message(kind,s,e,c,r,re,b,o,g,status,bytes(payload[HEADER.size:]),tuple(fds))
    except BaseException:
        close_rights(fds);raise


class Broker:
    MAX_WORKERS=4
    MAX_RESOURCES=32

    def __init__(self,session):
        self.session=session;self.workers={};self.resources={};self.next_resource=0
        self.max_pending=0;self.pending={};self.consumer_sequences={};self.ready_leases={};self.next_scanout=0;self.stale_acks=0;self.dead_cleanups=0
        self.producer_readiness_proven=0
        self.highest_worker_epoch=0
        self.unpublished_failure_cleanups=0

    def add(self,worker):
        if len(self.workers)>=self.MAX_WORKERS or worker.epoch<=self.highest_worker_epoch:
            raise ValueError('Worker bound or non-increasing epoch')
        self.highest_worker_epoch=worker.epoch
        self.workers[worker.epoch]={'worker':worker,'exports':{},'claims':{},'imports':set(),'bound':None,'alive':True,'last_generation':0}

    def observe(self,worker,message):
        state=self.workers[worker.epoch]
        if not state['alive'] or (message.session,message.worker_epoch,message.context_id)!=(self.session,worker.epoch,worker.context):
            close_rights(message.fds);raise ValueError('Dead/stale observation')
        if message.kind==EXPORT:
            if not message.blob_id or not message.object_id or len(state['exports'])>=8:raise ValueError('Invalid export record')
            if message.blob_id in state['exports']:raise ValueError('Repeated export identity')
            state['exports'][message.blob_id]=message.object_id
        elif message.kind==CLAIM and message.status==1 and message.blob_id:
            if not message.resource_id or len(state['claims'])>=self.MAX_RESOURCES:raise ValueError('Claim registry bound')
            if message.resource_id in self.resources:raise ValueError('Resource ID already owned')
            if len(self.resources)>=self.MAX_RESOURCES:raise ValueError('Resource registry bound')
            state['claims'][message.resource_id]=message.blob_id
        elif message.kind in (DESTROY,IMPORT):
            if message.kind==IMPORT:
                if len(state['imports'])>=self.MAX_RESOURCES:raise ValueError('Import registry bound')
                state['imports'].add(message.resource_id)
            elif message.resource_id in self.resources:
                bound=self.resources[message.resource_id]
                if bound.worker_epoch!=worker.epoch:raise ValueError('Destroy by non-owner')
                del self.resources[message.resource_id]
        elif message.kind==FRAME:
            bound=state['bound']
            if not bound or self.identity(message)!=self.identity(bound) or worker.epoch in self.pending or message.snapshot_generation<=state['last_generation']:
                close_rights(message.fds);raise ValueError('Unbound or duplicate pending snapshot')
            old_magic,version,generation,context=struct.unpack_from('<IIII',message.body)
            if old_magic!=0x50534E50 or version!=1 or generation!=message.snapshot_generation or context!=worker.context:
                close_rights(message.fds);raise ValueError('Snapshot body/envelope disagree')
            if struct.unpack_from('<Q',message.body,16)[0]!=message.blob_id:
                close_rights(message.fds);raise ValueError('Snapshot blob mismatch')
            self.pending[worker.epoch]=message;self.max_pending=max(self.max_pending,len(self.pending))
            state['last_generation']=message.snapshot_generation
        elif message.kind not in (HELLO,CLAIM_BEGIN,CLAIM,BOUND,ACKED,VERIFIED,STATS,IMPORT_RESULT):
            close_rights(message.fds);raise ValueError('Unknown worker operation')
        return message

    @staticmethod
    def identity(message):
        return (message.worker_epoch,message.context_id,message.resource_id,message.resource_epoch,message.blob_id,message.object_id)

    def bind(self,worker,resource):
        state=self.workers[worker.epoch]
        blob=state['claims'].get(resource);obj=state['exports'].get(blob)
        if not state['alive'] or not blob or not obj or len(state['exports'])!=1 or state['bound']:
            raise ValueError('Export and successful control claim are both required')
        if any(resource in other['imports'] for other in self.workers.values() if other['alive']):
            raise ValueError('Imported resource has unknown additional writer')
        if resource in self.resources:raise ValueError('Duplicate resource ownership')
        self.next_resource+=1
        message=Message(BIND,self.session,worker.epoch,worker.context,resource,self.next_resource,blob,obj)
        self.resources[resource]=message;state['bound']=message;worker.command(message)
        worker.await_kind(BOUND)
        return message

    def revoke_before_import(self,resource):
        bound=self.resources.pop(resource,None)
        if bound:
            state=self.workers[bound.worker_epoch]
            if state['alive']:
                state['worker'].command(replace(bound,kind=UNBIND));state['worker'].await_kind(BOUND)
            state['bound']=None

    def import_resource(self,worker,resource,fd):
        # Revoke and receive the actual producer barrier before the other
        # worker can map or open the VM resource. All fixture imports enter here.
        self.revoke_before_import(resource)
        worker.import_resource(resource,fd)

    def died(self,worker):
        state=self.workers[worker.epoch];state['alive']=False;state['bound']=None
        self.resources={r:b for r,b in self.resources.items() if b.worker_epoch!=worker.epoch}
        # Pending consumer may still own its duplicated mapping. Its ACK will
        # only release the broker's retained rights, never target a replacement.
        self.dead_cleanups+=1
        if worker.epoch in self.pending and worker.epoch not in self.ready_leases:
            close_rights(self.pending.pop(worker.epoch).fds);self.unpublished_failure_cleanups+=1
        if worker.epoch not in self.pending:self.workers.pop(worker.epoch)

    def consumer_packet(self,worker):
        message=self.pending[worker.epoch]
        if not self.workers[worker.epoch]['alive'] or worker.process.poll() is not None:
            raise ValueError('Dead worker cannot supply new readiness')
        poll=select.poll();poll.register(message.fds[1],select.POLLIN)
        events=poll.poll(0)
        if not events:raise BlockingIOError('Actual producer fence is not ready')
        if events[0][1]&(select.POLLHUP|select.POLLERR|select.POLLNVAL) or not events[0][1]&select.POLLIN:
            raise ValueError('Producer event failed before readiness proof')
        if worker.epoch in self.ready_leases:raise ValueError('Consumer lease already issued')
        # DXMT's event fd gets HUP when its process dies. After proving actual
        # readiness with a live producer, the broker owns a retained signal
        # pipe whose writer stays open through consumer ACK. EOF alone never
        # creates a ready token. The source fd and shm rights also remain held.
        read,write=os.pipe()
        try:
            if os.write(write,b'R')!=1:raise OSError('Readiness pipe short write')
        except BaseException:close_rights((read,write));raise
        self.ready_leases[worker.epoch]=(read,write)
        self.producer_readiness_proven+=1;self.next_scanout+=1
        self.consumer_sequences[worker.epoch]=self.next_scanout
        packet=bytearray(message.body);struct.pack_into('<I',packet,8,self.next_scanout)
        return bytes(packet),(message.fds[0],read),self.next_scanout

    def ack(self,worker,generation,status):
        message=self.pending.get(worker.epoch)
        if not message or generation!=self.consumer_sequences.get(worker.epoch) or status not in (0,1):
            self.stale_acks+=1;raise ValueError('Unknown/stale consumer ACK')
        state=self.workers[worker.epoch]
        if state['alive']:
            worker.command(replace(message,kind=ACK,body=b'',fds=(),status=status))
        else:self.stale_acks+=1;self.workers.pop(worker.epoch)
        close_rights(message.fds);del self.pending[worker.epoch]
        close_rights(self.ready_leases.pop(worker.epoch,()))
        self.consumer_sequences.pop(worker.epoch,None)

    def close(self):
        for message in self.pending.values():close_rights(message.fds)
        for fds in self.ready_leases.values():close_rights(fds)
        self.ready_leases.clear()
        self.pending.clear()

    def cancel_unpublished(self,worker):
        """No consumer has acquired this lease. Actual worker fence validation
        still decides whether cancellation can release the producer snapshot.
        """
        message=self.pending[worker.epoch]
        if worker.epoch in self.ready_leases:raise ValueError('Consumer owns issued lease')
        worker.command(replace(message,kind=ACK,body=b'',fds=(),status=1))
        worker.await_kind(ACKED)
        close_rights(message.fds);del self.pending[worker.epoch]
