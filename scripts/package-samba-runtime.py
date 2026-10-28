#!/usr/bin/env python3
"""Package pinned Samba and its libraries; no system service or Homebrew needed."""
import argparse,hashlib,json,os,shutil,subprocess,tarfile,urllib.request,urllib.error
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]
CACHE=Path.home()/'.local/share/perpendicular-samba'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def package(app):
 spec=json.loads((REPO/'guest/samba-runtime.json').read_text());CACHE.mkdir(parents=True,exist_ok=True)
 out=app/'Contents/Resources/Samba'
 if out.exists():shutil.rmtree(out)
 out.mkdir(parents=True)
 notices=out/'Notices';notices.mkdir()
 for item in spec['bottles']:
  name=item['formula'];archive=CACHE/(name+'-'+item['sha256'][:12]+'.tar.gz')
  if not archive.exists():
   repo='homebrew/core/'+name.replace('@','/')
   token=json.load(urllib.request.urlopen('https://ghcr.io/token?service=ghcr.io&scope=repository:'+repo+':pull'))['token']
   response=urllib.request.urlopen(urllib.request.Request(item['url'],headers={'Authorization':'Bearer '+token}))
   temporary=archive.with_suffix('.part');temporary.write_bytes(response.read());temporary.replace(archive)
  if digest(archive)!=item['sha256']:raise ValueError('Different Samba dependency: '+name)
  extracted=CACHE/'bottles'/name
  if not extracted.exists():
   extracted.mkdir(parents=True)
   with tarfile.open(archive) as tar:
    for member in tar.getmembers():
     path=Path(member.name)
     if path.is_absolute() or '..' in path.parts:raise ValueError('Unsafe package member')
    tar.extractall(extracted)
  for root in extracted.glob('*/*'):
   if (root/'lib').is_dir():
    for path in (root/'lib').rglob('*'):
     if path.is_dir() or not (path.name.endswith(('.dylib','.so')) or '.dylib.' in path.name or '.so.' in path.name):continue
     target=out/'lib'/path.relative_to(root/'lib');target.parent.mkdir(parents=True,exist_ok=True)
     if target.exists() or target.is_symlink():continue
     if path.is_symlink():
      link=os.readlink(path)
      if Path(link).is_absolute():raise ValueError('External library alias')
      os.symlink(link,target)
     else:shutil.copy2(path,target)
   if name=='samba':
    for directory in ['sbin','bin','libexec']:
     for binary in ['samba-dot-org-smbd','samba-dcerpcd']:
      path=root/directory/binary
      if path.is_file():
       target=out/'bin'/binary;target.parent.mkdir(exist_ok=True);shutil.copy2(path,target)
   for filename in ['COPYING','LICENSE','COPYRIGHT']:
    path=root/filename
    if path.is_file():shutil.copy2(path,notices/(name+'-'+filename))
 lookup={p.name:p for p in out.rglob('*') if p.is_file()}
 binaries=[p for p in out.rglob('*') if p.is_file() and not p.is_symlink() and p.read_bytes()[:4] in [b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe']]
 for path in binaries:
  changes=[]
  for line in subprocess.check_output(['otool','-L',str(path)],text=True).splitlines()[1:]:
   dependency=line.strip().split(' (')[0]
   if dependency.startswith(('/usr/lib/','/System/')):continue
   target=lookup.get(Path(dependency).name)
   if target is None:raise ValueError('Missing library '+dependency)
   changes+=['-change',dependency,'@loader_path/'+os.path.relpath(target,path.parent)]
  if changes:subprocess.run(['install_name_tool',*changes,str(path)],check=True,capture_output=True)
  subprocess.run(['codesign','--force','--sign','-',str(path)],check=True,capture_output=True)
 for path in out.rglob('*'):
  if path.is_symlink() and not path.resolve().is_relative_to(out.resolve()):raise ValueError('Library alias outside runtime')
 shutil.copy2(REPO/'guest/samba-runtime.json',notices/'sources.json')
 (notices/'README.txt').write_text('Samba: https://www.samba.org/ — GPL-3.0-or-later.\nPinned official Homebrew bottles, upstream source URLs, checksums and dependency licenses are recorded in sources.json. Libraries are relocated; no host service is installed.\n')
 files={str(p.relative_to(out)):digest(p) for p in out.rglob('*') if p.is_file() and not p.is_symlink()}
 (out/'runtime.json').write_text(json.dumps({'schema':1,'version':spec['version'],'files':files},indent=2)+'\n')
 subprocess.run([str(out/'bin/samba-dot-org-smbd'),'--version'],check=True)
 print('Authenticated private Samba runtime packaged.')
if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--app',type=Path,required=True);package(parser.parse_args().app.resolve())
