#!/usr/bin/env python3
"""Package a pinned Win32 UMD into a separate app; never changes Windows."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil

REPO = Path(__file__).resolve().parent.parent


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--umd', type=Path, required=True)
    p.add_argument('--release-manifest', type=Path, required=True)
    a = p.parse_args()
    app = a.app.resolve(strict=True)
    if app == Path('/Applications/Perpendicular.app'):
        raise ValueError('Package and verify a separate app before deployment')
    release = json.loads(a.release_manifest.read_text())
    files = {'neptune_umd_x86.dll': a.umd.resolve(strict=True),
             'install.ps1': REPO / 'graphics/driver/install-x86-candidate.ps1'}
    if set(release['files']) != set(files):
        raise ValueError('Unexpected Win32 payload members')
    for name, file in files.items():
        if hashlib.sha256(file.read_bytes()).hexdigest() != release['files'][name]:
            raise ValueError('Input differs from the pinned release: ' + name)
    target = app / 'Contents/Resources/Guest/X86Graphics'
    if target.exists():
        raise ValueError('Use a separate app with no existing Win32 payload')
    target.mkdir(parents=True)
    for name, file in files.items():
        shutil.copyfile(file, target / name)
    (target / 'release.json').write_text(json.dumps(release, indent=2) + '\n')
    spec = importlib.util.spec_from_file_location('x86_check', REPO / 'scripts/check-x86-payload.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.check(app)
    print('Packaged the shared Win32 graphics fix; Windows and host runtime unchanged')


if __name__ == '__main__':
    main()
