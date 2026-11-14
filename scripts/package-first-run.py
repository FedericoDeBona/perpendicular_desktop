#!/usr/bin/env python3
"""Package verified fresh-install dependencies. No VM state or local paths are shipped."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

REPO = Path(__file__).resolve().parents[1]

def sha(data):
    return hashlib.sha256(data).hexdigest()

def copy_members(source, target, members):
    for name, expected in members.items():
        file = source/name
        if sha(file.read_bytes()) != expected:
            raise ValueError('First-run dependency differs from shared pin: '+name)
    for name in members:
        file = target/name
        file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source/name, file)

def package(app, graphics, network, memory, probes):
    for check in ['cpu-idle-runtime','monitor-runtime','memory-runtime','opengl-payload','x86-payload','video-payload','connected-resize']:
        subprocess.run(['python3',str(REPO/'scripts'/('check-'+check+'.py')),'--app',str(app)],check=True)
    out=app/'Contents/Resources/FirstRun'
    if out.exists():
        raise ValueError('FirstRun already exists; build a new package instead of merging stale files')
    pin=json.loads((REPO/'installer/requirements.json').read_text())
    cache=Path.home()/'.local/share/perpendicular-installer-inputs'
    cache.mkdir(parents=True,exist_ok=True)
    archive=cache/'qemu-efi-aarch64_2025.02-8+deb13u1_all.deb'
    if not archive.exists():
        data=urllib.request.urlopen(pin['firmware']['url'],timeout=60).read()
        if sha(data)!=pin['firmware']['sha256']:raise ValueError('Firmware download differs')
        archive.write_bytes(data)
    if sha(archive.read_bytes())!=pin['firmware']['sha256']:raise ValueError('Firmware package differs')
    with tempfile.TemporaryDirectory(prefix='perpendicular-firmware-') as temporary:
        subprocess.run(['ar','-x',str(archive)],cwd=temporary,check=True)
        with tarfile.open(Path(temporary)/'data.tar.xz') as tar:
            firmware={name:tar.extractfile('./'+pin['firmware'][name]).read() for name in ['code','variables','license']}
    # All inputs are validated before a first-run payload becomes usable.
    inputs=[(graphics,'Graphics','guest/graphics-driver.json'),(network,'NetKVM','guest/network-driver.json'),(memory,'Memory','guest/memory-drivers.json')]
    for source,_,manifest in inputs:
        for name,expected in json.loads((REPO/manifest).read_text())['members'].items():
            if sha((source/name).read_bytes())!=expected:raise ValueError('Input differs: '+name)
    probe=probes/'arm64/OpenGLCheck.exe'
    data=probe.read_bytes()
    import struct
    pe=struct.unpack_from('<I',data,0x3c)[0]
    if data[pe:pe+4]!=b'PE\0\0' or struct.unpack_from('<H',data,pe+4)[0]!=0xaa64:raise ValueError('Expected the ARM64 WGL probe built from shared source')
    out.mkdir()
    (out/'Probes/arm64').mkdir(parents=True)
    shutil.copy2(probe,out/'Probes/arm64/OpenGLCheck.exe')
    for name in ['code','variables']:(out/(name+'.fd.gz')).write_bytes(gzip.compress(firmware[name],mtime=0))
    (out/'Firmware-LICENSE.txt').write_bytes(firmware['license'])
    for source,folder,manifest in inputs:
        copy_members(source,out/folder,json.loads((REPO/manifest).read_text())['members'])
        shutil.copy2(REPO/manifest,out/Path(manifest).name)
    for name in ['install-graphics.ps1','install-network.ps1','install-memory.ps1']:
        shutil.copy2(REPO/'guest'/name,out/name)
    for file in (REPO/'installer').glob('*.ps1'):shutil.copy2(file,out/file.name)
    shutil.copy2(REPO/'installer/requirements.json',out/'requirements.json')
    manifest={'schema':1,'firmware':{n:sha(d) for n,d in firmware.items()},'files':{str(f.relative_to(out)):sha(f.read_bytes()) for f in sorted(out.rglob('*')) if f.is_file()}}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('First-run firmware and signed driver payload verified and packaged. No private VM input copied.')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['app','graphics','network','memory','probes']:p.add_argument('--'+name,type=Path,required=True)
    a=p.parse_args();package(a.app.resolve(strict=True),a.graphics.resolve(strict=True),a.network.resolve(strict=True),a.memory.resolve(strict=True),a.probes.resolve(strict=True))
