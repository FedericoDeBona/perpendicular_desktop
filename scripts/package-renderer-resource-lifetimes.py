#!/usr/bin/env python3
"""Package the compatible lifetime fix in a fresh signed reference app.

Never starts Windows or overwrites an installed app. The frontend/guest in this
reference are unchanged; build-macos.sh supplies the current project versions.
"""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-app', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--host-profile', required=True)
    parser.add_argument('--output-app', type=Path, required=True)
    args = parser.parse_args()
    reference = args.reference_app.resolve(strict=True)
    build = args.build.resolve(strict=True)
    output = args.output_app.resolve()
    require(not output.exists() and not output.is_relative_to(REPO), 'Fresh private app outside Git required')
    require(not reference.is_relative_to(output) and not output.is_relative_to(reference), 'Separate reference/output required')
    require(args.host_profile.replace('-', '').isalnum(), 'Invalid host profile')
    profile = json.loads((REPO / 'graphics/renderer/profiles' / (args.host_profile + '.json')).read_text())
    require(profile['schema'] == 1 and profile['id'] == args.host_profile, 'Different host profile')
    receipt = json.loads((build / 'receipt.json').read_text())
    fix = receipt.get('resourceLifetimes', {})
    patch = REPO / 'graphics/renderer/resource-lifetime-metadata.patch'
    check = REPO / 'graphics/renderer/check-resource-lifetime-metadata.c'
    require(fix.get('version') == 1 and fix.get('perProducerSources') == 256 and fix.get('maxContexts') == 32
            and fix.get('patchSHA256') == sha(patch) and fix.get('checkSHA256') == sha(check)
            and fix.get('sanitizedCheck') == 'PASS', 'Missing shared fix or matching sanitized check')
    baseline = build / 'baseline-source.c'
    require(sha(baseline) == '801066f5f5cb50aef4d42c6af8cd67f7537e7d16d5547224452ee1ccc50fe6d4', 'Different compatible source')
    with tempfile.TemporaryDirectory(prefix='perp-renderer-source-') as temp:
        root = Path(temp)
        target = root / 'src/perp-sync/proxy-broker.c'
        target.parent.mkdir(parents=True)
        shutil.copy2(baseline, target)
        run(['patch', '-p1', '--batch', '--forward', '-i', patch], cwd=root)
        require(target.read_bytes() == (build / 'production/proxy-broker.c').read_bytes(), 'Production source differs from shared patch')
    native = reference / 'Contents/Resources/Native3D'
    manifest = json.loads((native / 'runtime.json').read_text())
    for name, expected in manifest['files'].items():
        relative = Path(name)
        require(not relative.is_absolute() and '..' not in relative.parts and sha(native / name) == expected, 'Reference mismatch: ' + name)
    sections = runpy.run_path(str(REPO / 'scripts/rebuild-hvf-erridr.py'))['sections']
    pair = {'library': 'lib/libvirglrenderer.1.dylib', 'server': 'bin/virgl_render_server'}
    for label, packed in pair.items():
        raw = build / 'production' / Path(packed).name
        require(sections(native / packed) == profile['baselineSections'][label]
                == receipt['variants']['baseline'][label]['sections'], 'Different baseline code: ' + label)
        require(sha(raw) == profile['raw'][label] == receipt['variants']['production'][label]['sha256'], 'Unpinned production output: ' + label)
        require(b'resource_inventory' not in raw.read_bytes(), 'Diagnostic output cannot be packaged')
    run(['codesign', '--verify', '--deep', '--strict', reference])
    output.parent.mkdir(parents=True, exist_ok=True)
    run(['cp', '-cR', reference, output])
    destination = output / 'Contents/Resources/Native3D'
    packaged = {}
    for label, packed in pair.items():
        raw = build / 'production' / Path(packed).name
        target = destination / packed
        shutil.copy2(raw, target)
        changes = []
        for line in run(['otool', '-L', target]).splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(('/System/', '/usr/lib/', '@')):
                continue
            dependency_name = Path(dependency).name
            require((destination / 'lib' / dependency_name).is_file(), 'Missing compatible dependency: ' + dependency_name)
            prefix = '@loader_path/../lib/' if packed.startswith('bin/') else '@loader_path/'
            changes += ['-change', dependency, prefix + dependency_name]
        if packed.startswith('lib/'):
            changes += ['-id', '@rpath/' + target.name]
        if changes:
            run(['install_name_tool', *changes, target])
        run(['codesign', '--force', '--sign', '-', '--timestamp=none', target])
        run(['codesign', '--verify', '--strict', target])
        require(sections(target) == receipt['variants']['production'][label]['sections'], 'Packaging changed code/data')
        packaged[packed] = sha(target)
        if profile['files']:
            require(profile['files'].get(packed) == packaged[packed], 'Packaged profile differs')
        manifest['files'][packed] = packaged[packed]
    manifest['resource_lifetime_metadata'] = {
        'version': 1, 'hostProfile': profile['id'], 'perProducerSources': 256,
        'maxContexts': 32, 'maxMetadataNodes': 8192,
        'patches': {'graphics/renderer/resource-lifetime-metadata.patch': sha(patch)},
        'files': packaged,
    }
    require(not any(manifest.get(key) for key in ('resource_inventory_candidate', 'resource_lifetime_metadata_candidate')), 'Use a qualified baseline, not a diagnostic reference')
    (destination / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    provenance = {'schema': 1, 'profile': profile['id'], 'fix': manifest['resource_lifetime_metadata'],
                  'source': sha(build / 'production/proxy-broker.c'), 'buildReceipt': sha(build / 'receipt.json'),
                  'recipe': sha(Path(__file__)), 'frontendAndGuest': 'unchanged reference; rebuild project next'}
    (destination / 'Notices/resource-lifetime-metadata.json').write_text(json.dumps(provenance, indent=2) + '\n')
    signing = runpy.run_path(str(REPO / 'scripts/sign-macos.py'))
    fingerprint, requirement = signing['requirement']()
    signing['run'](['/usr/bin/security', 'unlock-keychain', '-p', signing['PASSWORD'].read_text(), signing['KEYCHAIN']])
    signing['run'](['/usr/bin/codesign', '--force', '--sign', fingerprint, '--keychain', signing['KEYCHAIN'],
                    '--timestamp=none', '--identifier', 'com.perpendicular.restart', '--requirements', '=designated => ' + requirement, output])
    signing['run'](['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '=' + requirement, output])
    (output.parent / (output.name + '.renderer-profile.json')).write_text(json.dumps({**profile, 'files': packaged}, indent=2) + '\n')
    print(json.dumps({'app': str(output), 'files': packaged, 'frontEndAndGuestUnchanged': True}))


if __name__ == '__main__':
    main()
