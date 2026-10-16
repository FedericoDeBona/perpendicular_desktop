#!/usr/bin/env python3
"""Compile the exact added diagnostic code with metadata stubs; no QEMU/guest."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def braced(text, start):
    opening = text.index('{', start)
    depth = 1; cursor = opening + 1
    while depth:
        depth += (text[cursor] == '{') - (text[cursor] == '}')
        cursor += 1
    return text[start:cursor]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    text = args.source.read_text()
    gate = braced(text, text.index('static bool virgl_cmd_diagnostic_admit('))
    context_gate = 'virgl_cmd_diagnostic_admit(VirtIOGPU *g)' in gate
    call = 'if (virgl_cmd_diagnostic_admit(g))' if context_gate else 'if (virgl_cmd_diagnostic_admit())'
    emitted = []
    for name in ('virtio_gpu_virgl_process_cmd', 'virgl_cmd_get_capset_info', 'virgl_cmd_get_capset'):
        # Match the definition rather than a later call to the handler.
        match = re.search(r'(?:void\s+|void )' + re.escape(name) + r'\(', text)
        assert match, name
        body = braced(text, match.start())
        emitted.append(braced(body, body.index(call)))
        if name == 'virtio_gpu_virgl_process_cmd':
            assert body.index('VIRTIO_GPU_FILL_CMD(cmd->cmd_hdr);') < body.index(call) < body.index('virgl_renderer_force_ctx_0();')
        else:
            assert body.index('VIRTIO_GPU_FILL_CMD(') < body.index(call)
    if context_gate:
        assert gate.index('virtio_vdev_has_feature(VIRTIO_DEVICE(g), VIRTIO_GPU_F_CONTEXT_INIT)') < gate.index('if (enabled < 0)') < gate.index('records++')
    code = '''#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#define g_getenv getenv
static int g_strcmp0(const char *a, const char *b) { return a ? strcmp(a,b) : -1; }
#define VIRTIO_GPU_RESP_OK_CAPSET 0x1103
#define VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER 0x1205
typedef struct { unsigned int len; } CapsetIDs;
typedef struct { CapsetIDs *capset_ids; bool context_init; } VirtIOGPU;
''' + ('''
#define VIRTIO_DEVICE(g) (g)
#define VIRTIO_GPU_F_CONTEXT_INIT 4
static bool virtio_vdev_has_feature(VirtIOGPU *g, int bit) {
    return bit == VIRTIO_GPU_F_CONTEXT_INIT && g->context_init;
}
''' if context_gate else '') + gate + '''
int main(int argc, char **argv) {
    bool delayed = argc > 1 && strcmp(argv[1], "delayed") == 0;
    bool never = argc > 1 && strcmp(argv[1], "never") == 0;
    CapsetIDs ids = {3};
    VirtIOGPU state = {&ids, !delayed && !never}, *g = &state;
    struct { struct { uint32_t type, flags, ctx_id; } cmd_hdr; } command = {{0x108,1,7}}, *cmd = &command;
    struct { uint32_t capset_index; } info = {2};
    struct { uint32_t capset_id, capset_max_version, capset_max_size; } resp = {7,0,60};
    struct { uint32_t capset_id, capset_version; } gc = {7,0};
    uint32_t max_ver = 0, max_size = 60;
    const char *private_payload = "NEVER_PRINT_PRIVATE_PAYLOAD";
    (void)private_payload;
    for (unsigned int i=0; i<(delayed ? 8192u : 4096u); ++i) {
        if (delayed && i == 4096) { g->context_init = true; }
        switch (i%3) {
        case 0: ''' + emitted[0] + ''' break;
        case 1: ''' + emitted[1] + ''' break;
        case 2: ''' + emitted[2] + ''' break;
        }
    }
    return 0;
}
'''
    results = []
    with tempfile.TemporaryDirectory(prefix='perp-gpu-log-test-', dir='/tmp') as temporary:
        temporary = Path(temporary); source = temporary / 'harness.c'; binary = temporary / 'harness'
        source.write_text(code)
        built = subprocess.run(['/usr/bin/xcrun', 'clang', '-std=gnu11', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(binary)], capture_output=True, text=True)
        assert built.returncode == 0, built.stderr
        trials = [(value, None) for value in (None, '0', 'true', '01', '1')]
        if context_gate:trials.extend([('1', 'never'), ('1', 'delayed')])
        for value, feature_mode in trials:
            env = os.environ.copy();env.pop('PERPENDICULAR_GPU_COMMAND_DIAGNOSTICS', None)
            if value is not None:env['PERPENDICULAR_GPU_COMMAND_DIAGNOSTICS'] = value
            run = subprocess.run([str(binary), *([feature_mode] if feature_mode else [])], env=env, capture_output=True, text=True, timeout=5)
            assert run.returncode == 0 and run.stdout == ''
            lines = run.stderr.splitlines()
            if value == '1' and feature_mode != 'never':
                assert len(lines) == 65
                assert lines[-1] == 'perpendicular-gpu-cmd suppressed after 64 records'
                allowed = {
                    'perpendicular-gpu-cmd entry type=0x00000108 flags=0x00000001 ctx_id=7',
                    'perpendicular-gpu-cmd capset-info index=2 num_capsets=3 response_id=7 response_version=0 response_size=60',
                    'perpendicular-gpu-cmd capset request_id=7 request_version=0 num_capsets=3 backend_max_version=0 backend_size=60 response_type=0x00001103',
                }
                assert set(lines[:-1]) == allowed
                assert all(line in allowed for line in lines[:-1])
                assert 'NEVER_PRINT_PRIVATE_PAYLOAD' not in run.stderr
            else:
                assert lines == []
            results.append({'environment': value, 'feature_mode': feature_mode or 'enabled', 'exit': run.returncode, 'diagnostic_lines': len(lines)})
    report = {'source_sha256': hashlib.sha256(text.encode()).hexdigest(), 'trials': results,
        'result': 'pass', 'context_init_gate': context_gate, 'scope': 'Exact added gate/log blocks, compiled with metadata stubs; not QEMU runtime or guest validation'}
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
