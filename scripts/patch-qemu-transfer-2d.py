#!/usr/bin/env python3
"""Apply the opt-in 2D row cursor and scalar timing to a pinned private QEMU.

No ordering, pixel conversion, backing lifetime or full-width copy changes.
The live QOM switch defaults off for a comparison on the same QA boot.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def replace(text, before, after):
    if text.count(before) != 1:
        raise ValueError('Qualified 2D source anchor differs: ' + before[:100])
    return text.replace(before, after, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    source = parser.parse_args().source.resolve(strict=True)
    if source.is_relative_to(ROOT):
        raise ValueError('Use a private QEMU source outside Git')
    pins = json.loads((ROOT / 'graphics/qemu/transfer-2d.json').read_text())
    changes = {}
    for name, expected in pins['sourceBefore'].items():
        path = source / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('Qualified source differs: ' + name)
        changes[path] = path.read_text()
    path = source / 'hw/display/virtio-gpu.c'
    text = changes[path]
    text = replace(text, '#include "qemu/iov.h"',
                   '#include "qemu/iov.h"\n#include "perp-transfer-2d.h"')
    text = replace(text, '    if (t2d.r.x || t2d.r.width != pixman_image_get_width(res->image)) {',
                   '    int64_t copy_start = g_get_monotonic_time();\n'
                   '    uint64_t copied = 0;\n'
                   '    PerpIovCursor cursor = {0};\n'
                   '    bool partial = t2d.r.x || t2d.r.width != pixman_image_get_width(res->image);\n'
                   '    if (partial) {')
    text = replace(text,
                   '            iov_to_buf(res->iov, res->iov_cnt, src_offset,\n'
                   '                       (uint8_t *)img_data + dst_offset,\n'
                   '                       t2d.r.width * bpp);',
                   '            if (g->perp_2d_cursor) {\n'
                   '                copied += perp_iov_to_buf(res->iov, res->iov_cnt,\n'
                   '                    &cursor, src_offset, (uint8_t *)img_data + dst_offset,\n'
                   '                    t2d.r.width * bpp);\n'
                   '            } else {\n'
                   '                copied += iov_to_buf(res->iov, res->iov_cnt, src_offset,\n'
                   '                    (uint8_t *)img_data + dst_offset, t2d.r.width * bpp);\n'
                   '            }')
    text = replace(text, '        iov_to_buf(res->iov, res->iov_cnt, src_offset,\n'
                   '                   (uint8_t *)img_data + dst_offset,\n'
                   '                   stride * t2d.r.height);',
                   '        copied = iov_to_buf(res->iov, res->iov_cnt, src_offset,\n'
                   '                   (uint8_t *)img_data + dst_offset,\n'
                   '                   stride * t2d.r.height);')
    anchor = '\n}\n\nstatic void virtio_gpu_resource_flush(VirtIOGPU *g,'
    text = replace(text, anchor,
                   '\n    unsigned int mode = partial ? (g->perp_2d_cursor ? 2 : 1) : 0;\n'
                   '    g->perp_2d_calls[mode]++;\n'
                   '    g->perp_2d_bytes[mode] += copied;\n'
                   '    g->perp_2d_us[mode] += g_get_monotonic_time() - copy_start;'
                   + anchor)
    anchor = 'static void virtio_gpu_class_init(ObjectClass *klass, void *data)\n{'
    getter = '''static bool perp_2d_get_cursor(Object *obj, Error **errp)
{
    return VIRTIO_GPU(obj)->perp_2d_cursor;
}

static void perp_2d_set_cursor(Object *obj, bool value, Error **errp)
{
    VIRTIO_GPU(obj)->perp_2d_cursor = value;
}

static char *perp_2d_stats(Object *obj, Error **errp)
{
    VirtIOGPU *g = VIRTIO_GPU(obj);
    return g_strdup_printf("{\\"version\\":1,\\"cursor\\":%s,"
        "\\"full\\":{\\"calls\\":%" PRIu64 ",\\"bytes\\":%" PRIu64 ",\\"us\\":%" PRIu64 "},"
        "\\"rows\\":{\\"calls\\":%" PRIu64 ",\\"bytes\\":%" PRIu64 ",\\"us\\":%" PRIu64 "},"
        "\\"cursorRows\\":{\\"calls\\":%" PRIu64 ",\\"bytes\\":%" PRIu64 ",\\"us\\":%" PRIu64 "}}",
        g->perp_2d_cursor ? "true" : "false",
        g->perp_2d_calls[0], g->perp_2d_bytes[0], g->perp_2d_us[0],
        g->perp_2d_calls[1], g->perp_2d_bytes[1], g->perp_2d_us[1],
        g->perp_2d_calls[2], g->perp_2d_bytes[2], g->perp_2d_us[2]);
}

'''
    text = replace(text, anchor, getter + anchor +
                   '\n    object_class_property_add_bool(klass, "perp-2d-cursor",\n'
                   '                                   perp_2d_get_cursor, perp_2d_set_cursor);\n'
                   '    object_class_property_add_str(klass, "perp-2d-stats", perp_2d_stats, NULL);')
    changes[path] = text
    path = source / 'include/hw/virtio/virtio-gpu.h'
    changes[path] = replace(changes[path], '    uint64_t conf_max_hostmem;',
                           '    uint64_t conf_max_hostmem;\n'
                           '    bool perp_2d_cursor;\n'
                           '    uint64_t perp_2d_calls[3], perp_2d_bytes[3], perp_2d_us[3];')
    header = source / 'hw/display/perp-transfer-2d.h'
    if header.exists():
        raise ValueError('Preserve existing 2D candidate')
    for path, text in changes.items():
        path.write_text(text)
    shutil.copy2(ROOT / 'graphics/qemu/transfer-2d-cursor.h', header)
    print('Applied opt-in 2D cursor; build, pixels and real QA comparison required')


if __name__ == '__main__':
    main()
