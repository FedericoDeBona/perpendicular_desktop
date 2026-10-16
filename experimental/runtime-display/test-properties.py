#!/usr/bin/env python3
"""Read real candidate device/property inventories; does not start a guest."""
import argparse
from pathlib import Path
import subprocess

REPO=Path(__file__).resolve().parents[2]


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--binary',type=Path,required=True)
    binary=parser.parse_args().binary.resolve()
    assert (REPO/'.tools/runtime-display').resolve() in binary.parents
    def run(*arguments):
        result=subprocess.run([str(binary),*arguments],check=True,capture_output=True,text=True,timeout=8)
        return result.stdout+result.stderr
    assert 'version 11.1.2' in run('--version')
    devices=run('-device','help')
    assert '"virtio-ramfb"' in devices
    assert not any(name in devices for name in ['virtio-ramfb-gl','virtio-gpu-gl','virtio-gpu-rutabaga'])
    properties=run('-device','virtio-ramfb,help')
    for name in ['max_outputs=','xres=','yres=','edid=','addr=']:assert name in properties,name
    assert 'ppi=<bool>' in run('-device','tpm-tis-device,help')
    assert b'x-input-test-' not in binary.read_bytes() and b'x-runtime-test-' not in binary.read_bytes()
    print('QEMU11 identity, hybrid2D properties, absent3D devices, retained TPM ppi and absent QA markers PASS')


if __name__=='__main__':main()
