#!/usr/bin/env python3
"""Install a verified local build only after quitting the canonical app.

Backups use .bundle-backup, never .app: Launch Services must not confuse a
rollback copy with the ordinary app when attributing Files and Folders access.
"""
import argparse
from datetime import datetime
from pathlib import Path
import shutil
import subprocess
import tempfile
import importlib.util

spec = importlib.util.spec_from_file_location('sign_macos', Path(__file__).with_name('sign-macos.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--from-app', type=Path, default=Path('.build/Perpendicular.app'))
    args = parser.parse_args()
    source = args.from_app.resolve()
    target = Path('/Applications/Perpendicular.app')
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    if str(target/'Contents/MacOS/Perpendicular') in (p.strip() for p in processes):
        raise SystemExit('Quit Perpendicular before installing. Do not rename the running app.')
    requirement = '='+signing.requirement()[1]
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R', requirement, str(source)], check=True)
    backups = Path.home()/'Library/Application Support/Perpendicular Restart/QA/AppBackups'
    backups.mkdir(parents=True, exist_ok=True)
    backup = backups/(datetime.now().strftime('%Y%m%dT%H%M%S%f')+'.bundle-backup')
    with tempfile.TemporaryDirectory(prefix='.perpendicular-install-', dir='/Applications') as temporary:
        staged = Path(temporary)/'Perpendicular.app'
        shutil.copytree(source, staged, symlinks=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R', requirement, str(staged)], check=True)
        if target.exists():
            subprocess.run([LSREGISTER, '-u', str(target)], check=True)
            target.rename(backup)
        try:
            staged.rename(target)
        except OSError:
            if backup.exists():
                backup.rename(target)
            raise
    subprocess.run([LSREGISTER, '-f', str(target)], check=True)
    print('Installed verified app. Rollback bundle: '+str(backup))


if __name__ == '__main__':
    main()
