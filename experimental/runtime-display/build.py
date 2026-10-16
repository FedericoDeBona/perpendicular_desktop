#!/usr/bin/env python3
"""Reproduce the isolated QEMU11 2D/input candidate; no install or live changes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
PRIVATE=REPO/'.tools/runtime-display'
ARCHIVE_SHA='731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016'


def digest(path):
    result=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):result.update(chunk)
    return result.hexdigest()


def relative(path):return str(path.resolve().relative_to(REPO))


def prepare_candidate(build, destination):
    candidate=destination/'qemu-system-aarch64'
    destination.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(build/'qemu-system-aarch64',candidate);candidate.chmod(0o755)
    # Meson's uninstalled Slirp dependency is loader-relative. Copy only this
    # private build dependency and normalize IDs before signing. No install.
    source=build/'subprojects/slirp/libslirp.0.dylib'
    dependencies=subprocess.check_output(['otool','-L',str(candidate)],text=True)
    if '@rpath/libslirp.0.dylib' in dependencies:
        library=destination/'lib/libslirp.0.dylib';library.parent.mkdir(exist_ok=True)
        shutil.copyfile(source,library);library.chmod(0o755)
        subprocess.run(['install_name_tool','-id',str(library.resolve()),str(library)],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--sign','-',str(library)],check=True,capture_output=True)
        subprocess.run(['install_name_tool','-change','@rpath/libslirp.0.dylib',str(library.resolve()),str(candidate)],check=True,capture_output=True)
    remaining=subprocess.check_output(['otool','-L',str(candidate)],text=True).splitlines()[1:]
    if any(line.strip().startswith('@') for line in remaining):raise RuntimeError('Unresolved private candidate dependency')
    subprocess.run(['codesign','--force','--sign','-','--entitlements',str(HERE/'Hypervisor.entitlements'),str(candidate)],check=True,capture_output=True)
    return candidate


def provenance(candidate,source,build,arguments,qa=False,validation=None):
    pins=json.loads((HERE/'source-pins.json').read_text())
    data=candidate.read_bytes()
    probes=b'x-input-test-' in data or b'x-runtime-test-' in data
    assert probes==qa
    assert data[:8]==bytes.fromhex('cffaedfe0c000001')
    subprocess.run(['codesign','--verify','--strict',str(candidate)],check=True,capture_output=True)
    result=subprocess.run(['codesign','-d','--entitlements','-','--xml',str(candidate)],check=True,capture_output=True)
    entitlements=plistlib.loads(result.stdout)
    assert entitlements=={'com.apple.security.hypervisor':True},entitlements
    report={'schema':1,'qemu_version':'11.1.2',
            'upstream_archive':{'path':'.tools/downloads/qemu-11.1.2.tar.xz','sha256':ARCHIVE_SHA},
            'utm_source':{'repository':'https://github.com/utmapp/qemu.git','revision':pins['utm_revision'],'files_sha256':pins['utm_files']},
            'production_patches':[{'path':relative(HERE/name),'sha256':digest(HERE/name)} for name in ['hybrid-2d.patch','hid-backpressure.patch']],
            'qa_patch':{'path':relative(HERE/'qtest-probe.patch'),'sha256':digest(HERE/'qtest-probe.patch'),'excluded_from_candidate':not qa},
            'candidate':{'path':relative(candidate),'sha256':digest(candidate),'qa_probe_present':probes,'code_signature_verified':True,'hypervisor_entitlement':True},
            'build':{'source_path':relative(source),'build_path':relative(build),'configure_arguments':arguments,'jobs':2,'target':'qemu-system-aarch64','install_ran':False,'dependency_environment':['Homebrew glib/pixman/libusb/gnutls','repository .tools/build-venv (Meson/Ninja/Python)'],'private_dependencies':[{'path':relative(path),'sha256':digest(path),'component':'Slirp (archive subproject)'} for path in sorted((candidate.parent/'lib').glob('*.dylib'))],'gl_virgl_rutabaga_enabled':False},
            'notices':[{'path':relative(HERE/name),'license':license} for name,license in [('ATTRIBUTION.md','QEMU GPL-2.0; UTM wrapper GPL-2.0-or-later; retained per-file notices'),('COPYING.GPL-2.0','GPL-2.0'),('QEMU-LICENSE','Upstream QEMU license explanation'),('Slirp-COPYRIGHT','Retained Slirp BSD/MIT notices'),('source-pins.json','Corresponding-source identity metadata'),('README.md','Corresponding-source build instructions'),('build.py','Corresponding-source reproducible build script'),('Hypervisor.entitlements','Corresponding-source build configuration')]],
            'validation':validation or {'Windows_guest_acceptance':'not_run','qtest':'run the separately documented tests'}}
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--qa',action='store_true',help='Separate test binary with qtest-only probes; never bundle')
    parser.add_argument('--jobs',type=int,choices=(1,2),default=2)
    args=parser.parse_args();output=args.output.resolve()
    if PRIVATE.resolve() not in output.parents or output.exists():raise SystemExit('Output must be a fresh directory under .tools/runtime-display')
    archive=REPO/'.tools/downloads/qemu-11.1.2.tar.xz'
    if digest(archive)!=ARCHIVE_SHA:raise SystemExit('Pinned QEMU11 archive mismatch')
    output.mkdir(parents=True);source=output/'source';source.mkdir();build=output/'build';build.mkdir()
    subprocess.run(['tar','-xf',str(archive),'-C',str(source),'--strip-components','1'],check=True)
    pins=json.loads((HERE/'source-pins.json').read_text())
    for name,expected in pins['files'].items():
        path=source/name
        if (expected is None and path.exists()) or (expected is not None and digest(path)!=expected):raise SystemExit('Unpatched source mismatch: '+name)
    for name in ['hybrid-2d.patch','hid-backpressure.patch']:
        subprocess.run(['patch','--batch','-p1','-i',str(HERE/name)],cwd=source,check=True)
    for name,expected in pins['patched_files'].items():
        if digest(source/name)!=expected:raise SystemExit('Production source mismatch: '+name)
    if args.qa:
        for name,expected in pins['qa_files'].items():
            if digest(source/name)!=expected:raise SystemExit('QA base source mismatch: '+name)
        subprocess.run(['patch','--batch','-p1','-i',str(HERE/'qtest-probe.patch')],cwd=source,check=True)
        for name,expected in pins['qa_patched_files'].items():
            if digest(source/name)!=expected:raise SystemExit('QA source mismatch: '+name)
    environment=os.environ.copy()
    # Honor the caller's developer selection. Forcing full Xcode breaks an
    # otherwise working Command Line Tools build and can hit an unrelated EULA.
    environment['PATH']=str(REPO/'.tools/build-venv/bin')+':/opt/homebrew/bin:'+environment.get('PATH','')
    environment.pop('PKG_CONFIG_PATH',None);environment.pop('PYTHONPATH',None)
    arguments=['--prefix='+str(output/'unused-prefix'),'--target-list=aarch64-softmmu','--python='+str(REPO/'.tools/build-venv/bin/python'),'--enable-hvf','--enable-vnc','--enable-slirp','--enable-tpm','--enable-tools','--disable-docs','--disable-werror','--disable-gtk','--disable-sdl','--disable-cocoa','--disable-rust','--disable-vnc-jpeg','--disable-vnc-sasl','--disable-slirp-smbd','--disable-pvg','--disable-opengl','--disable-virglrenderer','--disable-rutabaga-gfx']
    with (output/'configure.log').open('wb') as log:subprocess.run([str(source/'configure')]+arguments,cwd=build,env=environment,stdout=log,stderr=subprocess.STDOUT,check=True)
    with (output/'build.log').open('wb') as log:subprocess.run(['ninja','-j'+str(args.jobs),'qemu-system-aarch64'],cwd=build,env=environment,stdout=log,stderr=subprocess.STDOUT,check=True)
    candidate=prepare_candidate(build,output/'candidate')
    report=provenance(candidate,source,build,arguments,args.qa)
    report['build']['jobs']=args.jobs
    report['build']['toolchain_environment']={name:environment.get(name) for name in
        ('DEVELOPER_DIR','SDKROOT','CC','CXX','OBJC','MACOSX_DEPLOYMENT_TARGET')}
    (output/'provenance.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['candidate'],indent=2))
    print('Private source/build/candidate only; no install, firmware, media or VM change.')


if __name__=='__main__':main()
