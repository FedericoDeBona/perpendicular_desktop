#!/usr/bin/env python3
"""Stage the exact reviewed package and read-only baseline script; never start a VM."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import zipfile


def prepare(archive: Path, output: Path):
    here = Path(__file__).resolve().parent
    manifest = json.loads((here / 'package.json').read_text())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['archive_sha256']:
        raise ValueError('Reviewed archive SHA-256 mismatch')
    expected = {'drivers/viogpu3d/' + k: v for k, v in manifest['members'].items()}
    with zipfile.ZipFile(archive) as source:
        files = [m for m in source.infolist() if not m.is_dir()]
        if len(files) != len(expected) or {m.filename for m in files} != set(expected):
            raise ValueError('Archive members differ from reviewed package')
        payload = {}
        for member in files:
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode) or member.file_size > 4 * 1024 * 1024:
                raise ValueError('Nonregular or oversized archive member')
            data = source.read(member)
            if hashlib.sha256(data).hexdigest() != expected[member.filename]:
                raise ValueError('Reviewed member hash mismatch: ' + member.filename)
            payload[Path(member.filename).name] = data
    # Exclusive output prevents modifying any earlier prepared trial or mounted disc.
    output.mkdir(mode=0o700)
    drivers = output / 'drivers'
    drivers.mkdir(mode=0o700)
    for name, data in payload.items():
        (drivers / name).write_bytes(data)
    for name in ('package.json', 'Read-Baseline.ps1'):
        shutil.copyfile(here / name, output / name)
    return {'prepared': True, 'members': len(payload), 'output': str(output.resolve()),
            'installed': False, 'vm_started': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('output', type=Path, help='Fresh directory; parent must already exist')
    args = parser.parse_args()
    print(json.dumps(prepare(args.archive, args.output), indent=2))
