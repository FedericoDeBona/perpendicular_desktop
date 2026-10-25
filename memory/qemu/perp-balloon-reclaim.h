/* SPDX-License-Identifier: GPL-2.0-only
 * Included by virtio-balloon.c. Only complete guest-owned balloon pages may
 * become reusable. This is deliberately separate from generic RAM discard:
 * that API promises zero-filled contents, while a balloon does not need them.
 */
#include "system/hvf.h"
#include "system/cpus.h"
#include "system/runstate.h"
#include "migration/blocker.h"

#if defined(__APPLE__) && defined(__aarch64__)
#include <Hypervisor/Hypervisor.h>

typedef struct PerpBalloonHostPage {
    uint64_t gpa, mask;
    void *host;
    size_t size;
    bool reusable;
} PerpBalloonHostPage;

/* QEMU admits one balloon device. All access is on the main loop under BQL;
 * the RAM listener invalidates tracking before a mapping can disappear.
 */
static GHashTable *perp_balloon_pages;
static uint64_t perp_balloon_reclaimed, perp_balloon_reused;
static uint64_t perp_balloon_reusable, perp_balloon_failures;
static Error *perp_balloon_migration_blocker;

static bool perp_balloon_reclaim_enabled(void)
{
    const char *enabled = getenv("PERP_HVF_BALLOON_RECLAIM");
    return hvf_enabled() && enabled && !strcmp(enabled, "1");
}

static void perp_balloon_forget(void)
{
    GHashTableIter it;
    gpointer value;
    if (!perp_balloon_pages) {
        return;
    }
    g_hash_table_iter_init(&it, perp_balloon_pages);
    while (g_hash_table_iter_next(&it, NULL, &value)) {
        PerpBalloonHostPage *page = value;
        if (page->reusable) {
            /* Removing the hint never discards data. This also handles reset
             * and removal of a RAM region before its host mapping is freed.
             */
            if (madvise(page->host, page->size, MADV_FREE_REUSE)) {
                perp_balloon_failures++;
            }
        }
    }
    g_hash_table_remove_all(perp_balloon_pages);
    perp_balloon_reusable = 0;
}

static void perp_balloon_region_del(MemoryListener *listener,
                                    MemoryRegionSection *section)
{
    /* Conservatively forget tracking on a topology change. Missing a reclaim
     * is safe; retaining ownership bits for a different mapping is not.
     */
    perp_balloon_forget();
}

static MemoryListener perp_balloon_listener = {
    .name = "perpendicular-balloon",
    .region_del = perp_balloon_region_del,
};

static bool perp_balloon_reclaim_init(Error **errp)
{
    if (perp_balloon_reclaim_enabled()) {
        if (runstate_check(RUN_STATE_INMIGRATE)) {
            error_setg(errp, "HVF balloon reclaim cannot restore migrated state");
            return false;
        }
        error_setg(&perp_balloon_migration_blocker,
                   "HVF balloon page ownership is not migratable");
        if (migrate_add_blocker(&perp_balloon_migration_blocker, errp)) {
            return false;
        }
        perp_balloon_pages = g_hash_table_new_full(g_int64_hash, g_int64_equal,
                                                  NULL, g_free);
        memory_listener_register(&perp_balloon_listener, &address_space_memory);
    }
    return true;
}

static void perp_balloon_reclaim_cleanup(void)
{
    if (perp_balloon_pages) {
        memory_listener_unregister(&perp_balloon_listener);
        perp_balloon_forget();
        g_hash_table_destroy(perp_balloon_pages);
        perp_balloon_pages = NULL;
        migrate_del_blocker(&perp_balloon_migration_blocker);
    }
}

/* Called with all vCPUs paused, from the main-loop bottom half. Keep the
 * hypervisor's slot bookkeeping unchanged: restore the exact same RAM mapping
 * before resuming any CPU. Never unmap a page containing an unballooned PFN.
 */
static bool perp_balloon_advise(PerpBalloonHostPage *page, int advice)
{
    hv_return_t status = hv_vm_unmap(page->gpa, page->size);
    if (status != HV_SUCCESS) {
        perp_balloon_failures++;
        error_report("balloon: HVF unmap failed: 0x%x", status);
        return false;
    }
    int rc = madvise(page->host, page->size, advice);
    int saved_errno = errno;
    status = hv_vm_map(page->host, page->gpa, page->size,
                       HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC);
    if (status != HV_SUCCESS) {
        /* Continuing with an absent mapping could corrupt the guest. */
        error_report("balloon: cannot restore HVF RAM mapping: 0x%x", status);
        abort();
    }
    if (rc) {
        perp_balloon_failures++;
        error_report("balloon: macOS memory advice failed: %s",
                     strerror(saved_errno));
        return false;
    }
    return true;
}

