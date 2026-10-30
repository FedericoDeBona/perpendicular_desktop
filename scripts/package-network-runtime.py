#!/usr/bin/env python3
"""Package pinned VPN relay payload and fixed authorization helpers, outside Git."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / 'addons/linkmanager-arm64/host-vpn'
spec = importlib.util.spec_from_file_location('network_prepare', SOURCE / 'prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    a = p.parse_args()
    cache = Path.home() / '.local/share/perpendicular-dependencies/network' / prepare.VERSION
    cache.mkdir(parents=True, exist_ok=True)
    output = a.app / 'Contents/Resources/Network'
    output.mkdir(parents=True, exist_ok=True)
    pins = {}
    for platform in prepare.PINS:
        name = 'sing-box.exe' if platform.startswith('windows') else 'sing-box'
        file = cache / name
        expected = prepare.PINS[platform][2]
        if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            prepare.fetch(cache, platform)
        if hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            raise ValueError('Network payload hash mismatch')
        shutil.copy2(file, output / name)
        pins[name] = expected
    for name, framework in [('authorize', ['-framework', 'Security']), ('supervisor', [])]:
        subprocess.run(['xcrun', 'clang', '-O2', '-target', 'arm64-apple-macosx14.0', '-Wno-deprecated-declarations', str(SOURCE / (name + '.c')),
                        *framework, '-o', str(output / name)], check=True)
        pins[name] = hashlib.sha256((output / name).read_bytes()).hexdigest()
    shutil.copy2(SOURCE / 'install-relay.ps1', output / 'install-relay.ps1')
    pins['install-relay.ps1'] = hashlib.sha256((output / 'install-relay.ps1').read_bytes()).hexdigest()
    (output / 'requirements.json').write_text(json.dumps({'schema': 1, 'version': prepare.VERSION, 'files': pins}, indent=2) + '\n')
    (output / 'SOURCE.txt').write_text('sing-box ' + prepare.VERSION + '\nGPL-3.0-or-later\nhttps://github.com/SagerNet/sing-box/tree/v' + prepare.VERSION + '\nhttps://github.com/SagerNet/sing-box/blob/v' + prepare.VERSION + '/LICENSE\n')
    for name, expected in pins.items():
        if hashlib.sha256((output / name).read_bytes()).hexdigest() != expected:
            raise ValueError('Incomplete network payload: ' + name)
    print('Pinned network payload and authorization helpers packaged.')


if __name__ == '__main__':
    main()
