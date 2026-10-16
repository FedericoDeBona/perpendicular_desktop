/* SPDX-License-Identifier: GPL-2.0-or-later
 * Included exactly once by the copied trace3 GPU source. */
#include "qemu/main-loop.h"
#include "qemu/timer.h"
#include "diagnostic.h"

#define PERP_GPU_MAP_RING_CAPACITY 512u
typedef struct PerpGpuMapEntry {
    PerpGpuMapRecord value;
    uint64_t sequence, realtime_ns;
} PerpGpuMapEntry;

static PerpGpuMapEntry perp_gpu_map_ring[PERP_GPU_MAP_RING_CAPACITY];
static uint64_t perp_gpu_map_sequence;
static int perp_gpu_map_enabled = -1;
static bool perp_gpu_map_dumped;

int perp_gpu_map_diag_active(void)
{
    /* Instrumentation must not acquire a lock, change scheduling, or query
     * object state from the unlocked HVF fast path/RCU context. */
    if (!bql_locked()) {
        return 0;
    }
    if (perp_gpu_map_enabled < 0) {
        perp_gpu_map_enabled = g_strcmp0(
            g_getenv("PERPENDICULAR_GPU_MAP_DIAGNOSTICS"), "1") == 0;
    }
    return perp_gpu_map_enabled;
}

void perp_gpu_map_diag_record(const PerpGpuMapRecord *record)
{
    PerpGpuMapEntry *entry;
    uint64_t sequence;

    if (!perp_gpu_map_diag_active() || perp_gpu_map_dumped) {
        return;
    }
    sequence = ++perp_gpu_map_sequence;
    entry = &perp_gpu_map_ring[(sequence - 1) % PERP_GPU_MAP_RING_CAPACITY];
    entry->value = *record;
    entry->sequence = sequence;
    entry->realtime_ns = qemu_clock_get_ns(QEMU_CLOCK_REALTIME);
}

static const char *perp_gpu_map_stage(uint32_t stage)
{
    static const char *const names[] = {
        "invalid", "map-request", "map-add-begin", "map-add-done",
        "unmap-request", "unref-request", "unmap-detach-begin",
        "unmap-detach-done", "unmap-finish", "resource-destroy",
        "gpu-reset-begin", "gpu-reset-done", "pci-config",
        "pci-bar-begin", "pci-bar-done", "pci-reset-begin",
        "pci-reset-done",
    };
    return stage < G_N_ELEMENTS(names) ? names[stage] : "invalid";
}

void perp_gpu_map_diag_dump(uint64_t ipa)
{
    uint64_t count, first, sequence;

    if (!perp_gpu_map_diag_active() || perp_gpu_map_dumped) {
        return;
    }
    perp_gpu_map_dumped = true;
    count = MIN(perp_gpu_map_sequence, PERP_GPU_MAP_RING_CAPACITY);
    first = perp_gpu_map_sequence - count + 1;
    error_report("perpendicular-gpu-map-v1 begin ipa=0x%016" PRIx64
                 " capacity=%u count=%" PRIu64 " first=%" PRIu64
                 " last=%" PRIu64 " overwritten=%" PRIu64,
                 ipa, PERP_GPU_MAP_RING_CAPACITY, count, first,
                 perp_gpu_map_sequence, perp_gpu_map_sequence - count);
    for (sequence = first; sequence <= perp_gpu_map_sequence; sequence++) {
        const PerpGpuMapEntry *entry =
            &perp_gpu_map_ring[(sequence - 1) % PERP_GPU_MAP_RING_CAPACITY];
        const PerpGpuMapRecord *r = &entry->value;
        bool contains = r->bar_start != UINT64_MAX && ipa >= r->bar_start &&
                        ipa - r->bar_start >= r->offset &&
                        ipa - r->bar_start - r->offset < r->size;

        error_report("perpendicular-gpu-map-v1 seq=%" PRIu64
                     " mono_ns=%" PRIu64 " stage=%s bdf=0x%04x"
                     " resid=%u opcode=0x%x ctx=%u fence=%" PRIu64
                     " offset=0x%016" PRIx64 " size=0x%016" PRIx64
                     " bar4_start=0x%016" PRIx64 " bar4_size=0x%016" PRIx64
                     " bar4_config=0x%016" PRIx64 " mapped=%u"
                     " old_bar=0x%016" PRIx64 " new_bar=0x%016" PRIx64
                     " command=0x%04x pm=%u vstatus=0x%02x"
                     " cfg_offset=0x%x cfg_value=0x%x cfg_length=%u"
                     " contains_ipa=%u",
                     entry->sequence, entry->realtime_ns,
                     perp_gpu_map_stage(r->stage), r->bdf, r->resource,
                     r->opcode, r->context, r->fence, r->offset, r->size,
                     r->bar_start, r->bar_size, r->bar_config, r->bar_mapped,
                     r->old_bar, r->new_bar, r->command, r->pm, r->vstatus,
                     r->config_offset, r->config_value, r->config_length,
                     (unsigned)contains);
    }
    error_report("perpendicular-gpu-map-v1 end");
}
