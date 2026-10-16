#!/usr/bin/env python3
"""Real diskless qtest: firmware fw_cfg RAMFB, VirtIO queue 2D, RFB resize hints."""
import argparse
import importlib.util
import sys
sys.dont_write_bytecode = True
import json
from pathlib import Path
import select
import socket
import struct
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
PRIVATE = REPO / ".tools/runtime-display"
spec = importlib.util.spec_from_file_location("frozen_rfb", REPO / "experimental/input-backpressure/test-server.py")
frozen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frozen)


class QTest(frozen.QTest):
    def command(self, text):
        self.peer.sendall(text.encode() + b"\n")
        line = self.lines.readline().decode().strip()
        assert line.startswith("OK"), line
        return line[2:].strip()

    def write(self, address, data):
        self.command("write 0x%x 0x%x 0x%s" % (address, len(data), data.hex()))

    def read(self, address, count):
        return bytes.fromhex(self.command("read 0x%x 0x%x" % (address, count)).removeprefix("0x"))

    def get(self, address, size):
        return int(self.command("read%s 0x%x" % ({1:"b", 2:"w", 4:"l", 8:"q"}[size], address)), 16)

    def put(self, address, value, size):
        self.command("write%s 0x%x 0x%x" % ({1:"b", 2:"w", 4:"l", 8:"q"}[size], address, value))


