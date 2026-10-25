#!/usr/bin/env python3
"""Make a private offline APFS development copy of an existing Windows VM.

Copies disk, EFI and TPM together. Does not start Windows, install guest tools,
clean existing integrations, alter the source, or overwrite a destination.
"""
import argparse
import hashlib
from datetime import datetime, timezone
import json
import os
import plistlib
from pathlib import Path
import re
import secrets
import shutil
import socket
import stat
import subprocess
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


def regular(path):
    require(not path.is_symlink() and path.is_file(), 'Expected a regular source file: ' + str(path))
    require(stat.S_ISREG(path.stat().st_mode), 'Unsupported source file: ' + str(path))


def identity(path):
    value = path.stat()
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns


def require_offline(source, files):
    """Inspect only: never signal a process or print its potentially private arguments."""
    lsof = shutil.which('lsof') or '/usr/sbin/lsof'
    result = subprocess.run([lsof, '-nP', '-Fpc', *map(str, files)],
                            capture_output=True, text=True, timeout=15)
    require(result.returncode in (0, 1) and not result.stderr.strip(),
            'Cannot establish that source files are closed.')
    require(not result.stdout.strip(), 'A process has a source VM file open. Shut down that VM first.')
    result = subprocess.run(['ps', '-axo', 'pid=,comm=,args='],
                            capture_output=True, text=True, check=True, timeout=10)
    for line in result.stdout.splitlines():
        if str(source) in line and ('qemu-system-' in line or 'swtpm' in line):
            raise ValueError('A QEMU or TPM process references the source VM. Shut it down first.')


def choose_port(preferred):
    with socket.socket() as probe:
        try:
            probe.bind(('127.0.0.1', preferred))
        except OSError:
            probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def write_private(path, value):
    with path.open('x') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')
    path.chmod(0o600)


def prepare_utm(source, root, image_tool, firmware, preferred_port, dry_run):
    """Import one offline ARM64 UTM VM, retaining its UEFI variables and TPM.

    UTM stores variables as qcow2 and TPM state in a single swtpm file. Convert
    only the variables container; never reset the firmware variables or TPM.
    """
    source = source.resolve(strict=True)
    require(source.is_dir() and source.suffix == '.utm', 'Expected a UTM bundle.')
    require(not root.exists() and not root.is_symlink(), 'Destination already exists.')
    root = root.parent.resolve(strict=True) / root.name
    require(not root.is_relative_to(source), 'Destination must be outside the source VM.')
    config_file = source / 'config.plist'
    regular(config_file)
    config = plistlib.loads(config_file.read_bytes())
    require(config.get('Backend') == 'QEMU' and config.get('ConfigurationVersion') == 4,
            'Only the inspected QEMU UTM configuration v4 is supported.')
    system, qemu = config.get('System', {}), config.get('QEMU', {})
    require(system.get('Architecture') == 'aarch64' and system.get('Target') == 'virt',
            'This import requires an ARM64 virt machine.')
    require(qemu.get('TPMDevice') is True and qemu.get('UEFIBoot') is True,
            'This import preserves an existing TPM and UEFI boot.')
    require(not qemu.get('AdditionalArguments'), 'Inspect custom QEMU arguments before import.')
    disks = [d for d in config.get('Drive', []) if d.get('ImageType') == 'Disk']
    require(len(disks) == 1 and disks[0].get('Interface') == 'NVMe', 'Expected one NVMe system disk.')
    name = disks[0].get('ImageName')
    require(isinstance(name, str) and Path(name).name == name, 'Invalid UTM disk filename.')
    require(firmware is not None, 'Provide --utm-firmware matching the firmware used by UTM.')
    firmware = firmware.resolve(strict=True)
    uuid.UUID(config['Information']['UUID'])
    cpus = system.get('CPUCount', 0) or min(4, os.cpu_count() or 1)
    memory = system.get('MemorySize')
    require(type(cpus) is int and 1 <= cpus <= 64 and type(memory) is int and 512 <= memory <= 1_048_576,
            'Invalid UTM CPU or memory configuration.')
    disk, variables, tpm = (source / 'Data' / name, source / 'Data/efi_vars.fd', source / 'Data/tpmdata')
    watched = [config_file, disk, variables, tpm, firmware]
    for path in watched:
        regular(path)
    before = {path: identity(path) for path in watched}
    require_offline(source, watched)
    for path in [disk, variables]:
        info = json.loads(subprocess.check_output([str(image_tool), 'info', '--output=json', str(path)]))
        require(info.get('format') == 'qcow2' and not info.get('backing-filename')
                and not info.get('encrypted') and not info.get('dirty-flag'),
                'Expected a clean standalone qcow2: ' + path.name)
        if path == variables:
            require(info.get('virtual-size') == firmware.stat().st_size == 64 * 1024 * 1024,
                    'Unexpected UEFI flash size.')
    require(all(identity(path) == before[path] for path in watched), 'Source changed during inspection.')
    if dry_run:
        print('Offline ARM64 UTM source checked:', source)
        print('Would clone disk, matching firmware and single-file TPM, and convert UEFI variables:', root)
        return
    os.umask(0o077)
    (root / 'Windows/tpm').mkdir(parents=True, mode=0o700)
    copied = []
    for path, relative in [(disk, 'Windows/system.qcow2'), (firmware, 'Windows/efi-code.fd'),
                           (tpm, 'Windows/tpm/tpmdata')]:
        require_offline(source, watched)
        require(all(identity(p) == before[p] for p in watched), 'Source changed before copying.')
        target = root / relative
        subprocess.run(['/bin/cp', '-c', str(path), str(target)], check=True)
        target.chmod(0o600)
        require(target.stat().st_size == before[path][2], 'Unexpected cloned size.')
        copied.append({'source': str(path), 'file': relative, 'bytes': target.stat().st_size})
    target_vars = root / 'Windows/efi-vars.fd'
    subprocess.run([str(image_tool), 'convert', '-f', 'qcow2', '-O', 'raw', str(variables), str(target_vars)], check=True)
    subprocess.run([str(image_tool), 'compare', '-f', 'qcow2', '-F', 'raw', str(variables), str(target_vars)], check=True)
    target_vars.chmod(0o600)
    require_offline(source, watched)
    require(all(identity(path) == before[path] for path in watched), 'Source changed during preparation.')
    machine_id = str(uuid.uuid4())
    mac = '02:' + ':'.join(f'{value:02x}' for value in secrets.token_bytes(5))
    write_private(root / 'machine.json', {
        'id': machine_id, 'name': config['Information'].get('Name', 'Windows IoT'),
        'cpus': cpus, 'memoryMiB': memory, 'disk': str(root / 'Windows/system.qcow2'),
        'firmware': str(root / 'Windows/efi-code.fd'), 'variables': str(target_vars),
        'tpmStateFile': str(root / 'Windows/tpm/tpmdata'), 'mac': mac,
        'guestPort': choose_port(preferred_port), 'token': secrets.token_hex(32),
        'graphics': 'standard', 'recoveryDisplay': False, 'keyboardLayout': 'it',
    })
    write_private(root / 'source-receipt.json', {
        'schema': 1, 'createdAt': datetime.now(timezone.utc).isoformat(),
        'method': 'offline APFS UTM import; qcow2-to-raw UEFI container conversion',
        'sourceDirectory': str(source), 'sourceMachineID': config['Information']['UUID'],
        'machineID': machine_id, 'files': copied, 'sourceChanged': False,
        'tpmBackend': 'single file, preserved', 'variablesComparedEqual': True,
        'firmwareSHA256': hashlib.sha256(firmware.read_bytes()).hexdigest(),
        'VMStarted': False, 'guestIntegrationsChanged': False,
    })
    print('Prepared offline UTM development copy:', root)
    print('Original UTM VM, UEFI contents and TPM identity preserved. Windows was not started.')


