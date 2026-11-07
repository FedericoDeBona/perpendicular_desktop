#!/usr/bin/env python3
"""Private read-only QA inventory; output is never admitted by production gates."""
import json,hashlib,subprocess,shlex,shutil,runpy
from pathlib import Path
import argparse
parser=argparse.ArgumentParser(description="Rebuild the exact renderer baseline, then add read-only QA resource ownership.")
parser.add_argument('--reference',type=Path,required=True,help='Compatible host-source/host-build/venv root')
parser.add_argument('--runtime',type=Path,required=True,help='Qualified Native3D directory, never modified')
parser.add_argument('--output',type=Path,required=True,help='Fresh private output, no app or VM is modified')
args=parser.parse_args()
repo=Path(__file__).resolve().parents[1];root=args.reference.resolve(strict=True);build=root/'host-build';source=root/'host-source';out=args.output.resolve()
if out.exists() or out.is_relative_to(repo):raise ValueError('Fresh private output outside repository required')
pins={
 'host-source/src/perp-sync/proxy-broker.c':'801066f5f5cb50aef4d42c6af8cd67f7537e7d16d5547224452ee1ccc50fe6d4',
 'host-build/src/libvirgl.a':'dbc60c171ed22fd13f46dc791ba1ea39a151c1e09bf1972ca29ae6462bc6700b',
 'host-build/compile_commands.json':'c3da71f5a5c1ed15ddfbe7202294112c6e3dd501e291b002d65e8bc95a033303',
 'host-build/build.ninja':'5ff3219ff7d9d6cf9c1a10940296a1e7bf6d9c2f1dd0c65d7fe0231a11be9494'}
for name,sha in pins.items():
 if hashlib.sha256((root/name).read_bytes()).hexdigest()!=sha:raise ValueError('Different compatible baseline: '+name)
actual=args.runtime.resolve(strict=True)
manifest=json.loads((actual/'runtime.json').read_text())
for name,sha in manifest['files'].items():
 if Path(name).is_absolute() or '..' in Path(name).parts or hashlib.sha256((actual/name).read_bytes()).hexdigest()!=sha:raise ValueError('Runtime mismatch: '+name)
out.mkdir(parents=True)
sec=runpy.run_path(str(repo/'scripts/rebuild-hvf-erridr.py'))['sections'];digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for a,b in [('src/libvirglrenderer.1.dylib','lib/libvirglrenderer.1.dylib'),('server/virgl_render_server','bin/virgl_render_server')]:assert sec(build/a)==sec(actual/b),(a,'different code')
records=json.loads((build/'compile_commands.json').read_text());row=next(r for r in records if r['file'].endswith('proxy-broker.c'))
cmd=shlex.split(row['command']);original=source/'src/perp-sync/proxy-broker.c';base=original.read_text();(out/'baseline-source.c').write_text(base)
receipt={'inputs':{str(p):digest(p) for p in [original,build/'src/libvirgl.a',build/'compile_commands.json',build/'build.ninja']},'baselineSectionsEqualActual':True,'variants':{}}
recipes={}
for name,target in [('library','src/libvirglrenderer.1.dylib'),('server','server/virgl_render_server')]:recipes[name]=shlex.split(subprocess.check_output([str(root/'venv/bin/ninja'),'-C',str(build),'-t','commands',target],text=True).splitlines()[-1])
# Apply only the shared diagnostic to a private source copy.
patch=repo/'graphics/renderer/resource-inventory.patch'
patched_root=out/'patched';target=patched_root/'src/perp-sync/proxy-broker.c';target.parent.mkdir(parents=True);target.write_text(base)
subprocess.run(['patch','-p1','--batch','--forward','-i',str(patch)],cwd=patched_root,check=True)
patched=target.read_text()
receipt['patchSHA256']=digest(patch)
assert patched!=base
for variant,code in [('baseline',base),('diagnostic',patched)]:
 work=out/variant;work.mkdir();src=work/'proxy-broker.c';src.write_text(code);obj=work/'perp-sync_proxy-broker.c.o';args=list(cmd)
 args[1:1]=['-iquote',str(source/'src/perp-sync')]
 for f,v in [('-c',src),('-o',obj),('-MF',str(obj)+'.d'),('-MQ',obj)]:args[args.index(f)+1]=str(v)
 subprocess.run(args,cwd=build,check=True);archive=work/'libvirgl.a';shutil.copy2(build/'src/libvirgl.a',archive);subprocess.run(['ar','-r',str(archive),str(obj)],check=True)
 outputs={}
 for name,recipe in recipes.items():
  args=list(recipe);output=work/('libvirglrenderer.1.dylib' if name=='library' else 'virgl_render_server');args[args.index('-o')+1]=str(output);args=[str(archive) if a=='src/libvirgl.a' else a for a in args];subprocess.run(args,cwd=build,check=True)
  original_binary=build/('src/libvirglrenderer.1.dylib' if name=='library' else 'server/virgl_render_server')
  if variant=='baseline':assert sec(output)==sec(original_binary),(name,'baseline rebuild differs')
  outputs[name]={'sha256':digest(output),'sections':sec(output)}
 receipt['variants'][variant]=outputs
(out/'receipt.json').write_text(json.dumps(receipt,indent=2));print('Baseline code/data replay exact; diagnostic pair built, no app or VM changed.')
