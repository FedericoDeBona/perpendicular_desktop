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
    def actual(w,h): return {'width':w,'height':h,'dpi':None,'device_name':'fixed-fixture','adapter':'fixture'}
    if command == 'guest-display-status':
        print(json.dumps({'display':{'connected':scenario!='channel-unavailable','can_resize':scenario not in ['fixed-driver','channel-unavailable'],
          'reason':'fixture actual capability','code':None,'current':actual(800,600),'modes':[{'width':800,'height':600},{'width':1280,'height':720},{'width':1600,'height':900}],
          'dpi_change_supported':False,'limits':{'min_width':640,'min_height':480,'max_width':3840,'max_height':2160,'max_pixels':8294400,'min_host_dpi':96,'max_host_dpi':288,'min_interval_ms':750}}}))
    elif command == 'guest-display-resize':
        assert sys.argv[2] == 'fixture-vm'
        assert sys.argv[3::2] == ['--width','--height','--host-dpi']
        w,h,dpi = map(int,sys.argv[4::2])
        (root/'resize-started').touch(mode=0o600)
        if scenario == 'stop':
            deadline = time.monotonic()+5
            while not (root/'release-cli').exists() and time.monotonic()<deadline: time.sleep(.01)
            assert (root/'release-cli').exists()
        ok = scenario != 'guest-unsupported'
        measured = actual(800,600) if scenario in ['false-success','guest-unsupported'] else actual(w,h)
        print(json.dumps({'display':{'applied':ok,'changed':ok,'code':'resized' if ok else 'display_resize_unsupported','reason':None,
          'requested':{'width':w,'height':h,'host_dpi':dpi},'actual':measured,'dpi_changed':False,'retry_after_ms':0}}))
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


for scenario in ['success','announcement','retina','rejected','ack-timeout','frame-timeout','coalescing','stop','fixed-driver','no-layout','channel-unavailable','false-success','guest-unsupported']:
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
                if scenario in ['fixed-driver','no-layout','channel-unavailable']:peer.drain();return
                peer.resize(1280,720)
                if scenario=='ack-timeout':peer.drain();return
                if scenario=='rejected':peer.update([layout(reason=1,status=1)]);peer.drain();return
                peer.update([layout(reason=1,status=0 if scenario=='announcement' else 4)])
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