def prepare(source, root, image_tool, preferred_port, dry_run):
    require(not source.is_symlink(), 'The source directory must not be a symlink.')
    source = source.resolve(strict=True)
    require(source.is_dir(), 'The source must be a VM directory.')
    require(not root.exists() and not root.is_symlink(), 'Destination already exists; nothing was changed.')
    root = root.parent.resolve(strict=True) / root.name
    require(not root.is_relative_to(source), 'The destination must be outside the source VM.')
    config_file = source / 'config.json'
    regular(config_file)
    config = json.loads(config_file.read_text())
    require(config.get('format_version') == 1, 'Unsupported source VM configuration version.')
    uuid.UUID(config['id'])
    cpus, memory = config.get('cpus'), config.get('memory_mib')
    require(type(cpus) is int and 1 <= cpus <= 64, 'Invalid source CPU count.')
    require(type(memory) is int and 512 <= memory <= 1_048_576, 'Invalid source memory size.')
    require(config.get('tpm_enabled') is True, 'This preparation requires the existing persistent TPM.')
    firmware = config.get('firmware_code_path')
    require(isinstance(firmware, str) and Path(firmware).is_absolute(), 'Missing explicit source firmware path.')
    require(not Path(firmware).is_symlink() and Path(firmware).resolve(strict=True) == source / 'efi-code.fd',
            'The configured firmware differs from the local EFI file; inspect it before copying.')
    layout = config.get('keyboard_layout') or 'it'
    require(isinstance(layout, str) and re.fullmatch(r'[a-z0-9_-]{1,32}', layout),
            'Invalid source keyboard layout.')
    sources = [(source / name, Path('Windows') / name)
               for name in ('system.qcow2', 'efi-code.fd', 'efi-vars.fd')]
    tpm = source / 'tpm'
    require(tpm.is_dir() and not tpm.is_symlink(), 'Missing regular source TPM directory.')
    for directory, children, names in os.walk(tpm, followlinks=False):
        require(all(not (Path(directory) / name).is_symlink() for name in children),
                'Unexpected symbolic link in source TPM state.')
        for name in sorted(names):
            path = Path(directory) / name
            sources.append((path, Path('Windows') / path.relative_to(source)))
    require(any(relative == Path('Windows/tpm/tpm2-00.permall') for _, relative in sources),
            'Missing persistent TPM 2.0 state.')
    for path, _ in sources:
        regular(path)
    watched = [config_file, *[path for path, _ in sources]]
    before = {path: identity(path) for path in watched}
    require_offline(source, watched)
    result = subprocess.run([str(image_tool), 'info', '--output=json', str(source / 'system.qcow2')],
                            capture_output=True, text=True, check=True, timeout=20)
    disk = json.loads(result.stdout)
    require(disk.get('format') == 'qcow2' and not disk.get('backing-filename'),
            'The source must be a standalone qcow2 disk, without a backing file.')
    require(not disk.get('encrypted') and not disk.get('dirty-flag'),
            'The qcow2 container is encrypted or marked dirty; inspect it before copying.')
    require(all(identity(path) == before[path] for path in watched), 'Source files changed during inspection.')
    if dry_run:
        print('Offline source checked:', source)
        print('Would clone', len(sources), 'files to a new private directory:', root)
        print('Source integrations, EFI and TPM would be preserved. No files were written.')
        return

    os.umask(0o077)
    root.mkdir(mode=0o700)
    copied = []
    try:
        for path, relative in sources:
            require_offline(source, watched)
            require(all(identity(item) == before[item] for item in watched), 'Source files changed before copying.')
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            subprocess.run(['/bin/cp', '-c', str(path), str(destination)], check=True)
            destination.chmod(0o600)
            require(destination.stat().st_size == before[path][2], 'A copied file has an unexpected size.')
            copied.append({'source': str(path), 'file': str(relative), 'bytes': before[path][2],
                           'source_mtime_ns': before[path][3]})
        require_offline(source, watched)
        require(all(identity(path) == before[path] for path in watched), 'Source files changed during copying.')
        machine_id = str(uuid.uuid4())
        mac = '02:' + ':'.join(f'{value:02x}' for value in secrets.token_bytes(5))
        machine = {'id': machine_id, 'name': config.get('name') or 'Windows',
                   'cpus': cpus, 'memoryMiB': memory,
                   'disk': str(root / 'Windows/system.qcow2'),
                   'firmware': str(root / 'Windows/efi-code.fd'),
                   'variables': str(root / 'Windows/efi-vars.fd'),
                   'mac': mac, 'guestPort': choose_port(preferred_port), 'token': secrets.token_hex(32),
                   'graphics': 'standard', 'recoveryDisplay': False, 'keyboardLayout': layout}
        receipt = {'schema': 1, 'createdAt': datetime.now(timezone.utc).isoformat(),
                   'method': 'offline APFS file clones', 'sourceDirectory': str(source),
                   'sourceMachineID': config['id'], 'machineID': machine_id, 'files': copied,
                   'sourceChanged': False, 'guestIntegrationsChanged': False, 'VMStarted': False,
                   'sourceDisplayAdapter': config.get('display_adapter'),
                   'sourceSecureBootRecordedState': config.get('secure_boot_state'),
                   'compatibility': 'EFI and TPM copied unchanged. New UUID/MAC and standard display require boot, activation and any guest disk-protection checks; no TPM reset or security-policy change.'}
        write_private(root / 'source-receipt.json', receipt)
        write_private(root / 'machine.json', machine)
    except Exception:
        print('Preparation did not finish. Partial destination retained for inspection:', root)
        raise
    print('Prepared private development copy:', root)
    print('The source was not changed. Windows was not started; existing guest integrations remain installed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Existing offline VM directory containing config.json, or an ARM64 QEMU .utm bundle')
    parser.add_argument('--root', type=Path, default=Path.home() / 'Library/Application Support/Perpendicular Memory IoT',
                        help='New destination directory; it must not already exist')
    parser.add_argument('--qemu-img', type=Path, help='Existing qemu-img executable if it is not on PATH')
    parser.add_argument('--guest-port', type=int, default=17837, help='Preferred free loopback port (default: 17837)')
    parser.add_argument('--dry-run', action='store_true', help='Validate the source without creating or copying anything')
    parser.add_argument('--utm-firmware', type=Path, help='Matching UTM firmware; required for an ARM64 .utm import')
    args = parser.parse_args()
    require(1024 <= args.guest_port <= 65535, 'The guest port must be between 1024 and 65535.')
    image_tool = args.qemu_img or shutil.which('qemu-img')
    require(image_tool is not None, 'Provide --qemu-img with the existing image tool path.')
    if args.source.suffix == '.utm':
        prepare_utm(args.source.expanduser(), args.root.expanduser(), Path(image_tool),
                    args.utm_firmware, args.guest_port, args.dry_run)
    else:
        prepare(args.source.expanduser(), args.root.expanduser(), Path(image_tool), args.guest_port, args.dry_run)
