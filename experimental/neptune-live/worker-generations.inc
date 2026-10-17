/* SPDX-License-Identifier: MIT
 * Included after Export/dispose; caller holds the worker registry lock.
 * Slots hold previous immutable generations and a bounded idle cache. The
 * ordinary Export remains the current generation; source COM owners stay there. */
#define GENERATION_SLOTS 8u
#define GENERATION_IDLE 4u
static Export generations[GENERATION_SLOTS];
static uint64_t generation_allocations, generation_reuses, generation_abandon_requests, generation_abandoned;
static uint64_t generation_peak_bytes;
static unsigned generation_peak_held;

static bool generation_key(const Export *a, const Export *b) {
    return a->ctx && a->ctx == b->ctx && a->blob_id == b->blob_id && a->object_id == b->object_id &&
        a->layout.size == b->source_bytes;
}
static bool generation_needed(const Export *slot, Export **chosen, unsigned count) {
    for (unsigned i=0; i<count; i++)
        if ((chosen[i]->busy || !chosen[i]->snapshot) && generation_key(slot, chosen[i])) return true;
    return false;
}
static void generation_measure(void) {
    unsigned held = 0;
    for (unsigned i=0; i<GENERATION_SLOTS; i++) held += generations[i].ctx && generations[i].busy;
    if (held > generation_peak_held) generation_peak_held = held;
    if (live_snapshot_bytes > generation_peak_bytes) generation_peak_bytes = live_snapshot_bytes;
}
static bool generation_prepare(Export **chosen, unsigned count) {
    if (count > LIVE_MAX_CANDIDATES) return false;
    for (unsigned i=0; i<count; i++) {
        if (!chosen[i] || !chosen[i]->ctx || !chosen[i]->source_bytes || chosen[i]->source_bytes > LIVE_MAX_BYTES) return false;
        for (unsigned j=0; j<i; j++)
            if (chosen[i] == chosen[j] || (chosen[i]->ctx == chosen[j]->ctx &&
                chosen[i]->blob_id == chosen[j]->blob_id && chosen[i]->object_id == chosen[j]->object_id)) return false;
    }
    bool reserved[GENERATION_SLOTS] = {0}; int slots[LIVE_MAX_CANDIDATES];
    uint64_t needed = 0, reclaimed = 0;
    for (unsigned i=0; i<count; i++) {
        slots[i] = -1;
        if (chosen[i]->busy || !chosen[i]->snapshot) needed += chosen[i]->source_bytes;
        if (!chosen[i]->busy) continue;
        for (unsigned pass=0; pass<3 && slots[i]<0; pass++)
            for (unsigned j=0; j<GENERATION_SLOTS; j++) {
                Export *slot = &generations[j];
                if (reserved[j] || slot->busy) continue;
                bool usable = pass == 0 ? !slot->ctx : pass == 1 ?
                    slot->ctx && !generation_needed(slot,chosen,count) : true;
                if (usable) { slots[i] = (int)j; reserved[j] = true; reclaimed += slot->layout.size; break; }
            }
        if (slots[i] < 0) return false;
    }
    for (unsigned i=0; i<count; i++) if (chosen[i]->busy || !chosen[i]->snapshot)
        for (unsigned j=0; j<GENERATION_SLOTS; j++)
            if (!reserved[j] && !generations[j].busy && generation_key(&generations[j],chosen[i])) {
                needed -= chosen[i]->source_bytes; break;
            }
    if (live_snapshot_bytes > LIVE_MAX_BYTES) return false;
    for (unsigned j=0; needed > LIVE_MAX_BYTES-live_snapshot_bytes+reclaimed && j<GENERATION_SLOTS; j++)
        if (!reserved[j] && generations[j].ctx && !generations[j].busy &&
            !generation_needed(&generations[j],chosen,count)) dispose(&generations[j]);
    if (needed > LIVE_MAX_BYTES-live_snapshot_bytes+reclaimed) return false;
    for (unsigned i=0; i<count; i++) if (chosen[i]->busy) {
        Export *slot = &generations[slots[i]], *entry = chosen[i];
        if (slot->ctx) dispose(slot); // only ACK-retired idle storage can be evicted
        *slot = *entry; slot->texture = slot->owner = slot->writer = NULL;
        entry->snapshot = NULL; entry->event = NULL; entry->fence = NULL;
        memset(&entry->layout,0,sizeof(entry->layout));
        entry->busy = false; entry->value = 0; entry->generation = 0;
    }
    generation_measure(); return true;
}
static bool generation_reuse(Export *entry) {
    if (entry->snapshot) return true;
    for (unsigned i=0; i<GENERATION_SLOTS; i++) {
        Export *slot = &generations[i];
        if (!slot->busy && slot->snapshot && generation_key(slot,entry)) {
            entry->snapshot = slot->snapshot; entry->layout = slot->layout;
            memset(slot,0,sizeof(*slot)); generation_reuses++; return true;
        }
    }
    return false;
}
static Export *generation_find(struct npt_context *ctx, uint32_t generation) {
    for (unsigned i=0; i<GENERATION_SLOTS; i++)
        if (generations[i].ctx == ctx && generations[i].busy && generations[i].generation == generation)
            return &generations[i];
    return NULL;
}
/* Event/fence have already been closed after checking actual GPU completion.
 * On abandonment the allocation MUST disappear, even if an old consumer still
 * retains duplicated FDs/mappings. Kernel lifetime preserves those old bytes. */
static void generation_retire(Export *entry, bool abandon) {
    bool held = false;
    for (unsigned i=0; i<GENERATION_SLOTS; i++) held |= entry == &generations[i];
    if (abandon) {
        generation_abandon_requests++;
        if (entry->snapshot) { live_snapshot_bytes -= entry->layout.size; release(&entry->snapshot); generation_abandoned++; }
        memset(&entry->layout,0,sizeof(entry->layout)); entry->busy = false;
        if (held) memset(entry,0,sizeof(*entry));
        return;
    }
    entry->busy = false;
    if (held) {
        unsigned idle = 0; bool duplicate = false;
        for (unsigned i=0; i<GENERATION_SLOTS; i++) if (&generations[i] != entry && generations[i].ctx && !generations[i].busy) {
            idle++; if (generation_key(&generations[i],entry)) duplicate = true;
        }
        if (idle >= GENERATION_IDLE || duplicate) dispose(entry);
    }
}
static void generation_destroy_context(struct npt_context *ctx) {
    for (unsigned i=0; i<GENERATION_SLOTS; i++) if (generations[i].ctx == ctx) dispose(&generations[i]);
}
static bool generation_blob_busy(struct npt_context *ctx, uint64_t blob) {
    for (unsigned i=0; i<GENERATION_SLOTS; i++)
        if (generations[i].ctx == ctx && generations[i].blob_id == blob && generations[i].busy) return true;
    return false;
}
static void generation_forget_blob(struct npt_context *ctx, uint64_t blob) {
    for (unsigned i=0; i<GENERATION_SLOTS; i++)
        if (generations[i].ctx == ctx && generations[i].blob_id == blob && !generations[i].busy) dispose(&generations[i]);
}