class RFB(frozen.RFB):
    def __init__(self, peer):
        super().__init__(peer)
        peer.sendall(struct.pack(">BBHiii", 2, 0, 3, 0, -223, -308))
        self.layouts = []

    def frame(self):
        assert self.read(1) == b"\0"
        count = struct.unpack(">H", self.read(3)[1:])[0]
        assert count <= 512
        pixels = []
        for _ in range(count):
            x, y, w, h, encoding = struct.unpack(">HHHHi", self.read(12))
            if encoding == 0:
                assert x+w <= self.width and y+h <= self.height
                pixels.append((x, y, w, h, self.read(w*h*4)))
            elif encoding == -223:
                self.width, self.height = w, h
            elif encoding == -308:
                screens = self.read(4)[0]
                assert screens <= 16
                self.read(screens*16)
                self.layouts.append((x, y, w, h))
                if y == 0:
                    self.width, self.height = w, h
            else:
                raise AssertionError("Unexpected RFB encoding: " + str(encoding))
        return pixels

    def expect_color(self, qt, width, height, rgb):
        deadline = time.monotonic()+5
        last = None
        while time.monotonic() < deadline:
            self.request()
            qt.step()
            if select.select([self.peer], [], [], .15)[0]:
                for x,y,w,h,data in self.frame():
                    if (self.width,self.height)==(width,height) and (x,y,w,h)==(0,0,width,height):
                        last = (len(data), data[:16].hex(), data[len(data)//2:len(data)//2+16].hex())
                        expected = bytes([rgb[2],rgb[1],rgb[0]])
                        if all(data[i:i+3] == expected for i in range(0,len(data),4)):
                            return
            time.sleep(.01)
        raise TimeoutError("Actual guest framebuffer did not match requested dimensions/color: "+str(last))

    def hint(self, width, height):
        self.peer.sendall(struct.pack(">BBHHBBIHHHHI", 251, 0, width, height, 1, 0, 0, 0, 0, width, height, 0))


class GPU:
    """Minimal real modern PCI VirtIO driver, without replacing device logic."""
    def __init__(self, qt, qmp):
        self.qt = qt
        devices = qmp.command("query-pci")[0]["devices"]
        device = next(item for item in devices if item.get("qdev_id") == "gpu")
        assert device["slot"] == 7, device
        assert device["id"]["vendor"] == 0x1AF4 and device["id"]["device"] == 0x1050, device["id"]
        self.pci = 0x4010000000 + (7 << 15)
        assert qt.get(self.pci,2) == 0x1AF4
        self.bars = {}
        next_address = 0x10000000
        for region in device["regions"]:
            bar = region["bar"]
            if bar > 5 or region["type"] != "memory":
                continue
            size = region["size"]
            next_address = (next_address+size-1)&~(size-1)
            self.bars[bar] = next_address
            qt.put(self.pci+0x10+bar*4,next_address,4)
            if region.get("mem_type_64"):
                qt.put(self.pci+0x14+bar*4,0,4)
            next_address += size
        qt.put(self.pci+4,6,2)
        caps = {}
        cap = qt.get(self.pci+0x34,1)
        while cap:
            if qt.get(self.pci+cap,1) == 9:
                kind=qt.get(self.pci+cap+3,1)
                bar=qt.get(self.pci+cap+4,1)
                offset=qt.get(self.pci+cap+8,4)
                if kind in (1,2,3,4):
                    caps[kind]=(self.bars[bar]+offset,cap)
            cap=qt.get(self.pci+cap+1,1)
        self.common=caps[1][0]
        self.notify=caps[2][0]
        self.multiplier=qt.get(self.pci+caps[2][1]+16,4)
        c=self.common
        qt.put(c+20,0,1)
        qt.put(c+20,3,1)
        qt.put(c,1,4)
        assert qt.get(c+4,4)&1, "Modern VERSION_1 feature absent"
        qt.put(c+8,0,4);qt.put(c+12,0,4)
        qt.put(c+8,1,4);qt.put(c+12,1,4)
        qt.put(c+20,11,1)
        assert qt.get(c+20,1)&8
        qt.put(c+22,0,2)
        assert qt.get(c+24,2)>=64
        qt.put(c+24,64,2)
        self.desc,self.avail,self.used=0x40080000,0x40081000,0x40082000
        self.request,self.response=0x40084000,0x40085000
        for address in (self.desc,self.avail,self.used,self.request,self.response):qt.write(address,bytes(4096))
        qt.put(c+32,self.desc,8);qt.put(c+40,self.avail,8);qt.put(c+48,self.used,8)
        self.notification=qt.get(c+30,2)*self.multiplier
        qt.put(c+28,1,2);qt.put(c+20,15,1)
        self.index=0
        print("Modern VirtIO GPU identity and PCI slot 7 PASS",flush=True)

    def command(self, kind, payload=b"", expected=0x1100):
        qt=self.qt
        request=struct.pack("<IIQII",kind,0,0,0,0)+payload
        assert len(request)<4096
        qt.write(self.request,request);qt.write(self.response,bytes(512))
        qt.write(self.desc,struct.pack("<QIHH",self.request,len(request),1,1)+struct.pack("<QIHH",self.response,512,2,0))
        qt.put(self.avail+4+2*(self.index%64),0,2)
        self.index=(self.index+1)&0xffff
        qt.put(self.avail+2,self.index,2)
        qt.put(self.notify+self.notification,0,2)
        deadline=time.monotonic()+3
        while qt.get(self.used+2,2)!=self.index:
            assert time.monotonic()<deadline,"Real VirtIO control queue did not complete"
            qt.step();time.sleep(.002)
        response=qt.read(self.response,512)
        assert struct.unpack_from("<I",response)[0]==expected,hex(struct.unpack_from("<I",response)[0])
        return response

    def color_scanout(self, width, height, rgb, resource):
        qt=self.qt;address=0x42000000
        data=bytes([rgb[2],rgb[1],rgb[0],0])*width*height
        qt.write(address,data)
        self.command(0x101,struct.pack("<IIII",resource,2,width,height))
        self.command(0x106,struct.pack("<IIQII",resource,1,address,len(data),0))
        rect=struct.pack("<IIII",0,0,width,height)
        self.command(0x105,rect+struct.pack("<QII",0,resource,0))
        self.command(0x103,rect+struct.pack("<II",0,resource))
        self.command(0x104,rect+struct.pack("<II",resource,0))


def firmware_ramfb(qt):
    base=0x9020000
    qt.write(base+8,struct.pack(">H",0x19))
    def data(count):return bytes(qt.get(base,1) for _ in range(count))
    count=struct.unpack(">I",data(4))[0]
    assert count<256
    selector=None
    for _ in range(count):
        entry=data(64)
        size,select_number=struct.unpack(">IH",entry[:6])
        if entry[8:].split(b"\0",1)[0]==b"etc/ramfb":
            assert size==28
            selector=select_number
    assert selector is not None,"Hybrid firmware etc/ramfb entry absent"
    framebuffer=0x41000000
    qt.write(framebuffer,bytes([0,0,255,0])*640*480)
    config=struct.pack(">QIIIII",framebuffer,0x34325258,0,640,480,640*4)
    qt.write(0x40010000,config)
    qt.write(0x40011000,struct.pack(">IIQ",(selector<<16)|0x18,len(config),0x40010000))
    qt.write(base+16,struct.pack(">Q",0x40011000))
    assert qt.read(0x40011000,4)==bytes(4),"Firmware DMA did not consume RAMFB configuration"
    qt.write(base+8,struct.pack(">H",selector))
    readback = data(28)
    assert readback == config, (readback.hex(), config.hex(), selector)
    assert qt.read(framebuffer,4)==bytes([0,0,255,0])


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary",type=Path,required=True)
    parser.add_argument("--source",type=Path,default=PRIVATE/"source")
    args=parser.parse_args();binary=args.binary.resolve()
    assert PRIVATE.resolve() in binary.parents
    with tempfile.TemporaryDirectory(prefix="display-test-",dir=PRIVATE) as directory:
        work=Path(directory);log_path=work/"qemu.log"
        command=[str(binary),"-machine","virt","-accel","qtest","-cpu","cortex-a57","-m","128M","-nodefaults","-display","none","-serial","none","-monitor","none","-L",str(args.source/"pc-bios"),"-device","virtio-ramfb,id=gpu,addr=7,max_outputs=2","-vnc","unix:"+str(work/"vnc"),"-qmp","unix:"+str(work/"qmp")+",server=on,wait=off","-qtest","unix:"+str(work/"qtest")+",server=on,wait=off","-qtest-log","/dev/null"]
        peers=[]
        with log_path.open("wb") as log:
            child=subprocess.Popen(command,stdout=log,stderr=log);qmp=None
            try:
                peer=frozen.connect(work/"qmp",child);peers.append(peer);qmp=frozen.QMP(peer)
                peer=frozen.connect(work/"qtest",child);peers.append(peer);qt=QTest(peer)
                qmp.command("cont")
                firmware_ramfb(qt)
                rfb=RFB(frozen.connect(work/"vnc",child));peers.append(rfb.peer)
                rfb.expect_color(qt,640,480,(255,0,0))
                print("Real fw_cfg DMA RAMFB firmware frame: 640x480 exact red pixels PASS",flush=True)
                gpu=GPU(qt,qmp)
                gpu.color_scanout(800,600,(0,0,255),1)
                rfb.expect_color(qt,800,600,(0,0,255))
                print("Real VirtIO resource/attach/transfer/scanout/flush handoff: 800x600 exact blue pixels PASS",flush=True)
                # Forwarding a host hint must not falsely change actual pixels.
                rfb.layouts.clear();rfb.hint(1280,800)
                deadline=time.monotonic()+3
                while not any(item[:2]==(1,4) for item in rfb.layouts):
                    assert time.monotonic()<deadline,"RFB resize was not forwarded"
                    qt.step()
                    if select.select([rfb.peer],[],[],.05)[0]:rfb.frame()
                assert (rfb.width,rfb.height)==(800,600),rfb.layouts
                info=gpu.command(0x100,expected=0x1101)
                _,_,width,height,enabled,_=struct.unpack_from("<IIIIII",info,24)
                assert (width,height,enabled)==(1280,800,1),(width,height,enabled)
                rfb.expect_color(qt,800,600,(0,0,255))
                gpu.color_scanout(1280,800,(0,255,0),2)
                rfb.expect_color(qt,1280,800,(0,255,0))
                print("Real RFB251 ui_info hint forwarded with old framebuffer; guest VirtIO command applies 1280x800 exact green PASS",flush=True)
            except BaseException:
                print(log_path.read_text(errors="replace")[-3000:]);raise
            finally:
                if child.poll() is None:
                    try:
                        if qmp:qmp.command("quit")
                    except (OSError,AssertionError):pass
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=3)
                for peer in peers:peer.close()
            assert child.returncode==0


if __name__=="__main__":main()
