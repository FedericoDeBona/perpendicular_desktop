#!/usr/bin/env python3
"""Reject a 2D candidate whose binary/recipe provenance is missing or stale.

Production has no new 2D minimum: this is an opt-in QA experiment, default off.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
args = parser.parse_args()
native = args.app.resolve(strict=True) / 'Contents/Resources/Native3D'
manifest = json.loads((native / 'runtime.json').read_text())
binary = (native / 'bin/qemu-system-aarch64').read_bytes()
metadata = manifest.get('transfer_2d_candidate')
if metadata or b'perp-2d-stats\0' in binary:
    shared = json.loads((ROOT / 'graphics/qemu/transfer-2d.json').read_text())
    if not metadata or any(metadata.get(k) != shared[k]
                           for k in ('recipe', 'sourceBefore', 'capability')):
        raise ValueError('2D candidate lacks the pinned shared recipe')
    for name, expected in shared['recipe'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise ValueError('Shared 2D recipe changed: ' + name)
    if hashlib.sha256(binary).hexdigest() != manifest['files']['bin/qemu-system-aarch64']:
        raise ValueError('2D QEMU differs from its packaged hash')
    if b'perp-2d-stats\0' not in binary or b'perp-2d-cursor\0' not in binary:
        raise ValueError('2D capability missing from the actual QEMU')
    receipt = json.loads((native / 'Notices/Perpendicular/transfer-2d-build.json').read_text())
    if receipt.get('transfer2D') != metadata:
        raise ValueError('2D build receipt differs from the manifest')
    print('2D candidate: pinned recipe, packaged QEMU and build receipt verified; default off')
else:
    print('2D: production reference preserved; no candidate claimed')
