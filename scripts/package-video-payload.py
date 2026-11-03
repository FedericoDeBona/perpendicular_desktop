#!/usr/bin/env python3
"""Package a pinned video pair into a separate app; never modifies Windows."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('video_check', REPO / 'scripts/check-video-payload.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--umd', type=Path, required=True)
    parser.add_argument('--backend', type=Path, required=True)
    parser.add_argument('--host-profile', required=True)
    parser.add_argument('--release', default='0.1.0')
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if app == Path('/Applications/Perpendicular.app'):
        raise ValueError('Package and verify a separate build before deployment')
    release = json.loads((REPO / 'graphics/backend/releases' / ('video-' + args.release + '.json')).read_text())
    host = release['hosts'][args.host_profile]
    if verifier.digest(args.backend) != host['backend_sha256'] or verifier.digest(args.umd) != release['files']['neptune_umd_arm64.dll']:
        raise ValueError('Video inputs differ from the pinned compatible pair')
    if verifier.digest(REPO / 'graphics/backend/install-video.ps1') != release['files']['install.ps1']:
        raise ValueError('Video installer differs from the pinned release')
    root = app / 'Contents/Resources/Guest/VideoGraphics'
    if root.exists():
        raise ValueError('Use a separate app without an existing video payload')
    native = app / 'Contents/Resources/Native3D'
    runtime = json.loads((native / 'runtime.json').read_text())
    for name, expected in runtime['files'].items():
        file = native / name
        if not file.resolve().is_relative_to(native) or verifier.digest(file) != expected:
            raise ValueError('Existing native runtime differs: ' + name)
    root.mkdir(parents=True)
    shutil.copy2(args.umd, root / 'neptune_umd_arm64.dll')
    shutil.copy2(REPO / 'graphics/backend/install-video.ps1', root / 'install.ps1')
    (root / 'release.json').write_text(json.dumps(release, indent=2)+'\n')
    target = native / 'lib/libdxmt-native.dylib'
    shutil.copy2(args.backend, target)
    runtime['files']['lib/libdxmt-native.dylib'] = host['backend_sha256']
    runtime.pop('video_candidate', None)
    runtime['video_release'] = {'version': release['version'], 'host_profile': args.host_profile}
    notice = native / 'Notices/Video'
    notice.mkdir(parents=True)
    for name in release['patches']:
        shutil.copy2(REPO / 'graphics/backend' / name, notice / name)
    (notice / 'release.json').write_text(json.dumps(release, indent=2)+'\n')
    (native / 'runtime.json').write_text(json.dumps(runtime, indent=2)+'\n')
    verifier.check(app)
    print('Packaged the compatible native/ARM64 video release; Windows unchanged')


if __name__ == '__main__':
    main()
