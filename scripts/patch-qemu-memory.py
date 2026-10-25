#!/usr/bin/env python3
"""Apply the isolated ARM64 macOS balloon change to a private QEMU source tree.

Does not build or launch QEMU, change a VM, or enable the opt-in runtime flag.
"""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def replace(text, before, after):
    if text.count(before) != 1:
        raise ValueError("QEMU source anchor differs: " + before[:90])
    return text.replace(before, after, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if source.is_relative_to(ROOT):
        raise ValueError("Use a private QEMU tree outside the repository")
    path = source / "hw/virtio/virtio-balloon.c"
    text = path.read_text()
    text = replace(text, '#include "qemu/osdep.h"',
                   '#include "qemu/osdep.h"\n#include "hw/mem/memory-device.h"')
    anchor = "    MachineState *machine = MACHINE(qdev_get_machine());"
    text = replace(text, anchor, anchor + "\n    if (perp_balloon_reclaim_enabled()) {\n"
        "        return machine->ram_size + get_plugged_memory_size();\n    }")
    text = replace(text, "static bool virtio_balloon_inhibited(void)",
                   '#include "perp-balloon-reclaim.h"\n\nstatic bool virtio_balloon_inhibited(void)')
    text = replace(text, "static void virtio_balloon_handle_output(VirtIODevice *vdev, VirtQueue *vq)",
                   "static void virtio_balloon_drain_output(VirtIODevice *vdev, VirtQueue *vq)")
    text = replace(text, "if (!virtio_balloon_inhibited()) {\n                if (vq == s->ivq)",
                   "if (!virtio_balloon_inhibited() &&\n                !perp_balloon_page(section.mr, section.offset_within_region,\n                                   pa, vq == s->ivq)) {\n                if (vq == s->ivq)")
    anchor = "static void virtio_balloon_get_config(VirtIODevice *vdev, uint8_t *config_data)"
    # Defer MMIO-originated notifications to the main loop before pausing all
    # CPUs. The existing queue implementation retains descriptor ownership.
    glue = """static void perp_balloon_output_bh(void *opaque)
{
    VirtIOBalloon *s = opaque;
    pause_all_vcpus();
    virtio_balloon_drain_output(VIRTIO_DEVICE(s), s->ivq);
    virtio_balloon_drain_output(VIRTIO_DEVICE(s), s->dvq);
    resume_all_vcpus();
}

static void virtio_balloon_handle_output(VirtIODevice *vdev, VirtQueue *vq)
{
    VirtIOBalloon *s = VIRTIO_BALLOON(vdev);
    if (s->perp_reclaim_bh) {
        qemu_bh_schedule(s->perp_reclaim_bh);
    } else {
        virtio_balloon_drain_output(vdev, vq);
    }
}

"""
    text = replace(text, anchor, glue + anchor)
    anchor = "    s->ivq = virtio_add_queue(vdev, 128, virtio_balloon_handle_output);"
    text = replace(text, anchor, "    if (!perp_balloon_reclaim_init(errp)) {\n"
        "        qemu_remove_balloon_handler(s);\n"
        "        virtio_cleanup(vdev);\n        return;\n    }\n"
        "    if (perp_balloon_reclaim_enabled()) {\n"
        "        s->perp_reclaim_bh = qemu_bh_new(perp_balloon_output_bh, s);\n"
        "    }\n" + anchor)
    anchor = "    qemu_unregister_resettable(OBJECT(dev));"
    text = replace(text, anchor, "    if (s->perp_reclaim_bh) {\n"
        "        qemu_bh_delete(s->perp_reclaim_bh);\n"
        "        s->perp_reclaim_bh = NULL;\n    }\n"
        "    perp_balloon_reclaim_cleanup();\n" + anchor)
    anchor = "static void virtio_balloon_device_reset(VirtIODevice *vdev)\n{\n    VirtIOBalloon *s = VIRTIO_BALLOON(vdev);"
    text = replace(text, anchor, anchor + "\n\n    if (s->perp_reclaim_bh) {\n"
        "        qemu_bh_cancel(s->perp_reclaim_bh);\n    }\n    perp_balloon_forget();")
    anchor = "static void virtio_balloon_class_init(ObjectClass *klass, void *data)\n{"
    text = replace(text, anchor, anchor + '\n    object_class_property_add_str(klass, "perp-reclaim-stats", perp_balloon_stats, NULL);')
    header = source / "include/hw/virtio/virtio-balloon.h"
    anchor = "    VirtQueue *ivq, *dvq, *svq, *free_page_vq, *reporting_vq;"
    h = replace(header.read_text(), anchor, "    QEMUBH *perp_reclaim_bh;\n" + anchor)
    # Validate every anchor before writing either source.
    path.write_text(text)
    header.write_text(h)
    shutil.copy2(ROOT / "memory/qemu/perp-balloon-reclaim.h", path.parent)
    print("Patched private balloon source; runtime verification required.")


if __name__ == "__main__":
    main()
