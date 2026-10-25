#!/usr/bin/env python3
"""Enable the private ARM64 HVF virtio-mem implementation in QEMU 10.0.12.

Only edits the supplied source tree, outside the product repository. It does
not start a VM, install a driver, or enable the runtime opt-in.
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
    source = parser.parse_args().source.resolve(strict=True)
    if source.is_relative_to(ROOT):
        raise ValueError("Use a private QEMU tree outside the repository")
    paths = ["hw/virtio/virtio-mem.c", "include/hw/virtio/virtio-mem.h",
             "hw/virtio/Kconfig", "Kconfig.host", "meson.build"]
    texts = {name: (source / name).read_text() for name in paths}
    text = texts[paths[0]]
    text = replace(text, '#include "trace.h"', '#include "trace.h"\n#include "perp-virtio-mem-hvf.h"')
    text = replace(text, "static void virtio_mem_handle_request(VirtIODevice *vdev, VirtQueue *vq)",
                   "static void virtio_mem_drain_request(VirtIODevice *vdev, VirtQueue *vq)")
    anchor = "static void virtio_mem_get_config(VirtIODevice *vdev, uint8_t *config_data)"
    glue = """static void perp_virtio_mem_bh(void *opaque)
{
    VirtIOMEM *vmem = opaque;
    pause_all_vcpus();
    vmem->perp_hvf_in_bh = true;
    virtio_mem_drain_request(VIRTIO_DEVICE(vmem), vmem->vq);
    vmem->perp_hvf_in_bh = false;
    resume_all_vcpus();
}

static void virtio_mem_handle_request(VirtIODevice *vdev, VirtQueue *vq)
{
    VirtIOMEM *vmem = VIRTIO_MEM(vdev);
    if (vmem->perp_hvf_bh) {
        qemu_bh_schedule(vmem->perp_hvf_bh);
    } else {
        virtio_mem_drain_request(vdev, vq);
    }
}

"""
    text = replace(text, anchor, glue + anchor)
    if text.count("ram_block_discard_range(rb,") != 5:
        raise ValueError("Different virtio-mem discard paths")
    text = text.replace("ram_block_discard_range(rb,", "perp_virtio_mem_discard(vmem,")
    anchor = "    if (!vmem->memdev) {"
    if text.count(anchor) != 2:
        raise ValueError("Different virtio-mem memdev validation paths")
    text = text.replace(anchor, """#if defined(__APPLE__)
    if (!perp_virtio_mem_enabled() || vmem->dynamic_memslots ||
        runstate_check(RUN_STATE_INMIGRATE)) {
        error_setg(errp, "macOS virtio-mem requires ARM64 HVF, explicit opt-in, "
                   "dynamic-memslots=off and no incoming migration");
        return;
    }
#endif
""" + anchor, 1)
    anchor = "    vmem->vq = virtio_add_queue(vdev, 128, virtio_mem_handle_request);"
    text = replace(text, anchor, "    if (perp_virtio_mem_enabled()) {\n"
        "        vmem->perp_hvf_bh = qemu_bh_new(perp_virtio_mem_bh, vmem);\n    }\n" + anchor)
    anchor = ("    virtio_mem_resize_usable_region(vmem, vmem->requested_size, true);\n\n"
              "    vmem->bitmap_size =")
    text = replace(text, anchor, """    if (perp_virtio_mem_enabled()) {
        error_setg(&vmem->perp_hvf_migration_blocker,
                   "HVF virtio-mem backing replacement is not migratable");
        if (migrate_add_blocker(&vmem->perp_hvf_migration_blocker, errp)) {
            ram_block_coordinated_discard_require(false);
            return;
        }
    }

""" + anchor)
    anchor = "    virtio_del_queue(vdev, 0);"
    text = replace(text, anchor, "    if (vmem->perp_hvf_bh) {\n"
        "        qemu_bh_delete(vmem->perp_hvf_bh);\n"
        "        vmem->perp_hvf_bh = NULL;\n    }\n"
        "    migrate_del_blocker(&vmem->perp_hvf_migration_blocker);\n" + anchor)
    anchor = "    virtio_mem_unplug_all(vmem);\n}"
    text = replace(text, anchor, "    if (vmem->perp_hvf_bh) {\n"
        "        qemu_bh_cancel(vmem->perp_hvf_bh);\n    }\n" + anchor)
    anchor = "static void virtio_mem_class_init(ObjectClass *klass, void *data)\n{"
    text = replace(text, anchor, anchor + '\n    object_class_property_add_str(klass, "perp-reclaim-stats", perp_virtio_mem_stats, NULL);')
    texts[paths[0]] = text
    texts[paths[1]] = replace(texts[paths[1]], "    VirtQueue *vq;",
        "    QEMUBH *perp_hvf_bh;\n    bool perp_hvf_in_bh;\n"
        "    uint64_t perp_hvf_discarded_bytes;\n"
        "    Error *perp_hvf_migration_blocker;\n    VirtQueue *vq;")
    texts[paths[2]] = replace(texts[paths[2]],
        "config VIRTIO_MEM\n    bool\n    default y\n    depends on VIRTIO\n    depends on LINUX",
        "config VIRTIO_MEM\n    bool\n    default y\n    depends on VIRTIO\n    depends on LINUX || DARWIN")
    texts[paths[3]] += "\nconfig DARWIN\n    bool\n"
    anchor = "  (host_os == 'linux' ? ['CONFIG_LINUX=y'] : []) + \\\n"
    texts[paths[4]] = replace(texts[paths[4]], anchor,
        anchor + "  (host_os == 'darwin' ? ['CONFIG_DARWIN=y'] : []) + \\\n")
    for name, text in texts.items():
        (source / name).write_text(text)
    shutil.copy2(ROOT / "memory/qemu/perp-virtio-mem-hvf.h", source / "hw/virtio")
    print("Patched private virtio-mem source; runtime verification required.")


if __name__ == "__main__":
    main()
