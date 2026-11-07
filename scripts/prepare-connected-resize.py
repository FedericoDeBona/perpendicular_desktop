#!/usr/bin/env python3
"""Prepare pinned original signed v0.5 media outside Git; never installs it."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request
import zipfile

REPO = Path(__file__).resolve().parent.parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists() or out.is_relative_to(REPO):
        raise ValueError('Use a new output directory outside the repository')
    manifest = json.loads((REPO / 'graphics/driver/connected-resize-v05.json').read_text())
    archives = {}
    for name, pin in [('source', manifest['source']), ('driver', manifest['archive'])]:
        data = urllib.request.urlopen(pin['url'], timeout=60).read()
        expected = pin.get('archive_sha256', pin.get('sha256'))
        if digest(data) != expected:
            raise ValueError(name + ' archive differs from the shared pin')
        archives[name] = data
    with tarfile.open(fileobj=io.BytesIO(archives['source'])) as archive:
        prefix = archive.getmembers()[0].name + '/'
        for name, expected in manifest['source']['files'].items():
            if digest(archive.extractfile(prefix + name).read()) != expected:
                raise ValueError('Connected-mode source differs: ' + name)
    helper = REPO / 'scripts/install-mixed-display-driver.ps1'
    if digest(helper.read_bytes()) != manifest['installer_helper_sha256']:
        raise ValueError('Pinned per-device installer differs')
    # Validate every member before writing any usable media.
    with zipfile.ZipFile(io.BytesIO(archives['driver'])) as archive:
        members = {name: archive.read('drivers/viogpu3d/' + name) for name in manifest['members']}
    for name, data in members.items():
        if digest(data) != manifest['members'][name]:
            raise ValueError('Original signed member differs: ' + name)
    (out / 'Graphics').mkdir(parents=True)
    for name, data in members.items():
        (out / 'Graphics' / name).write_bytes(data)
    for name, data in archives.items():
        (out / (name + '.archive')).write_bytes(data)
    shutil.copy2(helper, out / helper.name)
    shutil.copy2(REPO / 'graphics/driver/install-connected-resize.ps1', out / 'install.ps1')
    (out / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Pinned signed v0.5 and connected-mode source verified; candidate media prepared, Windows unchanged')


if __name__ == '__main__':
    main()
