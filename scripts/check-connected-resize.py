#!/usr/bin/env python3
"""Reject a build that silently carries the retired connected-mode driver."""
import argparse
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def check(app):
    root = app / 'Contents/Resources/Guest/ConnectedDisplay'
    pin = json.loads((REPO / 'graphics/driver/connected-resize-v05.json').read_text())
    if not (root / 'release.json').is_file():
        raise ValueError('Connected-display driver missing: prepare/package signed v0.5 using graphics/driver/README.md')
    if json.loads((root / 'release.json').read_text()) != pin:
        raise ValueError('Connected-display manifest differs from shared pins')
    files = {'Graphics/' + n: h for n, h in pin['members'].items()}
    files.update({'install.ps1': pin['installer_sha256'],
                  'install-mixed-display-driver.ps1': pin['installer_helper_sha256']})
    for name, expected in files.items():
        path = root / name
        if not path.resolve().is_relative_to(root.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('Connected-display payload differs: ' + name)
    for source, field in [('graphics/driver/install-connected-resize.ps1', 'installer_sha256'),
                          ('scripts/install-mixed-display-driver.ps1', 'installer_helper_sha256')]:
        if hashlib.sha256((REPO / source).read_bytes()).hexdigest() != pin[field]:
            raise ValueError('Shared connected-display installer differs')
    runtime = json.loads((app / 'Contents/Resources/Native3D/runtime.json').read_text())
    for name, expected in pin['native_runtime'].items():
        if runtime.get(name) != expected:
            raise ValueError('Connected-display native ABI differs: ' + name)
    guest = app / 'Contents/Resources/Guest'
    gl = json.loads((guest / 'OpenGL/release.json').read_text())
    if gl['version'] != pin['opengl_version']:
        raise ValueError('Connected-display installer needs a compatible OpenGL profile; do not force pins')
    for folder, member in [('VideoGraphics', 'neptune_umd_arm64.dll'),
                           ('X86Graphics', 'neptune_umd_x86.dll')]:
        actual = hashlib.sha256((guest / folder / member).read_bytes()).hexdigest()
        if actual not in pin['preserved_dll_sha256']:
            raise ValueError('Connected-display installer needs a qualified ' + folder + ' profile')
    return pin


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    check(parser.parse_args().app.resolve(strict=True))
    print('Connected display: signed v0.5 pins, installer and native ABI verified; runtime qualification separate')
