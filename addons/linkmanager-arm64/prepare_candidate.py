#!/usr/bin/env python3
"""Stage an OFFLINE experimental TAP candidate. Never execute or install it."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent
ZIP_URL = 'https://github.com/OpenVPN/tap-windows6/releases/download/9.27.0/dist.win10.zip'
ZIP_HASH = '36e2609b7ceefedcb978ce5c48caf9e0e5af83423717c4e2e3c1d7ebca8f62a5'
INPUTS = {
    'LinkManagerSvc.exe': ('ea2ee69df1e26c4d4d5eba405b2426216632737c287c132e2a50bc4613786d90',
                           [0x1c34c, 0x1c80c, 0x1c9d4, 0x1cc84]),
    'LinkManagerTray.exe': ('0d78ccee781d9e5b0b85ee805fb4a30f1170d6c0e7080a3de4f6f13c236e45bb',
                            [0xe4f8c, 0xe544c, 0xe5614, 0xe58c4]),
    'tapmgr.exe': ('a3315c2123e8ebc510d540b752ab356c6b5eeff0034c531d3454a5b0a6a0e130',
                    [0x1abfc, 0x1b0bc, 0x1b284, 0x1b534]),
}
# Product/provider filters found in addition to HardwareID selection.
# Reuse the two legacy VirtualBox/Sun alternatives, preserving Secomea strings.
IDENTITY_SLOTS = {
    INPUTS['LinkManagerSvc.exe'][0]: (0x1c1c0, 0x1c200),
    INPUTS['LinkManagerTray.exe'][0]: (0xe4e00, 0xe4e40),
    INPUTS['tapmgr.exe'][0]: (0x1aa70, 0x1aab0),
}
IDENTITY_VALUES = [(b'VirtualBox TAP Adapter', b'TAP-Windows Adapter V9'),
                   (b'Sun Microsystems, Inc.', b'TAP-Windows Provider V9')]

# Separate GetIfEntry description prefix check; this literal has one xref.
OPERATIONAL_SLOT = 0xe5f68

DRIVER = {
    'OemVista.inf': '87a47a05eab6428efbafc7324366fe951a3b5f0693247736b2c75d7d3adda891',
    'tap0901.cat': '28821d476a4708b2e530d9952ca6b13b7af10cd8d1b6a953f72a6056727cac07',
    'tap0901.sys': '07bf2e9b3abd1b040970851aa4f55473144ada2fe7eccca11729c9a6fc7cda6c',
    'devcon.exe': 'ce0e5282e85e541c9fb2e3fa0a5976edf3262c592d1870fe491b8a5376a2ee2f',
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def pe_headers(data, machine):
    require(data[:2] == b'MZ', 'Not a PE')
    pe = struct.unpack_from('<I', data, 60)[0]
    require(data[pe:pe+4] == b'PE\0\0', 'Invalid PE header')
    require(struct.unpack_from('<H', data, pe+4)[0] == machine, 'Wrong PE machine')
    optional = pe+24
    require(struct.unpack_from('<H', data, optional)[0] == 0x20b, 'Expected PE32+')
    return pe, optional


def checksum(data, offset):
    """IMAGEHLP checksum: folded 16-bit words, excluding CheckSum field."""
    total = 0
    for i in range(0, len(data), 2):
        if offset <= i < offset+4:
            continue
        word = data[i] | ((data[i+1] if i+1 < len(data) else 0) << 8)
        total += word
        total = (total & 0xffff) + (total >> 16)
    total = (total & 0xffff) + (total >> 16)
    return (total + len(data)) & 0xffffffff


def patch(data, expected_hash, offsets):
    require(digest(data) == expected_hash, 'Unknown LinkManager input; refusing patch')
    pe, optional = pe_headers(data, 0x8664)
    sections = pe+24+struct.unpack_from('<H', data, pe+20)[0]
    ranges = []
    for i in range(struct.unpack_from('<H', data, pe+6)[0]):
        pos = sections+40*i
        name = data[pos:pos+8].rstrip(b'\0')
        size, start = struct.unpack_from('<II', data, pos+16)
        if name == b'.rdata':
            ranges.append((start, start+size))
    require(data.count(b'lmtap\0') == len(offsets), 'Unexpected HardwareID inventory')
    output = bytearray(data)
    for offset in offsets:
        require(any(start <= offset and offset+8 <= end for start, end in ranges),
                'Patch outside read-only data section')
        require(data[offset:offset+12] == b'lmtap'+b'\0'*7, 'HardwareID slot changed')
        output[offset:offset+8] = b'tap0901\0'
    identity_ranges = []
    for offset, (old, new) in zip(IDENTITY_SLOTS[expected_hash], IDENTITY_VALUES):
        require(any(start <= offset and offset+24 <= end for start, end in ranges),
                'Identity patch outside read-only data section')
        require(data[offset:offset+24] == old+b'\0'*(24-len(old)), 'Identity slot changed')
        require(len(new) < 24, 'Identity replacement too long')
        output[offset:offset+24] = new+b'\0'*(24-len(new))
        identity_ranges.extend(range(offset, offset+24))
    if expected_hash == INPUTS['LinkManagerTray.exe'][0]:
        offset = OPERATIONAL_SLOT
        old = b'LinkManager Adapter'
        new = b'TAP-Windows Adapter V9'
        require(any(start <= offset and offset+24 <= end for start, end in ranges),
                'Operational description patch outside read-only data')
        require(data[offset:offset+24] == old+b'\0'*(24-len(old)),
                'Operational description slot changed')
        # Preserve the original 19-byte prefix comparison and every instruction.
        # The separate ProductName/provider/GUID checks still identify the NIC.
        output[offset:offset+24] = new+b'\0'*(24-len(new))
        identity_ranges.extend(range(offset, offset+24))
    # Do not present the original Authenticode certificate as a valid signature
    # on modified code. Keep the overlay bytes so every other file byte is stable.
    security = optional+112+4*8
    original_security = list(struct.unpack_from('<II', data, security))
    struct.pack_into('<II', output, security, 0, 0)
    check_offset = optional+64
    struct.pack_into('<I', output, check_offset, checksum(output, check_offset))
    allowed = set(range(security, security+8)) | set(range(check_offset, check_offset+4))
    allowed.update(identity_ranges)
    for offset in offsets:
        allowed.update(range(offset, offset+8))
    require(len(output) == len(data), 'PE length changed')
    require(all(a == b or i in allowed for i, (a, b) in enumerate(zip(data, output))),
            'Unexpected changed byte')
    return bytes(output), original_security


def build(archive, destination):
    destination = destination.resolve()
    repo = ROOT.parents[1]
    require(not destination.is_relative_to(repo), 'Generated candidate must be outside repository')
    require(not destination.exists(), 'Output exists; refusing to overwrite')
    require(digest(archive.read_bytes()) == ZIP_HASH, 'Unknown TAP archive SHA-256')
    # Validate all inputs in memory before creating output.
    files, patches = {}, []
    for name, (expected, offsets) in INPUTS.items():
        source = (ROOT/'artifacts/x64'/name).read_bytes()
        result, security = patch(source, expected, offsets)
        files['user-mode-x64/'+name] = result
        patches.append({'file': name, 'input_sha256': expected,
                        'output_sha256': digest(result), 'file_offsets': offsets,
                        'identity_file_offsets': list(IDENTITY_SLOTS[expected]),
                        'operational_description_file_offset': (OPERATIONAL_SLOT if name == 'LinkManagerTray.exe' else None),
                        'original_security_directory': security,
                        'signature': 'unsigned modified candidate; not Secomea signed'})
    with zipfile.ZipFile(archive) as zipped:
        for name, expected in DRIVER.items():
            content = zipped.read('dist.win10/arm64/'+name)
            require(digest(content) == expected, 'TAP member mismatch: '+name)
            if name.endswith(('.sys', '.exe')):
                pe_headers(content, 0xaa64)
            files['driver-arm64/'+name] = content
    for script in ['driver-stage.ps1', 'install-client.ps1']:
        files[script] = (ROOT/script).read_bytes()
    manifest = {
        'schema': 1, 'status': 'experimental, not runtime-qualified',
        'user_mode_machine': 'x64 emulated; NOT converted to ARM64',
        'driver_machine': 'ARM64, official package unchanged',
        'tap_source': ZIP_URL, 'tap_archive_sha256': ZIP_HASH,
        'patches': patches,
        'files': {name: {'sha256': digest(value), 'size': len(value)}
                  for name, value in files.items()},
        'limitations': ['Vendor USB/serial/setup integration not implemented',
                        'SetupDi lifecycle from emulated processes not qualified',
                        'No Windows signature trust or driver load verification',
                        'No portal login or Ethernet traffic verification'],
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.linkmanager-stage-', dir=destination.parent))
    try:
        for name, content in files.items():
            path = staging/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        (staging/'candidate.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
        require(not destination.exists(), 'Output created concurrently')
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tap-archive', type=Path, required=True, help=ZIP_URL)
    parser.add_argument('--output', type=Path, required=True, help='New directory OUTSIDE repository')
    args = parser.parse_args()
    manifest = build(args.tap_archive, args.output)
    print('Prepared experimental candidate: '+str(args.output.resolve()))
    print('12 HardwareID, 6 product/provider and 1 operational description slots patched; ARM64 driver preserved byte for byte.')
    print('No Windows code executed. Runtime/portal verification NOT performed.')
    return manifest


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        print('FAIL: '+str(error), file=sys.stderr)
        sys.exit(1)
