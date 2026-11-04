#!/usr/bin/env python3
"""Upgrade the qualified v1 HVF memory source without blocking the main loop.

Apply after patch-qemu-memory.py and patch-qemu-virtio-mem.py to a private
QEMU 10.0.12 tree. Does not build, package, launch or alter a running VM.
"""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def replace(text, before, after):
    if text.count(before) != 1:
        raise ValueError("Qualified memory source anchor differs: " + before[:100])
    return text.replace(before, after, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    source = parser.parse_args().source.resolve(strict=True)
    if source.is_relative_to(ROOT):
        raise ValueError("Use a private QEMU source tree outside the repository")
    changes = {}
    for device, instance, field, callback, drain, extra in (
        ("balloon", "s", "perp_reclaim", "perp_balloon_output_bh",
         "    virtio_balloon_drain_output(VIRTIO_DEVICE(s), s->ivq);\n"
         "    virtio_balloon_drain_output(VIRTIO_DEVICE(s), s->dvq);", ""),
        ("mem", "vmem", "perp_hvf", "perp_virtio_mem_bh",
         "    virtio_mem_drain_request(VIRTIO_DEVICE(vmem), vmem->vq);",
         "    vmem->perp_hvf_in_bh = true;\n"),
    ):
        path = source / f"hw/virtio/virtio-{device}.c"
        header = source / f"include/hw/virtio/virtio-{device}.h"
        text, h = path.read_text(), header.read_text()
        text = replace(text, '#include "qemu/osdep.h"',
                       '#include "qemu/osdep.h"\n#include "perp-hvf-quiesce.h"')
        before = "    pause_all_vcpus();\n" + extra + drain
        after = (f"    if (!perp_hvf_quiesce({instance}->{field}_retry,\n"
                 f"                          &{instance}->{field}_pause,\n"
                 f"                          &{instance}->{field}_waits)) {{\n"
                 "        return;\n    }\n" + extra + drain)
        text = replace(text, before, after)
        tail = ("    vmem->perp_hvf_in_bh = false;\n" if device == "mem" else "")
        text = replace(text, drain + "\n" + tail + "    resume_all_vcpus();",
                       drain + "\n" + tail +
                       f"    perp_hvf_quiesce_cancel({instance}->{field}_retry,\n"
                       f"                            &{instance}->{field}_pause);")
        anchor = f"        {instance}->{field}_bh = qemu_bh_new({callback}, {instance});"
        text = replace(text, anchor, anchor +
                       f"\n        {instance}->{field}_retry = timer_new_ms(\n"
                       f"            QEMU_CLOCK_REALTIME, {callback}, {instance});")
        anchor = f"        qemu_bh_cancel({instance}->{field}_bh);"
        text = replace(text, anchor, anchor +
                       f"\n        perp_hvf_quiesce_cancel({instance}->{field}_retry,\n"
                       f"                                &{instance}->{field}_pause);")
        anchor = f"        qemu_bh_delete({instance}->{field}_bh);"
        text = replace(text, anchor,
                       f"        perp_hvf_quiesce_cancel({instance}->{field}_retry,\n"
                       f"                                &{instance}->{field}_pause);\n"
                       f"        timer_free({instance}->{field}_retry);\n"
                       f"        {instance}->{field}_retry = NULL;\n" + anchor)
        declaration = f"    QEMUBH *{field}_bh;"
        h = replace(h, declaration, declaration +
                    f"\n    QEMUTimer *{field}_retry;\n"
                    f"    bool {field}_pause;\n    uint64_t {field}_waits;")
        # A live device property proves the capability independently of the
        # package manifest; these counters never change guest ownership.
        kind = "Balloon" if device == "balloon" else "MEM"
        cast = "VIRTIO_BALLOON" if device == "balloon" else "VIRTIO_MEM"
        prefix = "virtio_balloon" if device == "balloon" else "virtio_mem"
        function = f"perp_{device}_quiesce_stats"
        anchor = f"static void {prefix}_class_init(ObjectClass *klass, void *data)\n{{"
        getter = f'''static char *{function}(Object *obj, Error **errp)
{{
    VirtIO{kind} *dev = {cast}(obj);
    return g_strdup_printf("{{\\"version\\":1,\\"pending\\":%s,"
                           "\\"waits\\":%" PRIu64 "}}",
                           dev->{field}_pause ? "true" : "false",
                           dev->{field}_waits);
}}

'''
        text = replace(text, anchor, getter + anchor +
                       f'\n    object_class_property_add_str(klass, "perp-quiesce-stats", {function}, NULL);')
        changes[path], changes[header] = text, h
    destination = source / "hw/virtio/perp-hvf-quiesce.h"
    if destination.exists():
        raise ValueError("Quiesce helper already exists; preserve the source")
    # Validate both devices completely before changing either one.
    for path, text in changes.items():
        path.write_text(text)
    shutil.copy2(ROOT / "memory/qemu/perp-hvf-quiesce.h", destination)
    print("Patched both memory callbacks; build and protected runtime verification required.")


if __name__ == "__main__":
    main()
