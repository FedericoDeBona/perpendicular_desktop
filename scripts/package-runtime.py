#!/usr/bin/env python3
"""Low-level upstream QEMU/swtpm packager for explicit experiments.

Does not include the main HVF RAM/native graphics changes. Normal application
builds use copy-main-runtime.py and the installed qualified runtime instead.
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
repo = pathlib.Path(__file__).resolve().parent.parent
resources = app / 'Contents/Resources'
runtime = resources / 'QEMU'
libdir = app / 'Contents/Frameworks/Runtime/lib'
notices = resources / 'ThirdPartyNotices'
for directory in (runtime / 'bin', libdir, notices):
    directory.mkdir(parents=True, exist_ok=True)

def run(*args):
    return subprocess.check_output(args, text=True).strip()

prefix = pathlib.Path(run('brew', '--prefix'))
copied = {}
manifest = []

def copy_binary(source, destination):
    source = source.resolve()
    if source in copied:
        return copied[source]
    if destination.exists() and any(p == destination for p in copied.values()):
        raise RuntimeError(f'Dependency name collision: {source}')
    copied[source] = destination
    shutil.copy2(source, destination)
    destination.chmod(0o755)
    subprocess.run(['codesign', '--remove-signature', str(destination)], capture_output=True)
    manifest.append({'source': str(source), 'file': str(destination.relative_to(app)),
                     'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    dependencies = [line.strip().split(' (')[0] for line in run('otool', '-L', str(source)).splitlines()[1:]]
    for dependency in dependencies:
        if dependency == str(source) or dependency.startswith(('/usr/lib/', '/System/')):
            continue
        path = pathlib.Path(dependency)
        if not path.is_absolute():
            raise RuntimeError(f'Unresolved dependency {dependency} of {source}')
        if path.resolve() == source:
            continue
        target = copy_binary(path, libdir / path.name)
        replacement = '@loader_path/' + os.path.relpath(target, destination.parent)
        run('install_name_tool', '-change', dependency, replacement, str(destination))
    if destination.suffix == '.dylib':
        run('install_name_tool', '-id', '@loader_path/' + destination.name, str(destination))
    args = ['codesign', '--force', '--sign', '-']
    if destination.name == 'qemu-system-aarch64':
        args += ['--entitlements', str(repo / 'macos/Hypervisor.entitlements')]
    run(*args, str(destination))
    # Preserve each installed package's license and bottle provenance.
    try:
        cellar = pathlib.Path(run('brew', '--cellar')).resolve()
        parts = source.relative_to(cellar).parts
        package = cellar / parts[0] / parts[1]
        notice_dir = notices / (parts[0] + '-' + parts[1])
        notice_dir.mkdir(exist_ok=True)
        for item in package.iterdir():
            if item.is_file() and (item.name.startswith(('COPYING', 'LICENSE', 'NOTICE', 'AUTHORS')) or item.name == 'INSTALL_RECEIPT.json'):
                shutil.copy2(item, notice_dir / item.name)
    except ValueError:
        pass
    return destination

console = runtime / 'Windows Console.app'
(console / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
import plistlib
(console / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'com.perpendicular.windows-console', 'CFBundleName':'Windows Console',
    'CFBundleExecutable':'qemu-system-aarch64', 'CFBundlePackageType':'APPL',
    'CFBundleVersion':'11.1.2', 'LSMinimumSystemVersion':'14.0', 'NSHighResolutionCapable':True,
}))
copy_binary(prefix / 'bin/qemu-system-aarch64', console / 'Contents/MacOS/qemu-system-aarch64')
run('codesign','--force','--sign','-','--entitlements',str(repo / 'macos/Hypervisor.entitlements'),str(console))
link=runtime / 'bin/qemu-system-aarch64'
if link.exists() or link.is_symlink():
    link.unlink()
link.symlink_to('../Windows Console.app/Contents/MacOS/qemu-system-aarch64')
for name in ('qemu-img', 'swtpm'):
    copy_binary(prefix / 'bin' / name, runtime / 'bin' / name)
share = runtime / 'share/qemu'
share.mkdir(parents=True, exist_ok=True)
shutil.copytree(prefix / 'share/qemu/keymaps',share / 'keymaps',dirs_exist_ok=True)
# This machine uses existing enrolled ARM firmware, RAMFB and no PXE boot.
for name in ('vgabios-ramfb.bin',):
    source = prefix / 'share/qemu' / name
    if source.exists():
        shutil.copy2(source, share / name)
(resources / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Packaged {len(copied)} native files from Homebrew.')
