#!/usr/bin/env python3
"""Compile the existing bounded WGL probe for the fresh-install smoke check."""
import argparse
import os
from pathlib import Path
import subprocess

REPO=Path(__file__).resolve().parents[1]

def build(sdk,output):
    output.mkdir(parents=True,exist_ok=True)
    environment=os.environ.copy();environment['PATH']=str(sdk)+os.pathsep+environment['PATH']
    for arch,target in [('arm64','aarch64')]:
        destination=output/arch;destination.mkdir(exist_ok=True)
        arguments=[str(sdk/'clang-cl'),'--target='+target+'-pc-windows-msvc','-fuse-ld=lld','/nologo','/O2','/MT']
        for directory in ['crt/include','sdk/include/ucrt','sdk/include/shared','sdk/include/um','sdk/include/winrt']:
            arguments+=['/imsvc'+str(sdk/'xwin'/directory)]
        arguments += ['graphics/opengl/probe-wgl-triangle.c','/Fo'+str(destination/'probe.obj'),'/Fe'+str(destination/'OpenGLCheck.exe'),'/link','/timestamp:0','/subsystem:console']
        for directory in ['crt/lib/'+target,'sdk/lib/um/'+target,'sdk/lib/ucrt/'+target]:arguments+=['/libpath:'+str(sdk/'xwin'/directory)]
        arguments+=['user32.lib','gdi32.lib','kernel32.lib']
        subprocess.run(arguments,env=environment,cwd=REPO,check=True)
    print('Existing WGL probe compiled for ARM64; runtime verification remains separate')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--sdk',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args();build(args.sdk.resolve(strict=True),args.output.resolve())
