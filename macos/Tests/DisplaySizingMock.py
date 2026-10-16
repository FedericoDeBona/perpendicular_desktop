#!/usr/bin/env python3
"""Private local RFB peer plus real short-lived engine fixture processes."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time

HARNESS = sys.argv[1]
WORK = Path(sys.argv[2])

ENGINE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['PERPENDICULAR_DISPLAY_FIXTURE'])
scenario = os.environ['PERPENDICULAR_DISPLAY_SCENARIO']
lock = root / 'engine.lock'
try: fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
except FileExistsError: raise RuntimeError('Engine commands overlapped')
os.close(fd)
try:
    command = sys.argv[1]
    # Python <=3.9 on macOS uses a process-local monotonic epoch. A common wall
    # clock is required when comparing separate real fixture subprocesses.
    record = {'command':command, 'arguments':sys.argv[2:], 'time':time.time()}
    with (root / 'commands.ndjson').open('a') as log: log.write(json.dumps(record)+'\n')
    records = [json.loads(line) for line in (root/'commands.ndjson').read_text().splitlines()]
    status_count = sum(item['command']=='guest-display-status' for item in records)
    resize_count = sum(item['command']=='guest-display-resize' for item in records)
    recovery = scenario.startswith('recover-')
    def error(code, message='Fixture transport exchange expired.'):
        print(json.dumps({'error':{'code':code,'message':message}}));sys.exit(1)
    def held(name, release):
        (root/name).touch(mode=0o600)
        deadline = time.monotonic()+5
        while not (root/release).exists() and time.monotonic()<deadline: time.sleep(.01)
        assert (root/release).exists(), 'Harness did not release held fixture command'
    def actual(w,h): return {'width':w,'height':h,'dpi':None,'device_name':'fixed-fixture','adapter':'fixture'}
    if command == 'guest-display-status':
        assert status_count <= (6 if scenario=='bootstrap-exhausted' else 5 if scenario.startswith('bootstrap-') else 3 if scenario=='recover-reconnect' else 2), 'Unbounded capability requery'
        if recovery and status_count == 2:
            if scenario in ['recover-stop','recover-disable','recover-hidden','recover-reconnect','recover-target-changed','recover-deadline','recover-frame-first','recover-queued-deadline','recover-queued-hidden','recover-queued-target']:
                held('status-held','release-status')
            if scenario=='recover-status-error': error('guest_agent_timeout')
        disconnected = scenario=='channel-unavailable' or (scenario=='recover-status-unavailable' and status_count==2)
        startup_code = None
        if scenario.startswith('bootstrap-'):
            if scenario in ['bootstrap-deadline','bootstrap-hidden'] and status_count==2:
                held('bootstrap-held','release-bootstrap')
            disconnected = (scenario=='bootstrap-ready' and status_count<=2) or scenario in ['bootstrap-terminal','bootstrap-cancelled'] or (scenario=='bootstrap-exhausted' and not (root/'agent-ready').exists()) or (scenario in ['bootstrap-deadline','bootstrap-hidden'] and status_count==1)
            if disconnected: startup_code = 'guest_agent_protocol' if scenario=='bootstrap-terminal' else ('guest_agent_timeout' if status_count%2==0 else 'guest_agent_unavailable')
        fixed = scenario=='fixed-driver' or (scenario=='recover-reconnect' and status_count==3)
        measured = actual(1280,720) if status_count==2 and scenario in ['recover-applied','recover-applied-no-frame','recover-frame-first','recover-stop','recover-disable','recover-hidden','recover-reconnect'] else actual(800,600)
        modes = [{'width':800,'height':600},{'width':1280,'height':720},{'width':1600,'height':900}]
        if scenario=='recover-status-no-target' and status_count==2: modes.pop(1)
        print(json.dumps({'display':{'connected':not disconnected,'can_resize':not (fixed or disconnected),
          'reason':'fixture actual capability','code':startup_code,'current':measured,'modes':modes,
          'dpi_change_supported':False,'limits':{'min_width':640,'min_height':480,'max_width':3840,'max_height':2160,'max_pixels':8294400,'min_host_dpi':96,'max_host_dpi':288,'min_interval_ms':750}}}))
    elif command == 'guest-display-resize':
        assert sys.argv[2] == 'fixture-vm'
        assert sys.argv[3::2] == ['--width','--height','--host-dpi']
        w,h,dpi = map(int,sys.argv[4::2])
        (root/'resize-started').touch(mode=0o600)
        assert resize_count <= 2, 'Unbounded resize mutation retry'
        if recovery and resize_count==1:
            if scenario=='recover-deadline': time.sleep(.45)
            if scenario=='recover-message-only':
                print('Guest agent did not complete the exchange within5seconds',file=sys.stderr);sys.exit(1)
            code = {'recover-unavailable':'guest_agent_unavailable','recover-protocol-error':'guest_agent_protocol','recover-ownership-error':'ownership_mismatch'}.get(scenario,'guest_agent_timeout')
            error(code)
        if scenario=='recover-second-timeout': error('guest_agent_timeout')
        if scenario=='recover-retry-deadline': held('retry-held','release-retry')
        if scenario == 'stop':
            deadline = time.monotonic()+5
            while not (root/'release-cli').exists() and time.monotonic()<deadline: time.sleep(.01)
            assert (root/'release-cli').exists()
        ok = scenario != 'guest-unsupported'
        measured = actual(800,600) if scenario in ['false-success','guest-unsupported'] else actual(w,h)
        print(json.dumps({'display':{'applied':ok,'changed':ok,'code':'resized' if ok else 'display_resize_unsupported','reason':None,
          'requested':{'width':w,'height':h,'host_dpi':dpi},'actual':measured,'dpi_changed':False,'retry_after_ms':0}}))
    elif command == 'hold-queue':
        held('queue-held','release-queue')
        print('{}')
    else: raise RuntimeError('Unexpected engine action')
finally: lock.unlink()
'''


class Peer:
    def __init__(self, connection): self.connection = connection
    def read(self, count):
        data = b''
        while len(data) < count:
            chunk = self.connection.recv(count-len(data))
            assert chunk, 'Unexpected disconnect'
            data += chunk
        return data
    def send(self, data):
        # Fragment bounded layouts, preserving the exact-read regression.
        for offset in range(0,len(data),7): self.connection.sendall(data[offset:offset+7])
    def handshake(self):
        self.send(b'RFB 003.008\n'); assert self.read(12)==b'RFB 003.008\n'
        self.send(b'\x01\x01'); assert self.read(1)==b'\x01'; self.send(bytes(4)); assert self.read(1)==b'\x01'
        self.send(struct.pack('>HH',800,600)+bytes(16)+struct.pack('>I',4)+b'test')
        assert self.read(20)==bytes([0,0,0,0,32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0])
        assert self.read(20)==struct.pack('>BBHiiii',2,0,4,0,-223,-224,-308)
        assert self.read(10)==struct.pack('>BBHHHH',3,0,0,0,800,600)
    def update(self, rectangles): self.send(struct.pack('>BBH',0,0,len(rectangles))+b''.join(rectangles))
    def message(self):
        first = self.connection.recv(1)
        if not first: return None
        kind = first[0]
        assert kind in [3,251], 'Unexpected guest input or protocol message'
        return first+self.read(9 if kind==3 else 23)
    def resize(self, width, height):
        while True:
            message = self.message()
            assert message is not None, 'Disconnected before resize hint'
            if message[0]==3: continue
            expected = struct.pack('>BBHHBBIHHHHI',251,0,width,height,1,0,42,0,0,width,height,0)
            assert message==expected, 'Wrong hint, target, screen ID or bounds'
            return
    def drain(self):
        while True:
            message=self.message()
            if message is None:return
            assert message[0]==3, 'Unexpected extra automatic resize'


def rect(x,y,w,h,encoding,payload=b''): return struct.pack('>HHHHi',x,y,w,h,encoding)+payload
def layout(reason=0,status=0,w=800,h=600):
    return rect(reason,status,w,h,-308,struct.pack('>BBBBIHHHHI',1,0,0,0,42,0,0,w,h,0))
def pixel(): return rect(0,0,1,1,0,bytes([0,0,255,0]))
def changed(w,h): return [rect(0,0,w,h,-223),pixel()]
def wait_file(path):
    deadline=time.monotonic()+7
    while not path.exists() and time.monotonic()<deadline: time.sleep(.01)
    assert path.exists(), 'Harness did not allow next measured framebuffer'


for scenario in ['success','announcement','retina','rejected','ack-timeout','frame-timeout','coalescing','stop','fixed-driver','no-layout','channel-unavailable','false-success','guest-unsupported',
                 'recover-retry','recover-unavailable','recover-applied','recover-frame-first','recover-applied-no-frame','recover-second-timeout',
                 'recover-status-error','recover-status-unavailable','recover-status-no-target','recover-target-changed','recover-deadline','recover-retry-deadline',
                 'recover-stop','recover-disable','recover-hidden','recover-reconnect','recover-protocol-error','recover-ownership-error','recover-message-only',
                 'recover-queued-deadline','recover-queued-hidden','recover-queued-target',
                 'bootstrap-ready','bootstrap-exhausted','bootstrap-deadline','bootstrap-hidden','bootstrap-terminal','bootstrap-cancelled']:
    if len(sys.argv)>3 and scenario!=sys.argv[3]:continue
    root=WORK/scenario;root.mkdir(mode=0o700)
    engine=root/'engine';engine.write_text(ENGINE);engine.chmod(0o700)
    path=root/'rfb.sock'
    server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);server.bind(str(path));server.listen(1);server.settimeout(12)
    errors=[]
    def serve():
        try:
            connection,_=server.accept();connection.settimeout(12)
            with connection:
                peer=Peer(connection);peer.handshake()
                peer.update(([layout()] if scenario!='no-layout' else [])+[pixel()])
                if scenario in ['fixed-driver','no-layout','channel-unavailable','bootstrap-deadline','bootstrap-hidden','bootstrap-terminal','bootstrap-cancelled']:peer.drain();return
                peer.resize(1280,720)
                if scenario=='ack-timeout':peer.drain();return
                if scenario=='rejected':peer.update([layout(reason=1,status=1)]);peer.drain();return
                peer.update([layout(reason=1,status=0 if scenario=='announcement' else 4)])
                if scenario.startswith('recover-'):
                    if scenario=='recover-applied-no-frame':peer.update([rect(0,0,1280,720,-223)])
                    if scenario in ['recover-retry','recover-unavailable','recover-applied','recover-frame-first','recover-retry-deadline']:
                        wait_file(root/'allow-frame');peer.update(changed(1280,720))
                    peer.drain()
                    if scenario=='recover-reconnect':
                        replacement,_=server.accept();replacement.settimeout(12)
                        with replacement:
                            current=Peer(replacement);current.handshake();current.update([layout(),pixel()])
                            (root/'rfb-reconnected').touch(mode=0o600)
                            current.drain()
                    return
                if scenario=='frame-timeout':
                    # A size-only metadata rectangle contains no received guest
                    # pixels and cannot complete the UI's actual-frame check.
                    peer.update([rect(0,0,1280,720,-223)])
                if scenario in ['false-success','guest-unsupported','frame-timeout','stop']:peer.drain();return
                wait_file(root/'allow-frame');peer.update(changed(1280,720))
                if scenario=='coalescing':
                    peer.resize(1600,900)
                    peer.update([layout(reason=1,status=4,w=1280,h=720)])
                    wait_file(root/'allow-second-frame');peer.update(changed(1600,900))
                peer.drain()
        except BaseException as error:errors.append(error)
    thread=threading.Thread(target=serve,daemon=True);thread.start()
    environment=dict(os.environ,PERPENDICULAR_ENGINE=str(engine),PERPENDICULAR_DISPLAY_RENDERER='coregraphics',
                     PERPENDICULAR_DISPLAY_FIXTURE=str(root),PERPENDICULAR_DISPLAY_SCENARIO=scenario)
    try:
        result=subprocess.run([HARNESS,scenario,str(path),str(root)],env=environment,capture_output=True,text=True,timeout=20)
        thread.join(timeout=2)
        assert result.returncode==0,(scenario,result.stdout,result.stderr,errors)
        assert not errors and not thread.is_alive(),(scenario,errors)
        print(result.stdout.strip(),flush=True)
    finally:server.close();path.unlink(missing_ok=True)
print('All native display sizing integration fixtures passed.',flush=True)
