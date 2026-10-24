#!/usr/bin/env python3
"""Build one host export hook against the current local Wire2 renderer profile."""
import argparse,hashlib,json,pathlib,shlex,shutil,subprocess
HERE=pathlib.Path(__file__).resolve().parent;REPO=HERE.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--reference',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 ref=a.reference.resolve();q=a.output.resolve();assert not q.exists() and not q.is_relative_to(REPO);q.mkdir(parents=True)
 manifest=json.loads((REPO/'.build/Native3D/runtime.json').read_text());assert manifest['guest_wire_version']==2 and manifest['resource_update_context']==1
 for name,digest in manifest['files'].items():assert sha(REPO/'.build/Native3D'/name)==digest
 # Match the compiled reference to the actually packaged baseline before editing.
 baseline={}
 for built,packed in [('src/libvirglrenderer.1.dylib','lib/libvirglrenderer.1.dylib'),('server/virgl_render_server','bin/virgl_render_server')]:
  def code(path):
   lines=subprocess.check_output(['otool','-s','__TEXT','__text',str(path)],text=True).splitlines()[2:]
   return hashlib.sha256(''.join(''.join(line.split()[1:]) for line in lines).encode()).hexdigest()
  actual=code(ref/'build'/built);assert actual==code(REPO/'.build/Native3D'/packed),('Different compiled baseline',packed)
  baseline[packed]=actual
 for name in ['source','build']:subprocess.run(['cp','-cR',str(ref/name),str(q/name)],check=True)
 def run(name,args,cwd=None):
  (q/(name+'.command.json')).write_text(json.dumps(list(map(str,args)),indent=2)+'\n')
  r=subprocess.run(list(map(str,args)),cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(q/(name+'.log')).write_bytes(r.stdout);assert r.returncode==0,(name,r.stdout.decode(errors='replace')[-1800:])
 source=q/'source/src/neptune/npt_shared.c';before=sha(source)
 s=source.read_text();needle='/* OPEN_RES arrives';assert s.count(needle)==1
 s=s.replace(needle,'#include "perp-wgc-export.inc"\n\n'+needle)
 needle='   hr = npt_shared_export_handle(ctx, blob_id, data_res_id, data_off, handle);';assert s.count(needle)==1
 s=s.replace(needle,'   if (!nt_handle) perp_wgc_export(ctx, blob_id, (const void *)(uintptr_t)handle);\n'+needle)
 source.write_text(s);shutil.copy2(HERE/'export.inc',source.parent/'perp-wgc-export.inc')
 run('diagnostics',['patch','-p1','--forward','--batch','-i',HERE/'timing-diagnostics.patch'],q/'source')
 records=json.loads((ref/'build/compile_commands.json').read_text());objects=[]
 for filename in ['npt_shared.c','snapshot.c','proxy-broker.c']:
  record=next(x for x in records if x['file'].endswith('/'+filename))
  command=[x.replace(str(ref),str(q)) for x in shlex.split(record['command'])]
  run('compile-'+filename,command,q/'build');objects.append(record['output'])
 run('archive',['ar','r','src/libvirgl.a',*objects],q/'build')
 ninja=ref.parent/'venv/bin/ninja'
 for label,target in [('library','src/libvirglrenderer.1.dylib'),('server','server/virgl_render_server')]:
  line=subprocess.check_output([str(ninja),'-C',str(ref/'build'),'-t','commands',target],text=True).splitlines()[-1]
  run('link-'+label,[x.replace(str(ref),str(q)) for x in shlex.split(line)],q/'build')
 runtime=q/'Native3D';shutil.copytree(REPO/'.build/Native3D',runtime,symlinks=True)
 for name,origin in [('lib/libvirglrenderer.1.dylib','src/libvirglrenderer.1.dylib'),('bin/virgl_render_server','server/virgl_render_server')]:
  target=runtime/name;shutil.copy2(q/'build'/origin,target);changes=[]
  for line in subprocess.check_output(['otool','-L',str(target)],text=True).splitlines()[1:]:
   dep=line.strip().split(' (',1)[0]
   if dep.startswith(('/System/','/usr/lib/','@')):continue
   packaged=runtime/'lib'/pathlib.Path(dep).name;assert packaged.exists();changes+=['-change',dep,('@loader_path/../lib/' if name.startswith('bin/') else '@loader_path/')+packaged.name]
  if name.startswith('lib/'):changes+=['-id','@rpath/'+target.name]
  if changes:subprocess.run(['install_name_tool',*changes,str(target)],check=True)
  subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(target)],check=True);subprocess.run(['codesign','--verify','--strict',str(target)],check=True)
  manifest['files'][name]=sha(target)
 manifest['experimental_wgc_gpu_export']=1;(runtime/'runtime.json').write_text(json.dumps(manifest,indent=2)+'\n')
 (q/'receipt.json').write_text(json.dumps({'baselineCodeSHA256':baseline,'sourceBefore':before,'sourceAfter':sha(source),'hook':sha(HERE/'export.inc'),'files':manifest['files'],'runtimeVerified':False},indent=2)+'\n');print(runtime)
if __name__=='__main__':main()
