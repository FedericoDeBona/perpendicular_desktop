#!/usr/bin/env python3
"""Reject stale scanout code and the QA-only failure injection in builds."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    args = parser.parse_args()
    required = json.loads((ROOT / 'graphics/monitor/requirements.json').read_text())
    native = args.app.resolve(strict=True) / 'Contents/Resources/Native3D'
    manifest = json.loads((native / 'runtime.json').read_text())
    if (manifest.get('resource_inventory_candidate') or
            manifest.get('resource_lifetime_metadata_candidate') or
            b'resource_inventory' in (native / 'lib/libvirglrenderer.1.dylib').read_bytes()):
        raise ValueError('QA resource inventory cannot enter an ordinary build')
    binary = (native / 'bin/qemu-system-aarch64').read_bytes()
    candidate = manifest.get('deferred_scanout_selection_candidate', {})
    if candidate.get('qaFaultInjection') or b'QA delaying selection admission' in binary:
        raise ValueError('QA fault injection cannot enter an ordinary build')
    value = manifest.get('deferred_scanout_selection', {})
    if (value.get('version') != required['deferredScanoutSelectionVersion'] or
            value.get('waitMilliseconds') != required['waitMilliseconds']):
        raise ValueError('Local QEMU lacks qualified deferred scanout selection; rebuild/package the compatible local recipe in graphics/monitor/README.md')
    patches = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
               for name in required['requiredPatches']}
    if value.get('patches') != patches:
        raise ValueError('Local scanout recipe differs from the shared fixes')
    if hashlib.sha256(binary).hexdigest() != manifest['files']['bin/qemu-system-aarch64']:
        raise ValueError('Packaged scanout QEMU hash differs')
    if any(marker not in binary for marker in
           (b'perp-native: selection timed out resource=', b'selection_pending',
            b'selection_resumed', b'update_pending')):
        raise ValueError('QEMU lacks bounded selection and retained-update capabilities')
    print('Monitor: bounded selection, retained update, shared patches and QEMU hash verified')


if __name__ == '__main__':
    main()
