#!/usr/bin/env python3
"""Incremental diagnostic QEMU build; no install or VM launch."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASE = ROOT / '.tools/graphics-experiment'
SOURCE = BASE / 'src/qemu'
BUILD = BASE / 'build/qemu'
SOURCE_SHA = 'a57ff9a0275943f99c2566b00f7aa5877715948b427d9f648bcbf7191798e200'
ORIGINAL_OBJECT = 'libcommon.a.p/hw_display_virtio-gpu-virgl.c.o'
ORIGINAL_TARGET = 'qemu-system-aarch64-unsigned'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ninja_path(path):
    return str(path).replace('$', '$$').replace(' ', '$ ').replace(':', '$:')


def block(text, prefix):
    matches = [part for part in text.split('\n\n') if part.startswith(prefix)]
    assert len(matches) == 1, 'Expected one pinned Ninja target: ' + prefix
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=BASE / 'build/gpu-command-diagnostics')
    parser.add_argument('--context-init', action='store_true', help='Admit diagnostics only after CONTEXT_INIT was negotiated')
    args = parser.parse_args()
    output = args.output.absolute()
    assert output.parent == BASE / 'build' and output.name.startswith('gpu-command-diagnostics')
    assert not os.path.lexists(output), 'Fresh diagnostic output required'
    source_file = SOURCE / 'hw/display/virtio-gpu-virgl.c'
    assert sha(source_file) == SOURCE_SHA, 'Pinned source differs'
    protected = [source_file, BUILD / 'build.ninja', BUILD / ORIGINAL_TARGET,
        BASE / 'prefix/bin/qemu-system-aarch64',
        ROOT / '.tools/cocoa-neptune-app/Perpendicular 3D Trial.app/Contents/MacOS/qemu-system-aarch64',
        BASE / 'prefix/lib/libvirglrenderer.1.dylib', BASE / 'prefix/libexec/virgl_render_server']
    before = {str(path.relative_to(ROOT)): sha(path) for path in protected}
    previous = BASE / 'build/gpu-command-diagnostics-2/candidate/qemu-system-aarch64'
    if previous.exists():
        before[str(previous.relative_to(ROOT))] = sha(previous)
    output.mkdir(mode=0o700)
    copied = output / 'source/hw/display/virtio-gpu-virgl.c'
    copied.parent.mkdir(parents=True, mode=0o700)
    shutil.copyfile(source_file, copied)
    log_path = output / 'build.log'
    patch = HERE / ('diagnostics-context-init.patch' if args.context_init else 'diagnostics.patch')
    with log_path.open('w') as log:
        applied = subprocess.run(['/usr/bin/patch', '-p1', '--batch', '--forward', '-i', str(patch)],
            cwd=output / 'source', stdout=log, stderr=subprocess.STDOUT)
        assert applied.returncode == 0, 'Patch did not apply; see ' + str(log_path)
        text = (BUILD / 'build.ninja').read_text()
        obj = output / 'virtio-gpu-virgl.c.o'
        linked = output / 'qemu-system-aarch64-unsigned'
        compile_block = block(text, 'build ' + ORIGINAL_OBJECT + ':')
        compile_block = compile_block.replace(ORIGINAL_OBJECT, ninja_path(obj))
        assert compile_block.count('../../src/qemu/hw/display/virtio-gpu-virgl.c') == 1
        compile_block = compile_block.replace('../../src/qemu/hw/display/virtio-gpu-virgl.c', ninja_path(copied))
        # Preserve the original source-local quoted-header search (trace.h).
        compile_block += ' -iquote ' + shlex.quote(str(SOURCE / 'hw/display'))
        link_block = block(text, 'build ' + ORIGINAL_TARGET + ':')
        assert link_block.splitlines()[0].count(ORIGINAL_OBJECT) == 1
        link_block = link_block.replace(ORIGINAL_TARGET, ninja_path(linked), 1).replace(ORIGINAL_OBJECT, ninja_path(obj))
        description = output / 'diagnostics.ninja'
        description.write_text('include build.ninja\n\n' + compile_block + '\n\n' + link_block + '\n')
        env = {key: value for key, value in os.environ.items() if not key.startswith(('DYLD_', 'QEMU_', 'VIRGL_', 'NPT_', 'ANGLE_'))}
        env['PATH'] = str(ROOT / '.tools/build-venv/bin') + ':' + env.get('PATH', '')
        env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
        command = [str(ROOT / '.tools/build-venv/bin/ninja'), '-C', str(BUILD), '-f', str(description), '-j', '2', str(linked)]
        plan = subprocess.run([*command[:1], '-n', *command[1:]], env=env, capture_output=True, text=True)
        assert plan.returncode == 0, plan.stderr
        (output / 'build-plan.txt').write_text(plan.stdout + plan.stderr)
        log.write('Incremental command: ' + shlex.join(command) + '\n');log.flush()
        result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        assert result.returncode == 0, 'Build failed; see ' + str(log_path)
        candidate = output / 'candidate/qemu-system-aarch64'
        candidate.parent.mkdir(mode=0o700)
        shutil.copyfile(linked, candidate);candidate.chmod(0o700)
        entitlements = output / 'hypervisor.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.hypervisor': True}))
        signed = subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier',
            'org.perpendicular.gpu-command-diagnostics.qemu', '--entitlements', str(entitlements), str(candidate)], stdout=log, stderr=subprocess.STDOUT)
        assert signed.returncode == 0
        verified = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(candidate)], stdout=log, stderr=subprocess.STDOUT)
        assert verified.returncode == 0
        actual = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', '--xml', str(candidate)], capture_output=True)
        assert actual.returncode == 0 and plistlib.loads(actual.stdout[actual.stdout.find(b'<?xml'):]) == {'com.apple.security.hypervisor': True}
    for name, expected in before.items():
        assert sha(ROOT / name) == expected, 'Protected artifact changed: ' + name
    report = {'schema': 1, 'source_pin': '88e5ee7ec6703662fec7b638cca74c4769e683d6',
        'source_sha256': SOURCE_SHA, 'patched_source_sha256': sha(copied), 'patch_sha256': sha(patch),
        'candidate': str(candidate.relative_to(ROOT)), 'candidate_sha256': sha(candidate),
        'unsigned_sha256': sha(linked), 'build_log': str(log_path.relative_to(ROOT)), 'build_log_sha256': sha(log_path),
        'ninja_description_sha256': sha(description), 'command': command, 'exit_code': 0,
        'entitlements': {'com.apple.security.hypervisor': True}, 'strict_signature_verified': True,
        'protected_artifact_sha256': before, 'original_source_unchanged': True,
        'installed': False, 'vm_started': False, 'context_init_gate': args.context_init,
        'max_diagnostic_records': 64, 'suppression_lines': 1}
    (output / 'build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
