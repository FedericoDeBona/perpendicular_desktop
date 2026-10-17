/* SPDX-License-Identifier: MIT */
static LiveClaim *live_claim_blob(uint64_t blob)
{
    for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)if(live_claims[i].blob==blob && blob)return &live_claims[i];return NULL;
}
static bool live_emit(PerpBrokerHeader *h,const void *body,size_t bytes,const int *fds,unsigned count)
{
    if(live_broker<0 || bytes>176 || count>2)return false;
    h->magic=PERP_BROKER_MAGIC;h->version=PERP_BROKER_VERSION;h->bytes=sizeof(*h)+bytes;h->fd_count=count;
    h->session=live_session;h->worker_epoch=live_epoch;h->context_id=live_context->ctx_id;
    unsigned char packet[248];memcpy(packet,h,sizeof(*h));if(bytes)memcpy(packet+sizeof(*h),body,bytes);
    struct iovec io={packet,h->bytes};struct msghdr message={.msg_iov=&io,.msg_iovlen=1};
    union {struct cmsghdr align;char bytes[CMSG_SPACE(2*sizeof(int))];} rights={0};
    if(count) {
        message.msg_control=rights.bytes;message.msg_controllen=CMSG_SPACE(count*sizeof(int));
        struct cmsghdr *c=CMSG_FIRSTHDR(&message);c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;
        c->cmsg_len=CMSG_LEN(count*sizeof(int));memcpy(CMSG_DATA(c),fds,count*sizeof(int));
    }
    return sendmsg(live_broker,&message,MSG_DONTWAIT)==(ssize_t)h->bytes;
}
static void live_fault_locked(void)
{
    if(!live_faulted) {PerpBrokerHeader h={.kind=LIVE_FAULT};(void)live_emit(&h,NULL,0,NULL,0);}
    live_faulted=true;live_enabled=false;
}
bool perp_live_worker_import(struct npt_context *ctx,uint32_t resource)
{
    lock();bool good=ctx==live_context;
    /* Incoming textures are inputs, not automatically scanout sources. An
     * owned export can be reopened only after its exact DENY handshake has
     * stopped future capture and completed every already queued GPU copy.
     * Foreign exports are tainted by the VM-global proxy before attachment. */
    for(unsigned i=0;good && i<LIVE_MAX_SOURCES;i++)if(live_claims[i].resource==resource && resource) {
        good=live_claims[i].denied && live_claims[i].import_safe;
        if(!good) {rejected_import++;live_fault_locked();}
        break;
    }
    unlock();return good;
}
void perp_live_worker_imported(struct npt_context *ctx,void *texture)
{
    lock();void *key=identity(texture);void **slot=NULL;
    if(ctx!=live_context || !key) {release(&key);live_fault_locked();unlock();return;}
    for(unsigned i=0;i<LIVE_MAX_SOURCES;i++) {
        if(live_imported[i]==key) {release(&key);unlock();return;}
        if(!live_imported[i])slot=&live_imported[i];
    }
    if(slot)*slot=key;
    else {release(&key);live_fault_locked();}
    unlock();
}
bool perp_live_worker_source(struct npt_context *ctx,void *texture)
{
    lock();void *key=identity(texture);bool good=ctx==live_context && key && !live_faulted;
    for(unsigned i=0;good && i<LIVE_MAX_SOURCES;i++)if(live_imported[i]==key)good=false;
    release(&key);unlock();return good;
}
void perp_live_worker_created(struct npt_context *ctx) {live_context=ctx;}
void perp_live_worker_stopped(struct npt_context *ctx)
{
    if(live_context!=ctx)return;
    for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)release(&live_imported[i]);
    release((void **)&live_fence);live_last_fence_value=0;
    if(live_broker>=0)close(live_broker);
    if(live_acks[0]>=0)close(live_acks[0]);if(live_acks[1]>=0)close(live_acks[1]);
    live_broker=live_acks[0]=live_acks[1]=-1;live_context=NULL;
}
void perp_live_worker_claim(uint32_t ctx,uint32_t resource,uint64_t blob)
{
    if(!blob || !live_context || ctx!=live_context->ctx_id)return;
    lock();LiveClaim *claim=live_claim_blob(blob);
    for(unsigned i=0;i<LIVE_MAX_SOURCES && !claim;i++)if(!live_claims[i].blob)claim=&live_claims[i];
    if(!claim || (claim->resource && claim->resource!=resource))live_fault_locked();
    else {claim->blob=blob;claim->resource=resource;PerpBrokerHeader h={.kind=PERP_CLAIM,.resource_id=resource,.blob_id=blob,.status=1};if(!live_emit(&h,NULL,0,NULL,0))live_fault_locked();}
    unlock();
}
void perp_live_worker_resource_destroy(uint32_t ctx,uint32_t resource)
{
    if(!live_context || ctx!=live_context->ctx_id)return;
    lock();uint64_t blob=0;
    for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)if(live_claims[i].resource==resource) {
        blob=live_claims[i].blob;live_claims[i].denied=true;live_claims[i].granted=false;
    }
    unlock();if(blob)perp_snapshot_forget_export(live_context,blob);
}
bool perp_live_worker_export(struct npt_context *ctx,uint64_t object,uint64_t blob)
{
    lock();bool valid=ctx==live_context && !invalid_scope;
    PerpBrokerHeader h={.kind=PERP_EXPORT,.blob_id=blob,.object_id=object};
    if(valid)valid=live_emit(&h,NULL,0,NULL,0);if(!valid)live_fault_locked();unlock();return valid;
}
bool perp_live_worker_command(uint32_t ctx,const void *bytes,size_t count,const int *fds,unsigned fd_count)
{
    if(count!=sizeof(PerpBrokerHeader) || !live_context || ctx!=live_context->ctx_id)return false;
    const PerpBrokerHeader *h=bytes;
    if(h->magic!=PERP_BROKER_MAGIC || h->version!=1 || h->bytes!=count || h->fd_count!=fd_count || h->context_id!=ctx)return false;
    if(h->kind==LIVE_ATTACH) {
        if(live_broker>=0 || fd_count!=1 || !h->session || !h->worker_epoch ||
           !getenv("PERP_NEPTUNE_SCANOUT_BROKER") || strcmp(getenv("PERP_NEPTUNE_SCANOUT_BROKER"),"1"))return false;
        int enabled=1,pair[2];
        if(setsockopt(fds[0],SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled)) || socketpair(AF_UNIX,SOCK_STREAM,0,pair))return false;
        if(!perp_snapshot_worker_admit(live_context,pair[0])) {close(pair[0]);close(pair[1]);return false;}
        live_session=h->session;live_epoch=h->worker_epoch;live_broker=fds[0];
        live_acks[0]=pair[0];live_acks[1]=pair[1];
        lock();PerpBrokerHeader hello={.kind=PERP_HELLO};bool good=live_emit(&hello,NULL,0,NULL,0);unlock();
        /* On false the original dispatcher still owns and closes fds[0]. */
        if(!good)live_broker=-1;
        return good;
    }
    if(fd_count || h->session!=live_session || h->worker_epoch!=live_epoch)return false;
    if(h->kind==LIVE_GRANT) {
        lock();LiveClaim *claim=live_claim_blob(h->blob_id);Export *entry=NULL;
        for(unsigned i=0;i<MAX_EXPORTS;i++)if(entries[i].ctx==live_context && entries[i].blob_id==h->blob_id)entry=&entries[i];
        bool good=!live_faulted && claim && !claim->denied && claim->resource==h->resource_id && h->resource_epoch &&
            entry && entry->object_id==h->object_id;
        if(good) {
            /* Old immutable leases remain ACK-able through their identity. Only
             * the selected source participates in future GPU copies. */
            for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)live_claims[i].granted=false;
            claim->epoch=h->resource_epoch;claim->object=h->object_id;claim->granted=true;
        }
        unlock();return good;
    }
    if(h->kind==LIVE_ENABLE) {
        lock();bool good=!live_faulted && !invalid_scope && contexts==1 && !atomic_load(&live_context->multi_ring);
        if(good)live_enabled=true;unlock();return good;
    }
    if(h->kind==PERP_ACK) {
        lock();LiveClaim *claim=live_claim_blob(h->blob_id);
        bool good=claim && claim->resource==h->resource_id && claim->epoch==h->resource_epoch && claim->object==h->object_id &&
            h->snapshot_generation && h->status<=1;unlock();
        if(!good)return false;
        PerpSnapshotAck ack={PERP_SNAPSHOT_MAGIC,h->snapshot_generation,h->status,0};
        if(send(live_acks[1],&ack,sizeof(ack),MSG_DONTWAIT)!=(ssize_t)sizeof(ack) || !perp_snapshot_drain_ack(live_context,false))return false;
        lock();PerpBrokerHeader reply=*h;reply.kind=PERP_ACKED;good=live_emit(&reply,NULL,0,NULL,0);unlock();return good;
    }
    if(h->kind==LIVE_DENY) {
        lock();LiveClaim *claim=live_claim_blob(h->blob_id);bool good=claim && claim->resource==h->resource_id && claim->epoch==h->resource_epoch;
        if(good)claim->denied=true;
        /* No new copy can be queued while this lock is held. Wait only for
         * already queued copies before acknowledging that another worker may
         * import/write the original. Consumer snapshots remain immutable. */
        uint64_t deadline=live_now()+1000000000ull;
        for(unsigned i=0;good && i<MAX_EXPORTS;i++)if(entries[i].blob_id==h->blob_id && entries[i].busy) {
            while(VTABLE(PFN_ID3D11Fence_GetCompletedValue,entries[i].fence,NPT_VTBL_ID3D11Fence_GetCompletedValue)(entries[i].fence)<entries[i].value) {
                if(live_now()>=deadline) {good=false;break;}
                thrd_sleep(&(struct timespec){.tv_nsec=1000000},NULL);
            }
        }
        PerpBrokerHeader reply=*h;reply.kind=LIVE_DENIED;if(good)good=live_emit(&reply,NULL,0,NULL,0);
        if(good)claim->import_safe=true;
        unlock();return good;
    }
    if(h->kind==LIVE_REVOKE) {
        lock();live_enabled=false;bool good=true;
        for(unsigned i=0;i<MAX_EXPORTS;i++)if(entries[i].busy)good=false;
        if(good)for(unsigned i=0;i<MAX_EXPORTS;i++) {
            Export *entry=&entries[i];
            if(entry->snapshot) {live_snapshot_bytes-=entry->layout.size;release(&entry->snapshot);memset(&entry->layout,0,sizeof(entry->layout));}
        }
        for(unsigned i=0;i<LIVE_MAX_SOURCES;i++)live_claims[i].granted=false;
        PerpBrokerHeader reply={.kind=LIVE_REVOKED};if(good)good=live_emit(&reply,NULL,0,NULL,0);unlock();return good;
    }
    return false;
}
