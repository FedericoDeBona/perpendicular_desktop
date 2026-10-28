#!/usr/bin/env python3
"""Verify the qualified graphics runtime and package private Samba sharing."""
import argparse,hashlib,json,shutil,subprocess,sys
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]
def prepare(app):
 root=app/'Contents/Resources/Native3D';path=root/'runtime.json';value=json.loads(path.read_text())
 # Remove the retired file-sharing payload from copied older graphics bundles.
 # The qualified QEMU/renderer remain intact; no filesystem device is attached.
 retired=[name for name in value['files'] if name=='bin/macosvirtiofsd' or name.startswith('Notices/virtiofs/')]
 for name in retired:
  file=root/name
  if file.exists():file.unlink()
  del value['files'][name]
 for name in list(value):
  if name.startswith('virtiofs_'):del value[name]
 notices=root/'Notices/virtiofs'
 if notices.exists():shutil.rmtree(notices)
 for name,expected in value['files'].items():
  file=(root/name).resolve()
  if not file.is_relative_to(root.resolve()) or hashlib.sha256(file.read_bytes()).hexdigest()!=expected:raise ValueError('Graphics runtime member differs: '+name)
 if value.get('app_monitor_mode_version')!=1:raise ValueError('The qualified app-monitor graphics runtime is required.')
 path.write_text(json.dumps(value,indent=2)+'\n')
 probe=subprocess.run([str(root/'bin/qemu-system-aarch64'),'-S','-machine','virt,gic-version=3,highmem=off','-accel','hvf','-cpu','host','-m','128','-nodefaults','-display','none','-monitor','none','-serial','none','-qmp','stdio'],input='{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n',text=True,capture_output=True,timeout=15)
 if probe.returncode!=0:raise ValueError('Graphics runtime failed its diskless startup check.')
 subprocess.run([sys.executable,str(REPO/'scripts/package-samba-runtime.py'),'--app',str(app)],check=True)
 guest=app/'Contents/Resources/Guest';shared=guest/'SharedFiles'
 if shared.exists():shutil.rmtree(shared)
 shared.mkdir(parents=True)
 for name in ['install-shared-folders.ps1','configure-shared-folders.ps1','connect-shared-folders.ps1','apply-shared-folders.ps1','retire-shared-files.ps1','configure-smb-cache.ps1']:shutil.copy2(REPO/'guest'/name,shared/name)
 for name in ['virtiofs-drivers.json','install-shared-downloads.ps1','redirect-shared-downloads.ps1']:
  file=guest/name
  if file.exists():file.unlink()
 print('Qualified graphics runtime and private SMB folder integration complete.')
if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--app',type=Path,required=True);prepare(parser.parse_args().app.resolve())
