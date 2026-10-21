#!/usr/bin/env python3
"""Create an offline APFS rollback checkpoint before a graphics change.

Uses normal ACPI shutdown when requested. Never forces a VM off, restores a
disk, resets TPM state, or opens the original VM. Credentials stay private.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def command(path, operation):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(path)
        stream = connection.makefile('rwb')
        stream.readline()
        for name in ['qmp_capabilities', operation]:
            stream.write((json.dumps({'execute': name}) + '\n').encode())
            stream.flush()
            while True:
                value = json.loads(stream.readline())
                if 'error' in value:
                    raise RuntimeError(value['error'])
                if 'return' in value:
                    break
        return value['return']


def checkpoint(root, shutdown):
    config = json.loads((root / 'machine.json').read_text())
    qmp = f"/tmp/perpendicular-{os.getuid()}-{config['id'][:8]}.sock"
    pid_file = root / 'qemu-system-aarch64.pid'
    pid = int(pid_file.read_text()) if pid_file.exists() else None
    if pid and alive(pid):
        if not shutdown:
            raise RuntimeError('Windows is running. Shut it down normally before making a checkpoint.')
        if command(qmp, 'query-uuid').get('UUID') != config['id']:
            raise RuntimeError('The running machine identity does not match this checkpoint.')
        command(qmp, 'system_powerdown')
        print('Normal Windows shutdown requested. Waiting for its process to exit.', flush=True)
        deadline = time.monotonic() + 60
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.25)
        if alive(pid):
            raise RuntimeError('Windows has not shut down. No checkpoint was created and no force was used.')
    # A frontend can exit while QEMU continues running; its adopted TPM process
    # can then survive normal VM shutdown. Stop only the exact owned TPM helper.
    tpm_file = root / 'swtpm.pid'
    if tpm_file.exists():
        tpm_pid = int(tpm_file.read_text())
        if alive(tpm_pid):
            args = subprocess.check_output(['ps', '-p', str(tpm_pid), '-o', 'command='], text=True)
            expected = f"/tmp/perpendicular-tpm-{os.getuid()}-{config['id'][:8]}.sock"
            if expected not in args or str(root / 'Windows/tpm') not in args:
                raise RuntimeError('The saved TPM process does not belong to this machine.')
            os.kill(tpm_pid, signal.SIGTERM)
            deadline = time.monotonic() + 5
            while alive(tpm_pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            if alive(tpm_pid):
                raise RuntimeError('The virtual TPM is still stopping; no checkpoint was created.')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    destination = root / 'Rollback' / ('before-graphics-' + stamp)
    destination.mkdir(parents=True, mode=0o700)
    destination.parent.chmod(0o700)
    sources = [(root / 'machine.json', Path('machine.json')),
               (Path(config['disk']), Path('Windows/system.qcow2')),
               (Path(config['variables']), Path('Windows/efi-vars.fd')),
               (Path(config['firmware']), Path('Windows/efi-code.fd'))]
    for path in (root / 'Windows/tpm').rglob('*'):
        if path.is_file():
            if path.is_symlink():
                raise RuntimeError('A TPM state file is unexpectedly a symlink.')
            sources.append((path, path.relative_to(root)))
    saved = []
    for source, relative in sources:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        subprocess.run(['cp', '-c', str(source), str(target)], check=True)
        target.chmod(0o600)
        if target.stat().st_size != source.stat().st_size:
            raise RuntimeError('A checkpoint file has an unexpected size.')
        saved.append({'file': str(relative), 'source': str(source), 'bytes': target.stat().st_size})
    report = destination / 'checkpoint.json'
    report.write_text(json.dumps({'machineID': config['id'], 'createdAt': stamp,
                                 'method': 'offline APFS clones', 'files': saved}, indent=2) + '\n')
    report.chmod(0o600)
    print(f'Offline rollback checkpoint created: {destination}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.home() / 'Library/Application Support/Perpendicular Restart')
    parser.add_argument('--shutdown', action='store_true', help='Request normal ACPI shutdown first, without forcing it')
    options = parser.parse_args()
    checkpoint(options.root.resolve(strict=True), options.shutdown)
