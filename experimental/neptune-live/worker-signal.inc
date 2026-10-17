/* SPDX-License-Identifier: MIT
 * Replace the single-candidate development Signal hook in a private copy.
 * Capture every explicitly granted candidate of one verified immediate writer,
 * because the later SET_SCANOUT_BLOB may select any of those exact resources. */
HRESULT perp_snapshot_signal(struct npt_context *ctx,void *writer,ID3D11Fence *fence,
                              uint64_t value,PFN_ID3D11DeviceContext4_Signal original)
{
    lock();Export *chosen[LIVE_MAX_CANDIDATES]={0};unsigned count=0;
    int ready[LIVE_MAX_CANDIDATES]={-1,-1,-1,-1};
    if(admitted!=ctx || contexts!=1 || invalid_scope || live_faulted || !live_enabled ||
       atomic_load(&ctx->multi_ring) || !fence || !value) {rejected_scope++;goto no_capture;}
    if(live_context==ctx && fence) {
        if(!live_fence) {live_fence=fence;npt_com_add_ref(fence);}
        /* SetEventOnCompletion on an old/already-satisfied value could signal
         * before our newly inserted copies. A prior queued higher value has
         * the same hazard, even when it has not completed yet. */
        if(!identical(fence,live_fence) || !value || value<=live_last_fence_value ||
           VTABLE(PFN_ID3D11Fence_GetCompletedValue,fence,NPT_VTBL_ID3D11Fence_GetCompletedValue)(fence)>=value) {
            live_fault_locked();goto no_capture;
        }
        live_last_fence_value=value;
    }
    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx) {
        LiveClaim *claim=live_claim_blob(entries[i].blob_id);
        if(!claim || !claim->granted || claim->denied)continue;
        /* Validate the actual selected source and its writer. Unselected
         * metadata neither authorizes a read nor consumes snapshot storage. */
        if(!identical(writer,entries[i].writer)) {rejected_owner++;live_fault_locked();goto no_capture;}
        ID3D11Device *fence_owner=NULL;
        VTABLE(PFN_ID3D11DeviceChild_GetDevice,fence,NPT_VTBL_ID3D11DeviceChild_GetDevice)(fence,&fence_owner);
        bool same_owner=fence_owner && identical(fence_owner,entries[i].owner);release((void **)&fence_owner);
        if(!same_owner) {rejected_owner++;live_fault_locked();goto no_capture;}
        if(count>=LIVE_MAX_CANDIDATES) {live_fault_locked();goto no_capture;}
        chosen[count++]=&entries[i];
    }
    if(!count) {rejected_scope++;goto no_capture;}
    for(unsigned i=0;i<count;i++)if(chosen[i]->busy) {dropped_busy++;goto no_capture;}
    if(++live_capture_batch==0) {live_fault_locked();goto no_capture;}
    struct npt_d3d_library *lib=npt_renderer_get_library();
    if(!lib || !lib->pfn_event_create || !lib->pfn_event_dup_fd || !lib->pfn_event_close)goto no_capture;
    /* Allocate and validate the whole bounded plan before enqueueing copies. */
    for(unsigned i=0;i<count;i++) {
        Export *e=chosen[i];
        if(!allocate_snapshot(e)) {rejected_layout++;live_fault_locked();goto cleanup;}
        e->event=lib->pfn_event_create(1,0);
        if(!e->event || (ready[i]=lib->pfn_event_dup_fd(e->event))<0) {live_fault_locked();goto cleanup;}
    }
    for(unsigned i=0;i<count;i++) {
        /* Deliberately unready consumer token for a causal diskless test.
         * The real Signal still uses value and the actual GPU copy completes. */
        bool withheld=getenv("PERP_LIVE_TEST_WITHHOLD") && !strcmp(getenv("PERP_LIVE_TEST_WITHHOLD"),"1");
        HRESULT hr=VTABLE(PFN_ID3D11Fence_SetEventOnCompletion,fence,NPT_VTBL_ID3D11Fence_SetEventOnCompletion)(
            fence,withheld?UINT64_MAX:value,(HANDLE)(uintptr_t)chosen[i]->event);
        if(NPT_FAILED(hr)) {live_fault_locked();goto cleanup;}
    }
    for(unsigned i=0;i<count;i++)
        VTABLE(PFN_ID3D11DeviceContext_CopyResource,writer,NPT_VTBL_ID3D11DeviceContext_CopyResource)(writer,chosen[i]->snapshot,chosen[i]->texture);
    for(unsigned i=0;i<count;i++) {
        Export *e=chosen[i];e->busy=true;e->fence=fence;npt_com_add_ref(fence);e->value=value;
        if(++sequence==0)live_fault_locked();e->generation=sequence;
    }
    HRESULT result=original(writer,fence,value);
    if(NPT_FAILED(result))live_fault_locked();
    for(unsigned i=0;i<count;i++) {
        Export *e=chosen[i];LiveClaim *claim=live_claim_blob(e->blob_id);
        if(!live_faulted) {
            PerpSnapshotPacket packet={.magic=PERP_SNAPSHOT_MAGIC,.version=1,.generation=e->generation,
                .context_id=ctx->ctx_id,.blob_id=e->blob_id,.texture=e->layout};packet.texture.fd=-1;
            PerpBrokerHeader h={.kind=PERP_FRAME,.resource_id=claim->resource,.resource_epoch=claim->epoch,
                .blob_id=e->blob_id,.object_id=e->object_id,.snapshot_generation=e->generation,.status=live_capture_batch};
            int fds[]={e->layout.fd,ready[i]};
            if(live_emit(&h,&packet,sizeof(packet),fds,2))captures++;else live_fault_locked();
        }
        close(ready[i]);
    }
    unlock();return result;
cleanup:
    for(unsigned i=0;i<count;i++) {
        if(ready[i]>=0)close(ready[i]);
        if(chosen[i]->event) {lib->pfn_event_close(chosen[i]->event);chosen[i]->event=NULL;}
    }
no_capture:
    unlock();return original(writer,fence,value);
}
