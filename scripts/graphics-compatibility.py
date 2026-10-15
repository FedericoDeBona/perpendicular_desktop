#!/usr/bin/env python3
"""Paused diskless HVF/TPM/PCI check; never opens an existing VM's files."""
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

SPEC=importlib.util.spec_from_file_location('graphics_build',Path(__file__).with_name('graphics-build.py'))
build=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


def connect(path,process):
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
        if process.poll() is not None: raise RuntimeError('Owned fixture exited; inspect private compatibility logs')
        sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); sock.settimeout(5)
        try: sock.connect(str(path)); return sock
        except (FileNotFoundError,ConnectionRefusedError): sock.close(); time.sleep(.05)
    raise RuntimeError('Owned fixture socket not ready')


class QMP:
    def __init__(self,sock):
        self.sock=sock; self.file=sock.makefile('rb'); self.sequence=0
        assert 'QMP' in self.line()
        self.call('qmp_capabilities')
    def line(self):
        line=self.file.readline(1024*1024)
        if not line or not line.endswith(b'\n'): raise RuntimeError('Invalid fixture QMP line')
        return json.loads(line)
    def call(self,op):
        self.sequence+=1
        self.sock.sendall(json.dumps({'execute':op,'id':self.sequence}).encode()+b'\n')
        while True:
            reply=self.line()
            if reply.get('id')==self.sequence:
                if 'error' in reply: raise RuntimeError(str(reply['error']))
                return reply['return']


def main():
    env=build.prerequisites(optimization='0')
    angle=build.PREFIX/'ANGLE.xcarchive/Products/usr/local/lib'
    env['DYLD_FALLBACK_LIBRARY_PATH']=str(build.PREFIX/'lib')+':'+str(angle)
    swtpm=Path('/opt/homebrew/bin/swtpm')
    if not swtpm.is_file(): raise RuntimeError('Existing swtpm is required; this check installs nothing')
    stable=build.REPO/'.tools/qemu/bin/qemu-system-aarch64'
    experimental=build.PREFIX/'bin/qemu-system-aarch64'
    records=[]
    for label,binary,gpu,ppi in [('stable-ramfb',stable,'ramfb',True),
        ('fork-ramfb',experimental,'ramfb',False),('fork-virtio-ramfb',experimental,'virtio-ramfb',False)]:
        processes=[]
        with tempfile.TemporaryDirectory(prefix='perp-compat-',dir='/tmp') as temporary, \
             (build.LOGS/(label+'-paused-qemu.log')).open('w') as qlog, \
             (build.LOGS/(label+'-paused-swtpm.log')).open('w') as tlog:
            runtime=Path(temporary); state=runtime/'tpm'; state.mkdir(mode=0o700)
            try:
                t=subprocess.Popen([str(swtpm),'socket','--tpm2','--tpmstate','dir='+str(state),
                    '--ctrl','type=unixio,path='+str(runtime/'tpm.sock'),'--flags','not-need-init,startup-clear'],
                    env=env,stdout=tlog,stderr=subprocess.STDOUT)
                processes.append(t)
                deadline=time.monotonic()+5
                while not (runtime/'tpm.sock').exists():
                    if t.poll() is not None or time.monotonic()>deadline: raise RuntimeError('Owned swtpm not ready')
                    time.sleep(.05)
                argv=[str(binary),'-L',str(build.PREFIX/'share/qemu'),'-no-user-config','-nodefaults',
                    '-machine','virt,gic-version=3,highmem=on','-accel','hvf','-cpu','host',
                    '-m','128M','-smp','1','-S','-display','none','-vga','none','-nic','none',
                    '-device','qemu-xhci,id=usb','-device','usb-kbd,bus=usb.0','-device','usb-tablet,bus=usb.0',
                    '-device','virtio-net-pci,id=network','-device','virtio-rng-pci,id=rng',
                    '-blockdev','driver=null-co,node-name=empty,size=67108864',
                    '-device','nvme,id=bootnvme,drive=empty,serial=perp-compat-only,bootindex=1',
                    '-device','virtio-serial-pci,id=guestserial','-chardev','null,id=guestagent',
                    '-device','virtserialport,bus=guestserial.0,chardev=guestagent,name=org.perpendicular.guest_agent.0',
                    '-audiodev','none,id=audio0','-device','ich9-intel-hda,id=hda0',
                    '-device','hda-output,bus=hda0.0,audiodev=audio0',
                    '-chardev','socket,id=chrtpm,path='+str(runtime/'tpm.sock'),
                    '-tpmdev','emulator,id=tpm0,chardev=chrtpm',
                    '-device','tpm-tis-device,tpmdev=tpm0'+(',ppi=off' if ppi else ''),
                    '-device',gpu+',id=display0',
                    '-qmp','unix:'+str(runtime/'qmp.sock')+',server=on,wait=off',
                    '-vnc','unix:'+str(runtime/'vnc.sock'),'-monitor','none','-serial','none']
                p=subprocess.Popen(argv,env=env,stdout=qlog,stderr=subprocess.STDOUT); processes.append(p)
                sock=connect(runtime/'qmp.sock',p); q=QMP(sock)
                status=q.call('query-status'); assert status['running'] is False and status['status']=='prelaunch',status
                assert len(q.call('query-cpus-fast'))==1
                tpm=q.call('query-tpm'); assert len(tpm)==1 and tpm[0]['model']=='tpm-tis',tpm
                pci=q.call('query-pci')
                entries={x['qdev_id']:{k:x[k] for k in ('bus','slot','function','id')} for bus in pci for x in bus['devices'] if x['qdev_id']}
                assert 'bootnvme' in entries and 'guestserial' in entries and 'hda0' in entries,entries
                q.call('quit'); assert p.wait(timeout=5)==0
                q.file.close(); sock.close()
                records.append({'label':label,'qemu_sha256':build.file_hash(binary),'status':status,'tpm':tpm,
                    'pci':entries,'firmware':False,'disk_files':False,'guest_code_executed':False,
                    'tpm_state':'new temporary private state; destroyed after owned processes exit'})
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                        try: process.wait(timeout=5)
                        except subprocess.TimeoutExpired: process.kill(); process.wait()
    for key in ('bootnvme','usb','network','rng','guestserial','hda0'):
        assert records[0]['pci'][key]==records[1]['pci'][key]==records[2]['pci'][key],(key,records)
    report={'result':'pass','records':records,'pci_preserved':True,'no_existing_vm_files_or_processes_touched':True,
        'scope':'HVF initialization and paused hardware only; no Windows, firmware, storage or Secure Boot runtime verification'}
    (build.BASE/'provenance/graphics-compatibility.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':
    main()
