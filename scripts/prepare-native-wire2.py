#!/usr/bin/env python3
"""Prepare the exact v0.4 peer's host source, without changing a runtime or VM.

Requires the pinned renderer archives, a clean protocol Git checkout and the
matching private native-transport reference. Generated sources stay in output.
Run with the private Python environment containing PyYAML and Mako.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile

REPO = Path(__file__).resolve().parent.parent
PROTOCOL = 'f510a6e41ea89a6d626de4da9d9b02978a770e37'
RENDERER = 'cf5af71359b224a9a482e9b5a67f8160497dc951'
BASE_SHA = 'e024bfbbac6f8dfc7040c08ca35121557f4f539fa2d2bee50d0d7f8201062c7e'
RENDERER_SHA = '7610c0d9eca1ab12f9548661ef8577fd06602d1743c99c1e974eb77826a06d3b'
NATIVE_SHA = '00a1111d3a27e92f819874d4f47d389e38977c897f86b7ef03807d78cbd0d9c3'
NATIVE_PROFILES = {
    'sync-channel-20261019': NATIVE_SHA,
    'window-recovery-20261020': '741c50e71c63911632a97811757a9a5f6638eb9046cd6c2f03ec7c5816e8caf5',
}
# Names plus Git blob hashes of all 311 generated files in the released peer:
# osy/virtio-win-mesa bf536bba65454900d782fa7417bc95c1608d7483.
PEER_SHA = 'cf25a3e304a5adf97c5f7d189839785807e4fcdcf0ddfbe8a408cf654827ee68'
CHANGED = ['server/render_socket.c', 'server/render_context.c', 'src/virglrenderer.c',
           'src/meson.build', 'src/proxy/proxy_context.c', 'src/neptune/npt_shared.c',
           'src/neptune/npt_overrides_d3d11_fence.c', 'src/neptune/npt_ring.c',
           'src/neptune/npt_context.c']
ADDED = ['src/perp-sync/' + name for name in (
    'proxy-broker.c', 'wire.h', 'worker-prefix.inc', 'channel.h', 'worker-signal.inc',
    'snapshot.c', 'worker-suffix.inc', 'wire.c', 'broker.h', 'wire1-layout.h',
    'live.h', 'snapshot-storage.h', 'worker-generations.inc', 'snapshot.h')]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def extract(archive, destination):
    """Strip the GitHub archive root; reject special and escaping members."""
    destination.mkdir()
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        roots = {PurePosixPath(m.name).parts[0] for m in members if m.name}
        require(len(roots) == 1, 'Archive must have one root')
        for member in members:
            parts = PurePosixPath(member.name).parts
            require(not member.name.startswith('/') and '..' not in parts, 'Unsafe archive member')
            target = destination.joinpath(*parts[1:])
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as source, target.open('wb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)
            elif member.issym():
                require(target != destination and not Path(member.linkname).is_absolute(), 'Unsafe archive link')
                resolved = (target.parent / member.linkname).resolve()
                require(destination == resolved or destination in resolved.parents, 'Escaping archive link')
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)
            else:
                raise ValueError('Unsupported archive member: ' + member.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-archive', type=Path, required=True)
    parser.add_argument('--renderer-archive', type=Path, required=True)
    parser.add_argument('--protocol', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True, help='Pinned Wire1 renderer build profile')
    parser.add_argument('--reference-profile', choices=tuple(NATIVE_PROFILES),
                        default='sync-channel-20261019',
                        help='Exact native-source inventory to preserve; neither profile qualifies a runtime')
    parser.add_argument('--output', type=Path, required=True, help='Fresh private directory')
    args = parser.parse_args()
    output = args.output.resolve()
    require(not output.exists(), 'Fresh output required')
    require(REPO not in output.parents or REPO / '.build' in output.parents,
            'Generated sources must stay outside versioned repository paths')
    require(digest(args.base_archive) == BASE_SHA, 'Different base archive')
    require(digest(args.renderer_archive) == RENDERER_SHA, 'Different renderer archive')
    protocol = args.protocol.resolve(strict=True)
    head = subprocess.check_output(['git', '-C', str(protocol), 'rev-parse', 'HEAD'], text=True).strip()
    status = subprocess.check_output(['git', '-C', str(protocol), 'status', '--porcelain'], text=True)
    require(head == PROTOCOL and not status, 'Pinned clean protocol checkout required')
    profile = args.reference.resolve(strict=True)
    reference = profile / 'src/virglrenderer'
    native_inputs = {name: digest(reference / name) for name in CHANGED + ADDED}
    require(inventory_digest(native_inputs) == NATIVE_PROFILES[args.reference_profile],
            'Different native transport reference')
    output.mkdir(parents=True)
    logs = output / 'logs'
    logs.mkdir()

    def run(name, command, cwd=None, data=None):
        command = list(map(str, command))
        (logs / (name + '.command.json')).write_text(json.dumps(command, indent=2) + '\n')
        result = subprocess.run(command, cwd=cwd, input=data, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (logs / (name + '.log')).write_bytes(result.stdout)
        require(result.returncode == 0, name + ' failed; see private log')

    base, source = output / 'upstream-base', output / 'source'
    extract(args.base_archive, base)
    extract(args.renderer_archive, source)
    overlay = ''.join(''.join(difflib.unified_diff(
        (base / name).read_text().splitlines(keepends=True),
        (reference / name).read_text().splitlines(keepends=True),
        fromfile='a/' + name, tofile='b/' + name)) for name in CHANGED)
    (output / 'native-transport.patch').write_text(overlay)
    run('native-transport', ['patch', '-p1', '--batch', '--forward'], source, overlay.encode())
    for name in ADDED:
        (source / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(reference / name, source / name)
    # The pinned native layout header records the reference's original tool
    # root. Relocate that include on the copy, never on the reference itself.
    include = next(line for line in (reference / 'src/perp-sync/wire1-layout.h').read_text().splitlines()
                   if line.startswith('#include <') and '/.tools/' in line)
    original_tools = include.removeprefix('#include <').split('/.tools/', 1)[0] + '/.tools/'
    for name in CHANGED + ADDED:
        path = source / name
        path.write_text(path.read_text().replace(original_tools, str(profile.parent) + '/'))
    patches = {}
    for name in ['context-retirement', 'context-admission-channel', 'resource-retirement',
                 'import-lifetime', 'scanout-selection', 'wire2-update-context']:
        patch = REPO / 'graphics/renderer' / (name + '.patch')
        patches[patch.name] = digest(patch)
        run(name, ['patch', '-p1', '--batch', '--forward', '-i', patch], source)
    marker = REPO / 'graphics/renderer/import-marker.h'
    shutil.copy2(marker, source / 'src/perp-sync/import-marker.h')
    patches[marker.name] = digest(marker)
    generated = output / 'protocol'
    registry = ['--json', protocol / 'npt_registry.json', '--overlay', protocol / 'npt_registry_overlay.json']
    for name, flags in [('host', ['--side', 'host']), ('guest', ['--side', 'guest']),
                        ('client', ['--side', 'guest', '--client-only'])]:
        run('generate-' + name, [sys.executable, protocol / 'tools/npt_protocol.py',
                                '--outdir', generated, *flags, *registry])
    run('generate-types', [sys.executable, protocol / 'tools/gen_headers.py', *registry,
                          '--output', generated / 'npt_protocol_directx_types.h'])
    peers = {}
    for path in generated.iterdir():
        if path.is_file() and not path.name.startswith('npt_protocol_host'):
            data = path.read_bytes()
            peers[path.name] = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    require(len(peers) == 311 and inventory_digest(peers) == PEER_SHA,
            'Generated peer differs from the released guest')
    target = source / 'src/neptune/neptune-protocol'
    replaced = {}
    for path in generated.iterdir():
        destination = target / path.name
        if path.is_file() and destination.is_file():
            shutil.copy2(path, destination)
            replaced[path.name] = digest(destination)
    (output / 'source-receipt.json').write_text(json.dumps({
        'renderer_pin': RENDERER, 'protocol_pin': PROTOCOL, 'native_inputs': native_inputs,
        'base_archive_sha256': BASE_SHA, 'renderer_archive_sha256': RENDERER_SHA,
        'patches': patches, 'paired_guest_files': len(peers), 'peer_inventory_sha256': PEER_SHA,
        'generated_host_files': replaced, 'decode_failure_diagnostics': False,
        'runtime_verified': False,
    }, indent=2) + '\n')
    print('Matching source prepared. No runtime was built, installed or qualified: ' + str(source))


if __name__ == '__main__':
    main()
