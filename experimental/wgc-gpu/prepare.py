#!/usr/bin/env python3
"""Prepare a fresh private WGC GPU experiment. No install, boot or ordinary edits."""
import argparse,hashlib,json,pathlib,shutil,subprocess
HERE=pathlib.Path(__file__).resolve().parent
REPO=HERE.parents[1]
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();q=a.output.resolve()
 assert not q.exists() and not q.is_relative_to(REPO)
 for name,digest in json.loads((HERE/'source-inputs.json').read_text()).items():
  assert hashlib.sha256((REPO/name).read_bytes()).hexdigest()==digest,('Source differs',name)
 q.mkdir(parents=True,mode=0o700)
 subprocess.run(['cp','-cR',str(REPO/'guest'),str(q/'guest')],check=True)
 shutil.copytree(REPO/'macos',q/'macos')
 subprocess.run(['patch','-p1','--forward','--batch','-i',str(HERE/'overlay.patch')],cwd=q,check=True)
 shutil.copy2(HERE/'gpu.rs',q/'guest/src/windows/gpu.rs')
 for name in ['GpuFrames.swift','ExperimentalGpuTrace.swift']:shutil.copy2(HERE/name,q/'macos'/name)
 (q/'overlay.json').write_text(json.dumps({'scope':'single-window WGC GPU; no kernel/UMD replacement','ordinaryModified':False},indent=2)+'\n')
 print(q)
if __name__=='__main__':main()