static bool perp_balloon_page(MemoryRegion *mr, hwaddr mr_offset,
                              hwaddr pa, bool inflate)
{
    if (!perp_balloon_pages) {
        return false;
    }
    void *host = memory_region_get_ram_ptr(mr) + mr_offset;
    ram_addr_t offset;
    RAMBlock *rb = qemu_ram_block_from_host(host, false, &offset);
    size_t size = qemu_ram_pagesize(rb);
    unsigned subpages = size / BALLOON_PAGE_SIZE;
    if (!subpages || subpages > 64 || !is_power_of_2(size)) {
        return false;
    }
    size_t within = offset & (size - 1);
    uint64_t gpa = pa - within;
    void *base = host - within;
    if (!QEMU_IS_ALIGNED(gpa, size) || !QEMU_PTR_IS_ALIGNED(base, size)) {
        return false;
    }
    PerpBalloonHostPage *page = g_hash_table_lookup(perp_balloon_pages, &gpa);
    if (!page && !inflate) {
        return true;
    }
    if (!page) {
        page = g_new0(PerpBalloonHostPage, 1);
        *page = (PerpBalloonHostPage){.gpa = gpa, .host = base, .size = size};
        g_hash_table_insert(perp_balloon_pages, &page->gpa, page);
    }
    /* A RAM topology listener must have invalidated an old mapping first. */
    assert(page->host == base && page->size == size);
    uint64_t bit = UINT64_C(1) << (within / BALLOON_PAGE_SIZE);
    uint64_t full = UINT64_MAX >> (64 - subpages);
    if (inflate) {
        page->mask |= bit;
        if (page->mask == full && !page->reusable &&
            perp_balloon_advise(page, MADV_FREE_REUSABLE)) {
            page->reusable = true;
            perp_balloon_reclaimed += size;
            perp_balloon_reusable += size;
        }
    } else {
        if (page->reusable) {
            /* Revoke reuse for the entire host page before returning even
             * one of its 4 KiB subpages to the guest's allocator.
             */
            if (!perp_balloon_advise(page, MADV_FREE_REUSE)) {
                error_report("balloon: cannot revoke macOS reclaim hint");
                abort();
            }
            page->reusable = false;
            perp_balloon_reused += size;
            perp_balloon_reusable -= size;
        }
        page->mask &= ~bit;
        if (!page->mask) {
            g_hash_table_remove(perp_balloon_pages, &gpa);
        }
    }
    return true;
}

static char *perp_balloon_stats(Object *obj, Error **errp)
{
    VirtIOBalloon *balloon = VIRTIO_BALLOON(obj);
    MachineState *machine = MACHINE(qdev_get_machine());
    uint64_t ram = machine->ram_size + get_plugged_memory_size();
    uint64_t inflated = (uint64_t)balloon->actual << VIRTIO_BALLOON_PFN_SHIFT;
    return g_strdup_printf("{\"version\":1,\"enabled\":%s,\"reclaimedBytes\":%" PRIu64
        ",\"reusedBytes\":%" PRIu64 ",\"reusableBytes\":%" PRIu64
        ",\"failures\":%" PRIu64 ",\"ramBytes\":%" PRIu64
        ",\"baseBytes\":%" PRIu64 ",\"inflatedBytes\":%" PRIu64
        ",\"trackedHostPages\":%u}",
        perp_balloon_pages ? "true" : "false", perp_balloon_reclaimed,
        perp_balloon_reused, perp_balloon_reusable, perp_balloon_failures,
        ram, (uint64_t)machine->ram_size, inflated,
        perp_balloon_pages ? g_hash_table_size(perp_balloon_pages) : 0);
}
#else
static bool perp_balloon_reclaim_enabled(void) { return false; }
static bool perp_balloon_reclaim_init(Error **errp) { return true; }
static void perp_balloon_reclaim_cleanup(void) { }
static void perp_balloon_forget(void) { }
static bool perp_balloon_page(MemoryRegion *mr, hwaddr offset,
                              hwaddr pa, bool inflate) { return false; }
static char *perp_balloon_stats(Object *obj, Error **errp)
{ return g_strdup("{\"enabled\":false}"); }
#endif
