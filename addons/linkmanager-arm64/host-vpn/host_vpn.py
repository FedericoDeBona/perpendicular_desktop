#!/usr/bin/env python3
"""Manage the Mac side of the experimental LinkManager IP relay (TCP/UDP)."""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import socket
import stat
import struct
import base64
import time
import subprocess
import sys

DEFAULT = Path.home()/'Library/Application Support/Perpendicular Restart/HostVPN'
PIN = '6546126c1759683fe85798da92409215d53c50e0f2b346b4f74a61babc8dbec2'


def checked_root(root):
    root = root.resolve(strict=True)
    st = root.stat()
    if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise ValueError('Runtime must be owned by this user, mode0700')
    if hashlib.sha256((root/'sing-box').read_bytes()).hexdigest() != PIN:
        raise ValueError('Runtime hash mismatch')
    return root


def control(root, command):
    path=root/'tun.sock'
    st=path.lstat()
    if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode)!=0o600:
        raise ValueError('Invalid private supervisor socket')
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5);s.connect(str(path));s.sendall(command.encode()+b'\n')
        return s.recv(128).decode().strip()


def receive_exact(stream, count):
    data=bytearray()
    while len(data)<count:
        chunk=stream.recv(count-len(data))
        if not chunk: raise ValueError('Control disconnected')
        data.extend(chunk)
    return bytes(data)


def guest(root, script):
    connection=json.loads((root/'connection.json').read_text())
    machine=json.loads((root.parent/'machine.json').read_text())
    if machine['id']!=connection['machine_uuid']:
        raise ValueError('Wrong VM identity')
    script="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+script
    args=['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',
          base64.b64encode(script.encode('utf-16le')).decode()]
    request={'command':'execute','executable':r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
             'args':args,'timeoutSeconds':45}
    data=json.dumps(request).encode()
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(55);s.connect(str(root.parent/'Control/control.sock'))
        s.sendall(struct.pack('<I',len(data))+data)
        size=struct.unpack('<I',receive_exact(s,4))[0]
        if not 0<size<=1048576: raise ValueError('Invalid control frame')
        reply=json.loads(receive_exact(s,size))
    result=reply.get('result',{})
    if not reply.get('ok') or result.get('exitCode')!=0 or result.get('timedOut'):
        raise ValueError('Windows relay operation failed; inspect private diagnostics')
    return result.get('stdout','')


def connect_relay(root, enabled=True):
    metadata=json.loads((root/'connection.json').read_text())
    expected=metadata['machine_uuid']
    if not enabled:
        guest(root,"Stop-ScheduledTask -TaskName 'PerpendicularHostVPN'")
    path=f'/tmp/perpendicular-{os.getuid()}-{expected[:8]}.sock'
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5);s.connect(path);stream=s.makefile('rwb',buffering=0);stream.readline()
        def qmp(command, arguments=None):
            value={'execute':command}
            if arguments is not None: value['arguments']=arguments
            stream.write(json.dumps(value).encode()+b'\n')
            while True:
                reply=json.loads(stream.readline())
                if 'error' in reply: raise ValueError('QEMU rejected relay setup')
                if 'return' in reply: return reply['return']
        qmp('qmp_capabilities')
        if qmp('query-uuid')['UUID']!=expected: raise ValueError('QEMU identity changed')
        listing=qmp('human-monitor-command',{'command-line':'info usernet'})
        for protocol in ['tcp','udp']:
            # Recognize only an exact forwarding row owned by this runtime.
            rows=[line.split() for line in listing.splitlines() if f'{protocol.upper()}[HOST_FORWARD]' in line]
            matches=[row for row in rows if row[-6:-2]==['127.0.0.1','10884','10.0.2.15','10884']]
            if matches and not enabled:
                result=qmp('human-monitor-command',{'command-line':f'hostfwd_remove net {protocol}:127.0.0.1:10884'})
                if 'not found' in result.lower(): raise ValueError('Owned forwarding rule missing')
            elif not matches and enabled:
                result=qmp('human-monitor-command',{'command-line':f'hostfwd_add net {protocol}:127.0.0.1:10884-10.0.2.15:10884'})
                if result.strip(): raise ValueError('Relay port occupied or forwarding rejected: '+result.strip())
    if enabled: guest(root,"Start-ScheduledTask -TaskName 'PerpendicularHostVPN'")


