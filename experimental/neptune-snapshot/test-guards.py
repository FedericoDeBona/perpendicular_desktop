#!/usr/bin/env python3
"""Guard rejection through the actual Neptune wire Signal dispatcher."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import array

BASE=Path(__file__).resolve().parents[2]/'.tools/graphics-experiment'


def main():
    env=os.environ.copy(); env.pop('PERP_SNAPSHOT_WITHHOLD',None)
    env['DYLD_FALLBACK_LIBRARY_PATH']=str(BASE/'prefix/lib')+':'+str(BASE/'prefix/ANGLE.xcarchive/Products/usr/local/lib')
    env['DXMT_LOG_PATH']=str(BASE/'logs'); env['NPT_BACKEND']='dxmt'
    records=[]
    for guard,counter in [('unadmitted','rejected_scope'),('wrong-writer','rejected_owner'),
        ('multi-ring','rejected_scope'),('multi-context','rejected_scope'),('import','rejected_import'),
        ('ambiguous-export','rejected_owner'),('oversize','rejected_layout')]:
        left,right=socket.socketpair(socket.AF_UNIX,socket.SOCK_STREAM)
        try:
            result=subprocess.run([str(BASE/'build/neptune-snapshot/decoder-fixture'),str(left.fileno()),guard],env=env,
                pass_fds=(left.fileno(),),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=15)
            left.close(); right.settimeout(1)
            assert result.returncode==0,(guard,result.stdout)
            assert right.recv(1)==b'',guard+' unexpectedly published snapshot bytes'
            (BASE/('logs/neptune-guard-'+guard+'.log')).write_text(result.stdout)
            row=next(json.loads(line) for line in result.stdout.splitlines() if line.startswith('{') and '"guard"' in line)
            assert row['registry']['captures']==0 and row['registry'][counter]>0,row
            records.append(row)
        finally:
            left.close(); right.close()
    acknowledgements=[]
    for fault in ('wrong-generation','consumer-disconnect'):
        left,right=socket.socketpair(socket.AF_UNIX,socket.SOCK_STREAM)
        process=None; rights=[]
        try:
            right.settimeout(5)
            process=subprocess.Popen([str(BASE/'build/neptune-snapshot/decoder-fixture'),str(left.fileno())],env=env,
                pass_fds=(left.fileno(),),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            left.close(); right.sendall(b'N')
            packet,ancillary,flags,address=right.recvmsg(176,socket.CMSG_SPACE(8))
            assert len(packet)==176 and not flags and len(ancillary)==1,(fault,len(packet),flags)
            level,kind,data=ancillary[0]; assert level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS and len(data)==8
            rights=list(array.array('i',data)); assert len(rights)==2
            generation=struct.unpack_from('=I',packet,8)[0]
            assert right.recv(1)==b'O','Original overwrite must be verified before ACK fault'
            if fault=='wrong-generation':
                right.sendall(struct.pack('=IIII',0x50534e50,generation+1,0,0))
            else:
                right.close()
            output=process.communicate(timeout=10)[0]
            assert process.returncode==1 and 'Consumer exact ACK and snapshot release' in output,(fault,output)
            (BASE/('logs/neptune-ack-'+fault+'.log')).write_text(output)
            acknowledgements.append({'fault':fault,'result':'expected_rejection','consumer_gpu_read':False})
        finally:
            left.close(); right.close()
            for fd in rights: os.close(fd)
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
    report={'result':'pass','guards':records,'acknowledgements':acknowledgements,'guest_or_vm_started':False}
    (BASE/'provenance/neptune-guards.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':
    main()
