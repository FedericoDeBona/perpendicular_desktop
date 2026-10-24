#!/usr/bin/env python3
"""Build an already prepared private frontend. Does not start it or Windows."""
import argparse,json,pathlib,shutil,subprocess,plistlib
HERE=pathlib.Path(__file__).resolve().parent;REPO=HERE.parents[1]
def main():
 p=argparse.ArgumentParser();p.add_argument('--prepared',type=pathlib.Path,required=True);p.add_argument('--runtime',type=pathlib.Path,required=True);a=p.parse_args();q=a.prepared.resolve();app=q/'Perpendicular WGC GPU.app'
 assert (q/'overlay.json').exists() and not app.exists() and not q.is_relative_to(REPO)
 subprocess.run(['cp','-cR',str(REPO/'.build/Perpendicular.app'),str(app)],check=True)
 shutil.rmtree(app/'Contents/Resources/Native3D');shutil.copytree(a.runtime,app/'Contents/Resources/Native3D',symlinks=True)
 p=app/'Contents/Info.plist';info=plistlib.loads(p.read_bytes());info.update(CFBundleIdentifier='local.perpendicular.wgc-gpu-trial',CFBundleName='Perpendicular WGC GPU',PerpendicularDesktopOnly=False);p.write_bytes(plistlib.dumps(info))
 (q/'bridge.h').write_text('#include "'+str(REPO/'macos/NativeTransport/ndt.h')+'"\n#include "'+str(HERE/'receiver.h')+'"\n')
 subprocess.run(['xcrun','clang','-target','arm64-apple-macosx14.0','-O2','-c',str(HERE/'receiver.c'),'-o',str(q/'receiver.o')],check=True)
 command=['xcrun','swiftc','-swift-version','6','-O','-parse-as-library','-target','arm64-apple-macosx14.0','-import-objc-header',str(q/'bridge.h'),str(REPO/'.build/native-transport.o'),str(q/'receiver.o'),*[str(p) for p in sorted((q/'macos').glob('*.swift'))],'-o',str(app/'Contents/MacOS/Perpendicular')]
 (q/'frontend-command.json').write_text(json.dumps(command,indent=2)+'\n');result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(q/'frontend-build.log').write_bytes(result.stdout);assert result.returncode==0,'See private frontend-build.log'
 subprocess.run(['codesign','--force','--deep','--sign','-','--timestamp=none',str(app)],check=True);subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True);print(app)
if __name__=='__main__':main()
