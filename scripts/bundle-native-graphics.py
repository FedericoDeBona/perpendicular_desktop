#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bundle one qualified native-graphics profile into a private application copy."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('runtime_helpers',ROOT / 'scripts/bundle-runtime.py')
helpers=importlib.util.module_from_spec(spec);spec.loader.exec_module(helpers)
sha=helpers.digest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--profile',type=Path,required=True)
    parser.add_argument('--qualification',type=Path,required=True)
    args=parser.parse_args()
    app=args.app.resolve();profile=args.profile.resolve()
    if not app.is_relative_to(ROOT) or app.suffix!='.app' or not (app / 'Contents/MacOS/Perpendicular Desktop').is_file():
        raise RuntimeError('Build a private application in this repository first')
    build=json.loads((profile / 'build.json').read_text())
    if not build.get('input_backpressure') or not build.get('hvf_stp_hole_default_off') or not build.get('native_headless_available') or build.get('unsafe_test_keep_context'):
        raise RuntimeError('Normal native headless runtime with input/HVF fixes required')
    binary=Path(build['candidate'])
    if sha(binary)!=build['candidate_sha256']:raise RuntimeError('QEMU candidate changed')
    helpers.verify_candidate(binary)
    proof=json.loads(args.qualification.read_text())
    if proof['result']!='pass' or proof.get('headless_shutdown',{}).get('cocoa_application') is not False or proof['protected_sha256'].get(str(binary))!=sha(binary):
        raise RuntimeError('Exact candidate requires a passing actual headless receiver qualification')
    for path,digest in json.loads((profile / 'protected.json').read_text()).items():
        if sha(Path(path))!=digest:raise RuntimeError('Protected input changed: '+path)
    sync=Path(build['sync_renderer']);plan=json.loads((sync / 'plan.json').read_text())
    if plan['host_transport_version']!=3 or plan['guest_wire_version']!=1:raise RuntimeError('Incompatible renderer transport')
    backend=Path(plan['backend'])
    angle=ROOT / '.tools/graphics-experiment/prefix/ANGLE.xcarchive/Products/usr/local/lib'
    runtime=app / 'Contents/Resources/Native3D'
    if os.path.lexists(runtime):raise RuntimeError('Fresh Native3D output required')
    (runtime / 'bin').mkdir(parents=True);(runtime / 'lib').mkdir()
    seeds={
        'bin/qemu-system-aarch64':binary,
        'bin/virgl_render_server':sync / 'prefix/libexec/virgl_render_server',
        'lib/libvirglrenderer.1.dylib':sync / 'prefix/lib/libvirglrenderer.1.dylib',
        'lib/libdxmt-native.dylib':backend / 'prefix/lib/libdxmt-native.dylib',
        'lib/libEGL.dylib':angle / 'libEGL.dylib',
        'lib/libGLESv2.dylib':angle / 'libGLESv2.dylib',
    }
    libraries={};queue=[];files=[];origins={}
    def copy(source,target,executable):
        source=source.resolve(strict=True)
        helpers.copy_code(source,target);queue.append((source,target,executable));files.append(target)
        origins[str(target.relative_to(runtime))]={'source':str(source),'sha256':sha(source)}
        if not executable:libraries[target.name]=source
    for name,source in seeds.items():copy(source,runtime / name,name.startswith('bin/'))
    while queue:
        source,target,executable=queue.pop(0);changes=[]
        own_id=None
        if not executable:
            identifiers=helpers.run('/usr/bin/otool','-D',str(source)).splitlines()
            own_id=identifiers[1].strip() if len(identifiers)>1 else None
        for dependency in helpers.dependencies(source):
            if dependency==own_id:continue
            if dependency.startswith(('/System/','/usr/lib/')):continue
            name=Path(dependency).name
            if dependency.startswith('@loader_path/'):
                original=source.parent / dependency.removeprefix('@loader_path/')
            elif dependency.startswith('@rpath/'):
                choices=[libraries.get(name),source.parent / name,angle / name]
                original=next((p for p in choices if p and p.is_file()),None)
                if original is None:raise RuntimeError('Unresolved library: '+dependency)
            elif dependency.startswith('@'):raise RuntimeError('Unresolved dependency: '+dependency)
            else:original=Path(dependency)
            original=original.resolve(strict=True)
            if name not in libraries:copy(original,runtime / 'lib' / name,False)
            elif libraries[name]!=original and sha(libraries[name])!=sha(original):
                raise RuntimeError('Library name collision: '+name)
            changes+=['-change',dependency,('@loader_path/../lib/' if executable else '@loader_path/')+name]
        if not executable:changes+=['-id','@rpath/'+target.name]
        if changes:subprocess.run(['/usr/bin/install_name_tool',*changes,str(target)],check=True,capture_output=True)
    for path in files:
        for dep in helpers.dependencies(path):
            if not dep.startswith(('/System/','/usr/lib/','@loader_path/','@rpath/')):raise RuntimeError('Unrelocated dependency: '+dep)
        helpers.clear_finder_metadata(path)
        command=['/usr/bin/codesign','--force','--sign','-','--timestamp=none']
        if path.name=='qemu-system-aarch64':
            command+=['--entitlements',str(Path(build['qemu_profile']) / 'src/qemu/accel/hvf/entitlements.plist')]
        subprocess.run([*command,str(path)],check=True,capture_output=True)
        subprocess.run(['/usr/bin/codesign','--verify','--strict',str(path)],check=True,capture_output=True)
    helpers.verify_candidate(runtime / 'bin/qemu-system-aarch64')
    manifest={'schema':1,'guest_wire_version':1,'host_transport_version':3,'native_descriptor_version':2,
        'input_backpressure':True,'hvf_stp_hole_default_off':True,
        'source_receipt_sha256':sha(profile / 'build.json'),'qualification_sha256':sha(args.qualification),
        'files':{str(p.relative_to(runtime)):sha(p) for p in files}}
    (runtime / 'runtime.json').write_text(json.dumps(manifest,indent=2)+'\n')
    notice=app / 'Contents/Resources/ThirdPartyNotices/Native3D';notice.mkdir(parents=True)
    roots={'QEMU':Path(build['qemu_profile']) / 'src/qemu','Virglrenderer':sync / 'src/virglrenderer',
        'DXMT':backend / 'src/dxmt','ANGLE':ROOT / '.tools/graphics-experiment/src/WebKit/Source/ThirdParty/ANGLE'}
    for name,directory in roots.items():
        destination=notice / name;destination.mkdir()
        for path in directory.iterdir():
            if path.is_file() and path.name.upper().startswith(('COPYING','LICENSE','COPYRIGHT','AUTHORS')):shutil.copyfile(path,destination / path.name)
    for path in [ROOT / 'experimental/input-backpressure/qemu-10.0.12-backpressure.patch',
                 ROOT / 'experimental/hvf-stp-pci-hole/emulate.h',ROOT / 'experimental/hvf-stp-pci-hole/decode.h']:
        shutil.copyfile(path,notice / path.name)
    helpers.collect_notices(list(libraries.values()),notice)
    (notice / 'provenance.json').write_text(json.dumps({'runtime':manifest,'origins':origins,'pins':plan},indent=2)+'\n')
    print(json.dumps({'runtime':str(runtime),'code_files':len(files),'VM_started':False,'installed_app_changed':False}))


if __name__=='__main__':main()
