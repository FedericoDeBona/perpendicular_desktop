#!/usr/bin/env python3
"""Create and attach a private setup CD to the already running local machine."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import argparse

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--graphics-driver-dir',type=Path,help='Stage the pinned ARM64 graphics driver in addition to guest tools')
parser.add_argument('--network-driver-dir',type=Path,help='Stage the pinned ARM64 NetKVM driver for a fresh Windows install')
parser.add_argument('--remove-legacy',action='store_true',help='Stage the explicit one-time removal of previous Perpendicular agents and sharing')
parser.add_argument('--dry-run',action='store_true',help='Verify inputs without creating or attaching a setup CD')
arguments=parser.parse_args()

repo=Path(__file__).resolve().parent.parent
root=Path.home()/'Library/Application Support/Perpendicular Restart'
configuration=json.loads((root/'machine.json').read_text())
executable=repo/'guest/target/aarch64-pc-windows-msvc/release/perpendicular-guest.exe'
sources=[executable,repo/'guest/install.ps1',repo/'guest/install.cmd',repo/'guest/diagnostics.ps1']
if arguments.network_driver_dir or arguments.graphics_driver_dir:
    sources += [repo/'guest/setup-machine.cmd',repo/'guest/setup-machine.ps1']
if arguments.remove_legacy:
    sources += [repo/'guest/remove-legacy.ps1',repo/'guest/remove-legacy.cmd',repo/'guest/inspect-legacy.ps1']
drivers=[]
network_drivers=[]
if arguments.network_driver_dir:
    sources += [repo/'guest/install-network.ps1',repo/'guest/network-driver.json']
    network_manifest=json.loads((repo/'guest/network-driver.json').read_text())
    for name,expected in network_manifest['members'].items():
        path=arguments.network_driver_dir/name
        if path.name != name or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
            raise RuntimeError('Network driver does not match the pinned package: '+name)
        network_drivers.append(path)
if arguments.graphics_driver_dir:
    sources += [repo/'guest/install-graphics.ps1',repo/'guest/install-graphics.cmd',repo/'guest/graphics-driver.json']
    manifest=json.loads((repo/'guest/graphics-driver.json').read_text())
    # The signed UMD and native host must speak the same qualified protocol.
    # Check the final app's runtime before creating media or changing the VM.
    runtime_path=repo/'.build/Perpendicular.app/Contents/Resources/Native3D/runtime.json'
    if not runtime_path.is_file():
        raise RuntimeError('Build the matching Native3D app before preparing its graphics driver.')
    runtime=json.loads(runtime_path.read_text())
    for field,expected in manifest['native_runtime'].items():
        if runtime.get(field)!=expected:
            raise RuntimeError('Graphics driver requires a different packaged Native3D runtime: '+field)
    for name,expected in manifest['members'].items():
        path=arguments.graphics_driver_dir/name
        if path.name != name or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
            raise RuntimeError('Graphics driver does not match the pinned release: '+name)
        drivers.append(path)
digest=hashlib.sha256()
for source in sources:
    digest.update(source.read_bytes())
for source in drivers:
    digest.update(source.read_bytes())
for source in network_drivers:
    digest.update(source.read_bytes())
digest.update(configuration['token'].encode())
if arguments.dry_run:
    print('Setup inputs verified. No CD created or attached.')
    raise SystemExit(0)
setup=root/'Bootstrap'/digest.hexdigest()[:16]
setup.mkdir(parents=True,exist_ok=True,mode=0o700)
for source in sources:
    shutil.copy2(source,setup/source.name)
if drivers:
    (setup/'Graphics').mkdir(exist_ok=True,mode=0o700)
    for source in drivers:
        shutil.copy2(source,setup/'Graphics'/source.name)
if network_drivers:
    (setup/'NetKVM').mkdir(exist_ok=True,mode=0o700)
    for source in network_drivers:
        shutil.copy2(source,setup/'NetKVM'/source.name)
(setup/'connection.json').write_text(json.dumps({'port':configuration['guestPort'],'token':configuration['token']}))
(setup/'connection.json').chmod(0o600)
iso=setup.with_suffix('.iso')
if not iso.exists():
    subprocess.run(['hdiutil','makehybrid','-iso','-joliet','-default-volume-name','PERPSETUP','-o',str(iso),str(setup)],check=True,stdout=subprocess.DEVNULL)
iso.chmod(0o600)
address=f"/tmp/perpendicular-{os.getuid()}-{configuration['id'][:8]}.sock"
with socket.socket(socket.AF_UNIX) as connection:
    connection.settimeout(4)
    connection.connect(address)
    stream=connection.makefile('rwb')
    stream.readline()
    for command,command_args in [('qmp_capabilities',{}),('query-uuid',{}),('blockdev-change-medium',{'device':'bootstrap','filename':str(iso),'format':'raw'})]:
        stream.write((json.dumps({'execute':command,'arguments':command_args})+'\n').encode());stream.flush()
        while True:
            result=json.loads(stream.readline())
            if 'error' in result:
                raise RuntimeError(result['error'])
            if 'return' in result:
                if command == 'query-uuid' and result['return'].get('UUID') != configuration['id']:
                    raise RuntimeError('The running VM does not match the development machine.')
                break
print('Setup CD attached. In the Windows console run D:\\install.cmd and complete installation.')
if arguments.remove_legacy:
    print('For the explicitly requested legacy-agent/sharing cleanup and bridge install, run D:\\remove-legacy.cmd instead.')
if drivers:
    print('For the signed graphics driver, run D:\\install-graphics.cmd. This does not reinstall old guest integrations.')
if drivers or network_drivers:
    print('For the staged drivers and bridge together, run D:\\setup-machine.cmd with normal Windows elevation.')
