#!/usr/bin/env python3
"""Install a verified local build only after quitting the canonical app.

Rollback archives contain no discoverable application. Stop the owned folder
server while Windows is offline before moving its responsible application.
"""
import argparse
from datetime import datetime
from pathlib import Path
import shutil
import subprocess
import tempfile
import importlib.util
import os
import signal
import tarfile
import time
import hashlib
import plistlib

spec = importlib.util.spec_from_file_location('sign_macos', Path(__file__).with_name('sign-macos.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def unregister(path):
    result = subprocess.run([LSREGISTER, '-u', str(path)], capture_output=True, text=True)
    if result.returncode and '-10814' not in result.stdout + result.stderr:
        raise RuntimeError('Cannot retire the old application registration: '+str(path))


def stop_folder_server(directory):
    """Only the exact VM-owned SMB processes, with Windows already offline."""
    pid_file = directory/'qemu-system-aarch64.pid'
    if pid_file.exists():
        pid = pid_file.read_text().strip()
        result = subprocess.run(['ps', '-p', pid, '-o', 'command='], capture_output=True, text=True)
        if result.returncode == 0:
            raise RuntimeError('Shut down Windows normally before installing; its folder sessions must be closed.')
    config = directory/'Samba/smb.conf'
    owned = []
    for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
        pid, _, command = line.strip().partition(' ')
        command = command.strip()
        if command.endswith(' --configfile='+str(config)) and '/Samba/bin/samba-dot-org-smbd -F --no-process-group' in command:
            executable = command.split(' -F --no-process-group')[0]
            if not Path(executable).is_relative_to(directory/'Runtimes'):
                raise RuntimeError('The folder server does not belong to the selected VM.')
            owned.append(int(pid))
    for pid in owned:
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    for pid in owned:
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
            if result.returncode or result.stdout.strip().startswith('Z'): break
            time.sleep(.1)
        else: raise RuntimeError('The folder server is still stopping. No force was used.')
    print('Stopped owned offline folder server processes: '+str(len(owned)))


def archive_bundle(source, destination):
    """Verify file content before retiring a rollback app directory."""
    temporary = destination.with_suffix('.part')
    try:
        with tarfile.open(temporary, 'w:gz', compresslevel=1) as archive:
            archive.add(source, arcname='Perpendicular.app')
        with tarfile.open(temporary, 'r:gz') as archive:
            for member in archive.getmembers():
                if member.isfile():
                    relative = Path(member.name).relative_to('Perpendicular.app')
                    original = source/relative
                    with archive.extractfile(member) as saved, original.open('rb') as current:
                        def digest(stream):
                            result=hashlib.sha256()
                            for block in iter(lambda:stream.read(1024*1024), b''): result.update(block)
                            return result.digest()
                        if digest(saved) != digest(current): raise RuntimeError('Rollback archive verification failed.')
        temporary.chmod(0o600)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def retire_legacy_backups(directory, backups):
    candidates=[]
    for current, dirs, _ in os.walk(directory/'QA'):
        path=Path(current); info=path/'Contents/Info.plist'
        if not info.is_file(): continue
        dirs.clear()
        if plistlib.loads(info.read_bytes()).get('CFBundleIdentifier') == signing.IDENTIFIER:
            candidates.append(path)
    for path in candidates:
        archive=backups/(datetime.now().strftime('%Y%m%dT%H%M%S%f')+'-'+path.name+'.tar.gz')
        archive_bundle(path, archive)
        unregister(path)
        shutil.rmtree(path)
        print('Archived obsolete application copy: '+path.name)


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
    info=plistlib.loads((target/'Contents/Info.plist').read_bytes()) if target.exists() else {}
    directory=Path(info.get('PerpendicularMachineDirectory', str(Path.home()/'Library/Application Support/Perpendicular Restart')))
    stop_folder_server(directory)
    backups = directory/'QA/AppBackups'
    backups.mkdir(parents=True, exist_ok=True)
    backup = backups/(datetime.now().strftime('%Y%m%dT%H%M%S%f')+'.tar.gz')
    with tempfile.TemporaryDirectory(prefix='.perpendicular-install-', dir='/Applications') as temporary:
        staged = Path(temporary)/'Perpendicular.app'
        shutil.copytree(source, staged, symlinks=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R', requirement, str(staged)], check=True)
        previous=Path(temporary)/'previous'
        if target.exists():
            archive_bundle(target, backup)
            unregister(target)
            target.rename(previous)
        try:
            staged.rename(target)
        except OSError:
            if previous.exists():
                previous.rename(target)
            raise
    retire_legacy_backups(directory, backups)
    subprocess.run([LSREGISTER, '-f', str(target)], check=True)
    print('Installed verified app. Rollback archive: '+str(backup))


if __name__ == '__main__':
    main()
