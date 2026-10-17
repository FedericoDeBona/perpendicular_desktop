#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Opt-in private host v3: bounded immutable generations, guest Wire1 unchanged.

Applied after the matched descriptor port, only to a fresh private source tree.
This extension retains every owner/import/fence admission check in host v2.
"""
from pathlib import Path


def replace(text, before, after):
    if text.count(before) != 1:
        raise RuntimeError('Unique generation anchor changed: ' + before[:100])
    return text.replace(before, after, 1)


def apply(private: Path, root: Path):
    for name in ('snapshot.c', 'worker-signal.inc', 'worker-suffix.inc', 'live.h', 'broker.h', 'proxy-broker.c', 'wire.c'):
        path = private / name
        text = path.read_text()
        # Explicit private host bump; DMTX's native descriptor version stays 2.
        if name == 'broker.h':
            text = replace(text, '#define PERP_BROKER_VERSION 2u', '#define PERP_BROKER_VERSION 3u')
        else:
            for before, after in (('h->version!=2', 'h->version!=3'), ('h->version=2', 'h->version=3'),
                                  ('.version=2', '.version=3'), ('p->version!=2', 'p->version!=3'),
                                  ('packet->version!=2', 'packet->version!=3')):
                text = text.replace(before, after)
        path.write_text(text)
    (private / 'worker-generations.inc').write_text((root / 'experimental/neptune-live/worker-generations.inc').read_text())
    path = private / 'snapshot.c'; text = path.read_text()
    text = replace(text, '    uint64_t value;', '    uint64_t value,source_bytes;')
    text = replace(text, '\nvoid perp_snapshot_context_created', '\n#include "worker-generations.inc"\n\nvoid perp_snapshot_context_created')
    text = replace(text, '    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx) dispose(&entries[i]);',
        '    generation_destroy_context(ctx);\n    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx) dispose(&entries[i]);')
    text = replace(text, '.texture=tex,.owner=owner,.writer=writer };', '.texture=tex,.owner=owner,.writer=writer,.source_bytes=layout->size };')
    text = replace(text, '    if(entry->snapshot) return true;', '    if(generation_reuse(entry)) return true;')
    text = replace(text, '    entry->layout=*layout; live_snapshot_bytes+=layout->size; return true;',
        '    entry->layout=*layout; live_snapshot_bytes+=layout->size; generation_allocations++; generation_measure(); return true;')
    # Keep resource deletion conservative even when the busy allocation is now
    # in the retained-generation registry rather than the current Export.
    text = replace(text, '    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx && entries[i].blob_id==blob_id) {',
        '    if(generation_blob_busy(ctx,blob_id)) {invalid_scope=true; rejected_scope++;}\n'
        '    generation_forget_blob(ctx,blob_id);\n'
        '    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx && entries[i].blob_id==blob_id) {')
    text = replace(text, 'ack.status>1', 'ack.status>2')
    text = replace(text, '    if(!entry || !entry->fence ||', '    if(!entry)entry=generation_find(ctx,ack.generation);\n    if(!entry || !entry->fence ||')
    text = replace(text, '    release((void **)&entry->fence); entry->busy=false; acked++;',
        '    release((void **)&entry->fence); generation_retire(entry,ack.status==2); acked++;')
    # The live Signal is embedded into snapshot.c by the pre-existing recipe.
    text = replace(text, '    for(unsigned i=0;i<count;i++)if(chosen[i]->busy) {dropped_busy++;goto no_capture;}',
        '    if(!generation_prepare(chosen,count)) {dropped_busy++;goto no_capture;}')
    path.write_text(text)

    path = private / 'live.h'; text = path.read_text()
    text = replace(text, 'LIVE_DENIED,LIVE_FAULT };', 'LIVE_DENIED,LIVE_FAULT,LIVE_POOL_STATS };')
    text = replace(text, '#define LIVE_MAX_CANDIDATES 4u', '#define LIVE_MAX_CANDIDATES 4u\n#define LIVE_MAX_PENDING 8u\n'
        '/* Producer-owned allocation statistics, sampled after actual ACK processing. */\n'
        'typedef struct PerpLivePoolStats {\n'
        '    uint64_t allocations,reuses,abandon_requests,abandoned,peak_bytes,peak_held,retirements;\n'
        '} PerpLivePoolStats;')
    text = replace(text, 'LIVE_PUBLIC void perp_live_scanout_done',
        'LIVE_PUBLIC int perp_live_scanout_ready_fd(const PerpLiveLease *lease);\n'
        'LIVE_PUBLIC void perp_live_scanout_abandon(const PerpLiveLease *lease);\n'
        'LIVE_PUBLIC void perp_live_scanout_done')
    path.write_text(text)

    path = private / 'worker-suffix.inc'; text = path.read_text()
    text = replace(text, 'h->status<=1', 'h->status<=2')
    text = replace(text, 'lock();PerpBrokerHeader reply=*h;reply.kind=PERP_ACKED;good=live_emit(&reply,NULL,0,NULL,0);unlock();return good;',
        'lock();PerpBrokerHeader reply=*h;reply.kind=PERP_ACKED;good=live_emit(&reply,NULL,0,NULL,0);\n'
        '        PerpLivePoolStats stats={generation_allocations,generation_reuses,generation_abandon_requests,\n'
        '            generation_abandoned,generation_peak_bytes,generation_peak_held,acked};\n'
        '        PerpBrokerHeader pool={.kind=LIVE_POOL_STATS};\n'
        '        if(good)good=live_emit(&pool,&stats,sizeof(stats),NULL,0);unlock();return good;')
    anchor = '        PerpBrokerHeader reply=*h;reply.kind=LIVE_DENIED;'
    text = replace(text, anchor,
        '        for(unsigned i=0;good && i<GENERATION_SLOTS;i++)if(generations[i].ctx==live_context && generations[i].blob_id==h->blob_id && generations[i].busy) {\n'
        '            Export *entry=&generations[i];\n'
        '            while(VTABLE(PFN_ID3D11Fence_GetCompletedValue,entry->fence,NPT_VTBL_ID3D11Fence_GetCompletedValue)(entry->fence)<entry->value) {\n'
        '                if(live_now()>=deadline) {good=false;break;}\n'
        '                thrd_sleep(&(struct timespec){.tv_nsec=1000000},NULL);\n'
        '            }\n        }\n' + anchor)
    text = replace(text, '        if(good)for(unsigned i=0;i<MAX_EXPORTS;i++) {',
        '        for(unsigned i=0;i<GENERATION_SLOTS;i++)if(generations[i].busy)good=false;\n'
        '        if(good)generation_destroy_context(live_context);\n'
        '        if(good)for(unsigned i=0;i<MAX_EXPORTS;i++) {')
    path.write_text(text)

    path = private / 'proxy-broker.c'; text = path.read_text()
    text = replace(text, '    uint32_t retired_batch;', '    uint32_t retired_batch;\n    PerpLivePoolStats pool;')
    text = replace(text, 'static LiveFrame frames[LIVE_MAX_CANDIDATES];', 'static LiveFrame frames[LIVE_MAX_PENDING];\nstatic PerpLivePoolStats pool;\nstatic uint64_t abandoned;')
    # Only frame loops grow; source identity metadata has its own bound.
    import re
    text = re.sub(r'for\(unsigned ([ij])=0;\1<LIVE_MAX_CANDIDATES;\1\+\+\)(?=if\(frames\[)',
                  lambda m: m.group(0).replace('LIVE_MAX_CANDIDATES', 'LIVE_MAX_PENDING'), text)
    text = replace(text, 'i<LIVE_MAX_CANDIDATES;i++)pending|=frames[i].used;', 'i<LIVE_MAX_PENDING;i++)pending|=frames[i].used;')
    text = replace(text, 'i<LIVE_MAX_CANDIDATES;i++)pending+=frames[i].used;', 'i<LIVE_MAX_PENDING;i++)pending+=frames[i].used;')
    text = replace(text, 'static void retire(LiveFrame *f,bool read)', 'static void retire_status(LiveFrame *f,unsigned status)')
    text = replace(text, 'ack.status=read?0:1;', 'ack.status=status;')
    text = replace(text, 'if(read)completed++;else cancelled++;', 'if(status==0)completed++;else if(status==2)abandoned++;else cancelled++;')
    text = replace(text, 'static void fail_worker(', 'static void retire(LiveFrame *f,bool read) {retire_status(f,read?0:1);}\nstatic void fail_worker(')
    anchor = '    if(h->kind==PERP_ACKED && h->bytes==sizeof(*h) && !h->fd_count)return true;'
    text = replace(text, anchor, anchor + '\n'
        '    if(h->kind==LIVE_POOL_STATS && h->bytes==sizeof(*h)+sizeof(pool) && !h->fd_count) {\n'
        '        const PerpLivePoolStats *next=body;\n'
        '        if(next->peak_bytes>LIVE_MAX_BYTES || next->peak_held>8 || next->abandoned>next->abandon_requests ||\n'
        '           next->allocations<w->pool.allocations || next->reuses<w->pool.reuses || next->abandon_requests<w->pool.abandon_requests ||\n'
        '           next->abandoned<w->pool.abandoned || next->peak_bytes<w->pool.peak_bytes || next->peak_held<w->pool.peak_held ||\n'
        '           next->retirements<w->pool.retirements)return false;\n'
        '        pool.allocations+=next->allocations-w->pool.allocations;pool.reuses+=next->reuses-w->pool.reuses;\n'
        '        pool.abandon_requests+=next->abandon_requests-w->pool.abandon_requests;pool.abandoned+=next->abandoned-w->pool.abandoned;\n'
        '        pool.retirements+=next->retirements-w->pool.retirements;\n'
        '        if(next->peak_bytes>pool.peak_bytes)pool.peak_bytes=next->peak_bytes;\n'
        '        if(next->peak_held>pool.peak_held)pool.peak_held=next->peak_held;w->pool=*next;return true;\n    }')
    # A newer ready generation supersedes only never-leased storage. Leased
    # older epochs must remain pinned until their exact consumer retirement.
    text = replace(text, '    LiveFrame *frame=NULL;uint64_t bytes=p->texture.size,count=1;\n    for(unsigned i=0;i<LIVE_MAX_CANDIDATES;i++) {',
        '    for(unsigned i=0;i<LIVE_MAX_PENDING;i++)if(frames[i].used && !frames[i].leased &&\n'
        '        frames[i].header.resource_id==r->id && ready(&frames[i]))retire(&frames[i],false);\n'
        '    LiveFrame *frame=NULL;uint64_t bytes=p->texture.size,count=1;\n    for(unsigned i=0;i<LIVE_MAX_PENDING;i++) {')
    text = replace(text, 'count++;if(frames[i].header.resource_id==r->id)return false;', 'count++;')
    # Bind every callback/getter to the full identity, including old worker
    # epochs retained over reset. Never infer identity from a recycled fd.
    begin = text.index('void perp_live_scanout_done(')
    end = text.index('\nvoid perp_live_renderer_reset', begin)
    text = text[:begin] + '''static LiveFrame *leased_frame(const PerpLiveLease *lease)
{
    if(!lease || lease->version!=3)return NULL;
    for(unsigned i=0;i<LIVE_MAX_PENDING;i++)if(frames[i].used && frames[i].leased) {
        PerpBrokerHeader *h=&frames[i].header;
        if(h->resource_id==lease->resource_id && h->context_id==lease->context_id && h->worker_epoch==lease->worker_epoch &&
           h->resource_epoch==lease->resource_epoch && h->blob_id==lease->blob_id && h->snapshot_generation==lease->generation)return &frames[i];
    }
    return NULL;
}
int perp_live_scanout_ready_fd(const PerpLiveLease *lease)
{
    LiveFrame *frame=leased_frame(lease);return frame && ready(frame)?dup(frame->fds[1]):-1;
}
static void retire_lease(const PerpLiveLease *lease,unsigned status)
{
    LiveFrame *frame=leased_frame(lease);if(!frame)return;
    PerpBrokerHeader *h=&frame->header;LiveWorker *w=worker(h->context_id);
    if(w && w->epoch==h->worker_epoch && h->status>w->retired_batch)w->retired_batch=h->status;
    retire_status(frame,status);
    for(unsigned j=0;j<LIVE_MAX_PENDING;j++)if(frames[j].used && !frames[j].leased && frames[j].header.resource_id!=selected && ready(&frames[j]))retire(&frames[j],false);
}
void perp_live_scanout_done(const PerpLiveLease *lease,bool read) {retire_lease(lease,read?0:1);}
void perp_live_scanout_abandon(const PerpLiveLease *lease) {retire_lease(lease,2);}
''' + text[end:]
    # Receipt exposes actual worker allocations rather than estimating from
    # broker descriptors, which omit the ACK-retired cache.
    text = replace(text, '    char *result=NULL;asprintf(&result,', '    char *base=NULL;asprintf(&base,')
    text = replace(text, 'permanently_failed?"true":"false");return result;',
        'permanently_failed?"true":"false");\n'
        '    char *result=NULL;asprintf(&result,"%.*s,\\\"abandoned\\\":%llu,\\\"worker_allocations\\\":%llu,\\\"worker_reuses\\\":%llu,\\\"worker_abandon_requests\\\":%llu,\\\"worker_abandoned\\\":%llu,\\\"worker_peak_bytes\\\":%llu,\\\"worker_peak_retained\\\":%llu,\\\"worker_retirements\\\":%llu}",\n'
        '        (int)strlen(base)-1,base,(unsigned long long)abandoned,(unsigned long long)pool.allocations,(unsigned long long)pool.reuses,\n'
        '        (unsigned long long)pool.abandon_requests,(unsigned long long)pool.abandoned,(unsigned long long)pool.peak_bytes,(unsigned long long)pool.peak_held,(unsigned long long)pool.retirements);\n'
        '    free(base);return result;')
    path.write_text(text)
