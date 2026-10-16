/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "pci-fields.inc.c"

static void perp_gpu_map_diag_pci(unsigned stage, PCIDevice *device,
                                 uint64_t old_bar, uint64_t new_bar,
                                 uint32_t offset, uint32_t value,
                                 uint32_t length)
{
    PerpGpuMapRecord record = { .stage = stage, .config_offset = offset,
                                .config_value = value,
                                .config_length = length };

    if (!perp_gpu_map_diag_active() || !perp_gpu_map_diag_target(device)) {
        return;
    }
    perp_gpu_map_diag_fields(&record, device);
    record.old_bar = old_bar;
    record.new_bar = new_bar;
    perp_gpu_map_diag_record(&record);
}
