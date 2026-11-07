#!/usr/bin/env python3
"""Package original signed connected-resize candidate into a separate app."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import runpy
import shutil

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--sign', action='store_true', help='Use this Mac\'s existing persistent signing identity')
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if app == Path('/Applications/Perpendicular.app'):
        raise ValueError('Package a separate app before deployment')
    pin = json.loads((REPO / 'graphics/driver/connected-resize-v05.json').read_text())
    root = app / 'Contents/Resources/Guest/ConnectedDisplay'
    if root.exists():
        raise ValueError('Connected payload already exists; preserve it and use a fresh app')
    # Copy only public pinned components, never connection.json or private media.
    (root / 'Graphics').mkdir(parents=True)
    for name in pin['members']:
        shutil.copy2(args.payload / 'Graphics' / name, root / 'Graphics' / name)
    for name in ['install.ps1', 'install-mixed-display-driver.ps1']:
        shutil.copy2(args.payload / name, root / name)
    (root / 'release.json').write_text(json.dumps(pin, indent=2) + '\n')
    spec = importlib.util.spec_from_file_location('connected_check', REPO / 'scripts/check-connected-resize.py')
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    verifier.check(app)
    if args.sign:
        signing = runpy.run_path(str(REPO / 'scripts/sign-macos.py'))
        identifier = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
        if identifier == signing['IDENTIFIER']:
            import subprocess
            subprocess.run(['python3', str(REPO / 'scripts/sign-macos.py'), '--app', str(app)], check=True)
        else:
            signing['sign_component'](app, identifier)
    print('Pinned connected-display candidate packaged; ' + ('signed' if args.sign else 'sign before building') + '; Windows unchanged')


if __name__ == '__main__':
    main()
