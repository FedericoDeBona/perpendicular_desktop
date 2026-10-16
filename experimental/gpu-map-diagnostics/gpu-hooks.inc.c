/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "pci-fields.inc.c"
#include "ring.inc.c"

void perp_gpu_map_diag_gpu(unsigned stage, void *opaque, uint32_t resource,
                           uint64_t offset, uint64_t size, const void *command)
{
    VirtIOGPU *gpu = opaque;
    const struct virtio_gpu_ctrl_command *cmd = command;
    BusState *bus;
    PCIDevice *pci;
    PerpGpuMapRecord record = { .stage = stage, .resource = resource,
                                .offset = offset, .size = size };

    if (!perp_gpu_map_diag_active()) {
        return;
    }
    bus = qdev_get_parent_bus(DEVICE(gpu));
    pci = bus && bus->parent ?
        (PCIDevice *)object_dynamic_cast(OBJECT(bus->parent), TYPE_PCI_DEVICE) :
        NULL;
    if (!perp_gpu_map_diag_target(pci)) {
        return;
    }
    perp_gpu_map_diag_fields(&record, pci);
    record.vstatus = VIRTIO_DEVICE(gpu)->status;
    if (cmd) {
        record.opcode = cmd->cmd_hdr.type;
        record.context = cmd->cmd_hdr.ctx_id;
        record.fence = cmd->cmd_hdr.fence_id;
    }
    perp_gpu_map_diag_record(&record);
}