def targets(values):
    result=[]
    for value in values:
        address=ipaddress.IPv4Address(value)
        if not address.is_private or address.is_loopback or address.is_link_local or address.is_multicast or address.is_unspecified:
            raise ValueError('Use specific private unicast VPN IPv4 addresses')
        result.append(str(address)+'/32')
    if not result:
        raise ValueError('At least one VPN IP is required')
    return sorted(set(result))


def configure(root, values):
    cidrs=targets(values)
    path=root/'client-tun.json'
    data=json.loads(path.read_text())
    inbound=data['inbounds'][0]
    if inbound.get('type')!='tun' or inbound.get('interface_name')!='utun88':
        raise ValueError('Unexpected managed TUN interface')
    inbound['route_address']=cidrs
    temp=root/'client-tun.pending.json'
    temp.write_text(json.dumps(data,indent=2)+'\n');temp.chmod(0o600)
    subprocess.run([str(root/'sing-box'),'check','-c',str(temp)],check=True)
    # Retain the previous config for recovery. This contains a private relay key.
    previous=root/'client-tun.previous.json'
    previous.write_bytes(path.read_bytes());previous.chmod(0o600)
    temp.replace(path)
    return cidrs


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime',type=Path,default=DEFAULT)
    sub=p.add_subparsers(dest='command',required=True)
    sub.add_parser('start');sub.add_parser('stop');sub.add_parser('status')
    c=sub.add_parser('targets');c.add_argument('addresses',nargs='+')
    args=p.parse_args();root=checked_root(args.runtime)
    if args.command=='start':
        if (root/'tun.sock').exists():
            raise ValueError('Already active; use status or stop first')
        subprocess.run([str(root/'sing-box'),'check','-c',str(root/'client-tun.json')],check=True)
        connect_relay(root)
        subprocess.run([str(root/'authorize'),str(root/'supervisor'),str(root)],check=True)
        deadline=time.monotonic()+10
        while not (root/'tun.sock').exists() and time.monotonic()<deadline: time.sleep(.1)
        if not (root/'tun.sock').exists(): raise ValueError('Supervisor did not start; inspect tun.log')
    elif args.command=='stop':
        print(control(root,'stop'))
        deadline=time.monotonic()+10
        while (root/'tun.sock').exists() and time.monotonic()<deadline: time.sleep(.1)
        if (root/'tun.sock').exists(): raise ValueError('TUN is still stopping; relay retained')
        connect_relay(root,enabled=False)
    elif args.command=='targets':
        requested=targets(args.addresses)
        if (root/'tun.sock').exists():
            raise ValueError('Stop before changing targets, then start to activate')
        payload=json.dumps(requested,separators=(',',':'))
        update=r"""$d='C:\ProgramData\Perpendicular\HostVPN';
$c=Get-Content -LiteralPath "$d\server.json" -Raw|ConvertFrom-Json;
$r=@($c.route.rules|Where-Object {$_.outbound -eq 'vpn'});
if($r.Count -ne 1){throw 'Unexpected relay rules'};
$r[0].ip_cidr=@(ConvertFrom-Json '__TARGETS__');
[IO.File]::WriteAllText("$d\server.pending.json",($c|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));
& "$d\sing-box.exe" check -c "$d\server.pending.json";
if($LASTEXITCODE -ne 0){throw 'Relay config invalid'};
Copy-Item -LiteralPath "$d\server.json" -Destination "$d\server.previous.json" -Force;
Move-Item -LiteralPath "$d\server.pending.json" -Destination "$d\server.json" -Force;"""
        guest(root,update.replace('__TARGETS__',payload))
        prepared=configure(root,args.addresses)
        metadata_path=root/'connection.json'
        metadata=json.loads(metadata_path.read_text());metadata['targets']=prepared
        metadata_path.write_text(json.dumps(metadata,indent=2)+'\n');metadata_path.chmod(0o600)
        print('Prepared routes on both sides: '+', '.join(prepared))
    else:
        data=json.loads((root/'client-tun.json').read_text())
        print(json.dumps({'supervisor_socket':(root/'tun.sock').exists(),
                          'targets':data['inbounds'][0]['route_address'],
                          'protocols':['TCP','UDP'],
                          'remote_device_verified':False},indent=2))
        for cidr in data['inbounds'][0]['route_address']:
            subprocess.run(['/sbin/route','-n','get',cidr.split('/')[0]],check=False)


if __name__=='__main__':
    try: main()
    except (OSError,ValueError,subprocess.CalledProcessError) as e:
        print('ERROR: '+str(e),file=sys.stderr);sys.exit(1)
