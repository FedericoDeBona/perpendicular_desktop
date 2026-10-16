/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PERPENDICULAR_GPU_MAP_DIAGNOSTIC_H
#define PERPENDICULAR_GPU_MAP_DIAGNOSTIC_H

#include <stdint.h>

enum PerpGpuMapStage {
    PMD_MAP_REQUEST = 1, PMD_MAP_ADD_BEGIN, PMD_MAP_ADD_DONE,
    PMD_UNMAP_REQUEST, PMD_UNREF_REQUEST, PMD_UNMAP_DETACH_BEGIN,
    PMD_UNMAP_DETACH_DONE, PMD_UNMAP_FINISH, PMD_RESOURCE_DESTROY,
    PMD_GPU_RESET_BEGIN, PMD_GPU_RESET_DONE, PMD_PCI_CONFIG,
    PMD_PCI_BAR_BEGIN, PMD_PCI_BAR_DONE, PMD_PCI_RESET_BEGIN,
    PMD_PCI_RESET_DONE,
};

/* Scalar metadata only. No guest bytes, host addresses or object pointers. */
typedef struct PerpGpuMapRecord {
    uint64_t offset, size, bar_start, bar_size, bar_config;
    uint64_t old_bar, new_bar, fence;
    uint32_t stage, resource, opcode, context, bdf;
    uint32_t command, pm, vstatus, bar_mapped;
    uint32_t config_offset, config_value, config_length;
} PerpGpuMapRecord;

/* All functions require the BQL. Off unless the exact environment value is1.
 * The GPU translation unit owns the one process-global fixed ring. */
int perp_gpu_map_diag_active(void);
void perp_gpu_map_diag_record(const PerpGpuMapRecord *record);
void perp_gpu_map_diag_dump(uint64_t ipa);
void perp_gpu_map_diag_gpu(unsigned stage, void *gpu, uint32_t resource,
                           uint64_t offset, uint64_t size, const void *command);

#endif
