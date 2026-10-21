#!/usr/bin/env python3
"""Create and attach a private setup CD to the already running local machine."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess

repo=Path(__file__).resolve().parent.parent
root=Path.home()/'Library/Application Support/Perpendicular Restart'
configuration=json.loads((root/'machine.json').read_text())
executable=repo/'guest/target/aarch64-pc-windows-msvc/release/perpendicular-guest.exe'
sources=[executable,repo/'guest/install.ps1',repo/'guest/install.cmd',repo/'guest/diagnostics.ps1']
digest=hashlib.sha256()
for source in sources:
    digest.update(source.read_bytes())
digest.update(configuration['token'].encode())
setup=root/'Bootstrap'/digest.hexdigest()[:16]
setup.mkdir(parents=True,exist_ok=True,mode=0o700)
for source in sources:
    shutil.copy2(source,setup/source.name)
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
    for command,arguments in [('qmp_capabilities',{}),('blockdev-change-medium',{'device':'bootstrap','filename':str(iso),'format':'raw'})]:
        stream.write((json.dumps({'execute':command,'arguments':arguments})+'\n').encode());stream.flush()
        while True:
            result=json.loads(stream.readline())
            if 'error' in result:
                raise RuntimeError(result['error'])
            if 'return' in result:
                break
print('Setup CD attached. In the Windows console run D:\\install.cmd and complete installation.')
