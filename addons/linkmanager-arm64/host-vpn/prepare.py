#!/usr/bin/env python3
"""Prepare the pinned private relay package; no VM, route or root changes."""
import argparse
import base64
import concurrent.futures
import hashlib
import json
from pathlib import Path
import secrets
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

VERSION='1.14.4'
PINS={
 'darwin-arm64':('tar.gz','0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838','6546126c1759683fe85798da92409215d53c50e0f2b346b4f74a61babc8dbec2'),
 'windows-arm64':('zip','8cd0a4d0cd8cd480be5731ac31f17038969a42d12add9feb6e031fd43d85bbae','fa52dcb75bdc08e864927e260baad31a4d62668f0af40725d7a5e5aac37dfb92')}
ROOT=Path(__file__).resolve().parent


def fetch(root, platform):
    extension,archive_hash,binary_hash=PINS[platform]
    name=f'sing-box-{VERSION}-{platform}.{extension}'
    archive=root/name
    url=f'https://github.com/SagerNet/sing-box/releases/download/v{VERSION}/{name}'
    archive.write_bytes(urllib.request.urlopen(url,timeout=60).read())
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=archive_hash:
        raise ValueError('Archive SHA256 mismatch')
    binary='sing-box.exe' if platform.startswith('windows') else 'sing-box'
    if extension=='zip':
        with zipfile.ZipFile(archive) as z:
            data=z.read(f'sing-box-{VERSION}-{platform}/{binary}')
    else:
        with tarfile.open(archive) as z:
            data=z.extractfile(f'sing-box-{VERSION}-{platform}/{binary}').read()
    if hashlib.sha256(data).hexdigest()!=binary_hash:
        raise ValueError('Binary SHA256 mismatch')
    target=root/binary;target.write_bytes(data);target.chmod(0o700)
    return {'platform':platform,'version':VERSION,'url':url,'archive_sha256':archive_hash,'binary_sha256':binary_hash}


def configs(key, addresses):
    # Both sides use the same explicit /32 destinations. No default route.
    from host_vpn import targets
    cidrs=targets(addresses)
    method={'type':'shadowsocks','method':'2022-blake3-aes-256-gcm','password':key}
    server={'log':{'level':'warn','timestamp':True},
            'inbounds':[dict(method,tag='host-in',listen='10.0.2.15',listen_port=10884,
                             multiplex={'enabled':True})],
            'outbounds':[{'type':'direct','tag':'vpn','bind_interface':'LinkManager Adapter'}],
            'route':{'rules':[{'ip_cidr':cidrs,'action':'route','outbound':'vpn'},{'action':'reject'}]}}
    client={'log':{'level':'warn','timestamp':True},
            'inbounds':[{'type':'tun','tag':'vpn-tun','interface_name':'utun88',
                         'address':['198.18.88.1/30'],'mtu':1400,'auto_route':True,
                         'route_address':cidrs,'dns_mode':'disabled','stack':'gvisor'}],
            # A browser opens several flows at once. Keep one local transport
            # connection so QEMU host forwarding is not hit by an accept burst.
            'outbounds':[dict(method,tag='windows-vpn',server='127.0.0.1',server_port=10884,
                              multiplex={'enabled':True,'protocol':'smux','max_connections':1})],
            'route':{'final':'windows-vpn'}}
    return server,client


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime',type=Path,required=True)
    p.add_argument('--delivery',type=Path,required=True)
    p.add_argument('--machine-uuid',required=True)
    p.add_argument('--target',action='append',required=True)
    a=p.parse_args()
    repo=ROOT.parents[2]
    for path in [a.runtime,a.delivery]:
        if path.exists() or path.resolve().is_relative_to(repo):
            raise ValueError('Choose new output directories outside repository')
    # Validate before downloads/outputs.
    key=base64.b64encode(secrets.token_bytes(32)).decode()
    server,client=configs(key,a.target)
    a.runtime.mkdir(parents=True,mode=0o700)
    a.delivery.mkdir(parents=True,mode=0o700)
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        pins=list(pool.map(lambda platform:fetch(a.runtime,platform),PINS))
    for name,value in [('server.json',server),('client-tun.json',client),
                       ('connection.json',{'targets':client['inbounds'][0]['route_address'],
                                           'machine_uuid':a.machine_uuid,'guest_ip':'10.0.2.15',
                                           'host_port':10884,'guest_port':10884})]:
        target=a.runtime/name;target.write_text(json.dumps(value,indent=2)+'\n');target.chmod(0o600)
    (a.runtime/'pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    for name in ['sing-box.exe','server.json']:
        shutil.copy2(a.runtime/name,a.delivery/name)
    shutil.copy2(ROOT/'install-relay.ps1',a.delivery/'install-relay.ps1')
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations',str(ROOT/'authorize.c'),
                    '-framework','Security','-o',str(a.runtime/'authorize')],check=True)
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations',str(ROOT/'supervisor.c'),
                    '-o',str(a.runtime/'supervisor')],check=True)
    subprocess.run([str(a.runtime/'sing-box'),'check','-c',str(a.runtime/'client-tun.json')],check=True)
    print('Prepared private runtime and Windows delivery. No key printed.')


if __name__=='__main__':
    main()
