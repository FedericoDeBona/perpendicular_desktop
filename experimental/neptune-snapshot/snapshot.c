/* SPDX-License-Identifier: MIT
 * Bounded experimental single-owner snapshot registry. Production admission
 * remains closed until a VM-global worker broker proves writer exclusivity. */
#include "npt_context.h"
#include "npt_library.h"
#include "snapshot.h"
#include "wire.h"
#include <poll.h>
#include <sys/socket.h>
#include <stdio.h>
#include <unistd.h>

#define MAX_EXPORTS 8
#define MAX_PIXELS (8u*1024u*1024u)
#define MAX_SNAPSHOT_BYTES (64u*1024u*1024u)
#define VTABLE(type,obj,slot) NPT_COM_VTBL_FUNC(type,npt_com_vtable(obj),slot)

typedef struct Export {
    struct npt_context *ctx;
    uint64_t object_id,blob_id;
    void *texture,*owner,*writer,*snapshot;
    dxn_shared_texture layout;
    void *event;
    ID3D11Fence *fence;
    uint64_t value;
    uint32_t generation;
    bool busy;
} Export;
static Export entries[MAX_EXPORTS];
static once_flag once=ONCE_FLAG_INIT;
static mtx_t mutex;
static unsigned contexts;
static struct npt_context *admitted;
static int channel=-1;
static bool invalid_scope;
static uint32_t sequence;
static uint64_t captures,acked,dropped_busy,rejected_owner,rejected_import,rejected_scope,rejected_layout;

static void initialize(void) { mtx_init(&mutex,mtx_plain); }
static void lock(void) { call_once(&once,initialize); mtx_lock(&mutex); }
static void unlock(void) { mtx_unlock(&mutex); }
static void release(void **value) { if(*value) npt_com_release(*value); *value=NULL; }
static void *identity(void *value)
{
    void *result=NULL;
    if(value) npt_com_query_interface(value,&NPT_IID_IUnknown,&result);
    return result;
}
static bool identical(void *a,void *b)
{
    void *ia=identity(a),*ib=identity(b);
    bool equal=ia && ia==ib; release(&ia); release(&ib); return equal;
}
static void dispose(Export *entry)
{
    struct npt_d3d_library *lib=npt_renderer_get_library();
    if(entry->event && lib) lib->pfn_event_close(entry->event);
    release((void **)&entry->fence); release(&entry->snapshot);
    release(&entry->writer); release(&entry->owner); release(&entry->texture);
    memset(entry,0,sizeof(*entry));
}

void perp_snapshot_context_created(struct npt_context *ctx)
{
    (void)ctx; lock(); contexts++;
    if(admitted && contexts!=1) { invalid_scope=true; rejected_scope++; }
    unlock();
}
void perp_snapshot_context_destroying(struct npt_context *ctx)
{
    lock();
    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx) dispose(&entries[i]);
    if(admitted==ctx) { admitted=NULL; channel=-1; }
    if(contexts) contexts--;
    if(!contexts) invalid_scope=false;
    unlock();
}
bool perp_snapshot_fixture_admit(struct npt_context *ctx,int fd)
{
    lock(); bool valid=contexts==1 && !admitted && !invalid_scope && fd>=0;
    if(valid) { admitted=ctx; channel=fd; } else rejected_scope++;
    unlock(); return valid;
}
void perp_snapshot_import(struct npt_context *ctx,uint32_t res_id)
{
    (void)ctx; (void)res_id;
    lock(); invalid_scope=true; rejected_import++; unlock();
}

void perp_snapshot_export(struct npt_context *ctx,uint64_t object_id,uint64_t blob_id,
                          void *texture,const dxn_shared_texture *layout)
{
    lock();
    if(admitted!=ctx || invalid_scope || contexts!=1) { rejected_scope++; unlock(); return; }
    if(!dxn_shared_check(layout,DXN_SHARED_TEXTURE_MAGIC,sizeof(*layout)) ||
       !layout->meta.width || !layout->meta.height || layout->meta.width>4096 || layout->meta.height>4096 ||
       (uint64_t)layout->meta.width*layout->meta.height>MAX_PIXELS || layout->meta.dxgi_format!=87 ||
       layout->meta.mip_levels!=1 || layout->meta.array_size!=1 || layout->meta.sample_count!=1 ||
       layout->meta.cpu_access_flags || layout->meta.usage!=0 || layout->plane_count!=1 ||
       layout->drm_modifier || layout->planes[0].offset || layout->size>MAX_SNAPSHOT_BYTES) {
        rejected_layout++; unlock(); return;
    }
    Export *entry=NULL;
    for(unsigned i=0;i<MAX_EXPORTS;i++) {
        if(entries[i].ctx==ctx && entries[i].blob_id==blob_id) {
            if(!identical(entries[i].texture,texture)) { invalid_scope=true; rejected_owner++; }
            unlock(); return;
        }
        if(!entries[i].ctx) entry=&entries[i];
    }
    if(!entry) { rejected_layout++; unlock(); return; }
    void *tex=NULL,*owner=NULL,*writer=NULL;
    if(NPT_FAILED(npt_com_query_interface(texture,&NPT_IID_ID3D11Texture2D,&tex)) || !tex) goto invalid;
    VTABLE(PFN_ID3D11DeviceChild_GetDevice,tex,NPT_VTBL_ID3D11DeviceChild_GetDevice)(tex,(ID3D11Device **)&owner);
    if(!owner) goto invalid;
    VTABLE(PFN_ID3D11Device_GetImmediateContext,owner,NPT_VTBL_ID3D11Device_GetImmediateContext)(owner,(ID3D11DeviceContext **)&writer);
    if(!writer || VTABLE(PFN_ID3D11DeviceContext_GetType,writer,NPT_VTBL_ID3D11DeviceContext_GetType)(writer)!=0) goto invalid;
    *entry=(Export){ .ctx=ctx,.object_id=object_id,.blob_id=blob_id,.texture=tex,.owner=owner,.writer=writer };
    unlock(); return;
invalid:
    release(&tex); release(&owner); release(&writer); rejected_owner++; unlock();
}

void perp_snapshot_forget_export(struct npt_context *ctx,uint64_t blob_id)
{
    lock();
    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx && entries[i].blob_id==blob_id) {
        if(entries[i].busy) { invalid_scope=true; rejected_scope++; }
        else dispose(&entries[i]);
    }
    unlock();
}

static bool allocate_snapshot(Export *entry)
{
    if(entry->snapshot) return true;
    D3D11_TEXTURE2D_DESC desc={0};
    VTABLE(PFN_ID3D11Texture2D_GetDesc,entry->texture,NPT_VTBL_ID3D11Texture2D_GetDesc)(entry->texture,&desc);
    desc.MiscFlags=0x2u|DXN_MISC_LINEAR_EXPORT; // SHARED; original remains untouched.
    desc.CPUAccessFlags=0; desc.Usage=0; desc.BindFlags=0x8u|0x20u;
    HRESULT hr=VTABLE(PFN_ID3D11Device_CreateTexture2D,entry->owner,NPT_VTBL_ID3D11Device_CreateTexture2D)(
        entry->owner,&desc,NULL,(ID3D11Texture2D **)&entry->snapshot);
    if(NPT_FAILED(hr) || !entry->snapshot) goto invalid;
    void *resource=NULL; HANDLE handle=0;
    npt_com_query_interface(entry->snapshot,&NPT_IID_IDXGIResource,&resource);
    if(!resource) goto invalid;
    hr=VTABLE(PFN_IDXGIResource_GetSharedHandle,resource,NPT_VTBL_IDXGIResource_GetSharedHandle)(resource,&handle);
    release(&resource);
    const dxn_shared_texture *layout=(const void *)(uintptr_t)handle;
    if(NPT_FAILED(hr) || !dxn_shared_check(layout,DXN_SHARED_TEXTURE_MAGIC,sizeof(*layout)) ||
       layout->size>MAX_SNAPSHOT_BYTES || layout->fd<0) goto invalid;
    entry->layout=*layout; return true;
invalid:
    release(&entry->snapshot); memset(&entry->layout,0,sizeof(entry->layout)); return false;
}

bool perp_snapshot_drain_ack(struct npt_context *ctx,bool wait)
{
    lock();
    if(admitted!=ctx || channel<0) { unlock(); return false; }
    struct pollfd fd={channel,POLLIN,0};
    int result=poll(&fd,1,wait?5000:0);
    if(result==0) { unlock(); return !wait; }
    PerpSnapshotAck ack={0};
    ssize_t count=recv(channel,&ack,sizeof(ack),MSG_DONTWAIT|MSG_PEEK);
    if(count<0 && (errno==EAGAIN || errno==EWOULDBLOCK)) { unlock(); return !wait; }
    if(result<0 || fd.revents&(POLLHUP|POLLERR|POLLNVAL) || count!=(ssize_t)sizeof(ack) ||
       ack.magic!=PERP_SNAPSHOT_MAGIC || ack.reserved || ack.status>1) goto invalid;
    Export *entry=NULL;
    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx && entries[i].busy && entries[i].generation==ack.generation) entry=&entries[i];
    if(!entry || !entry->fence || VTABLE(PFN_ID3D11Fence_GetCompletedValue,entry->fence,NPT_VTBL_ID3D11Fence_GetCompletedValue)(entry->fence)<entry->value) goto invalid;
    if(recv(channel,&ack,sizeof(ack),MSG_DONTWAIT)!=(ssize_t)sizeof(ack)) goto invalid;
    struct npt_d3d_library *lib=npt_renderer_get_library();
    lib->pfn_event_close(entry->event); entry->event=NULL;
    release((void **)&entry->fence); entry->busy=false; acked++;
    unlock(); return true;
invalid:
    invalid_scope=true; rejected_scope++; unlock(); return false;
}

HRESULT perp_snapshot_signal(struct npt_context *ctx,void *writer,ID3D11Fence *fence,
                              uint64_t value,PFN_ID3D11DeviceContext4_Signal original)
{
    lock();
    Export *entry=NULL; unsigned candidates=0;
    for(unsigned i=0;i<MAX_EXPORTS;i++) if(entries[i].ctx==ctx) { entry=&entries[i]; candidates++; }
    if(admitted!=ctx || contexts!=1 || invalid_scope || atomic_load(&ctx->multi_ring)) {
        rejected_scope++; goto no_capture;
    }
    if(candidates!=1 || !entry || !identical(writer,entry->writer) || !fence || !value) {
        rejected_owner++; goto no_capture;
    }
    if(entry->busy) { dropped_busy++; goto no_capture; }
    if(!allocate_snapshot(entry)) { rejected_layout++; goto no_capture; }
    struct npt_d3d_library *lib=npt_renderer_get_library();
    if(!lib || !lib->pfn_event_create || !lib->pfn_event_dup_fd || !lib->pfn_event_close) goto no_capture;
    entry->event=lib->pfn_event_create(1,0);
    if(!entry->event) goto no_capture;
    int ready=lib->pfn_event_dup_fd(entry->event);
    if(ready<0) { lib->pfn_event_close(entry->event); entry->event=NULL; goto no_capture; }
    bool withheld=getenv("PERP_SNAPSHOT_WITHHOLD") && !strcmp(getenv("PERP_SNAPSHOT_WITHHOLD"),"1");
    /* Development fault injection: actual copy completes, while its consumer
     * token remains unready. The reader must still refuse that snapshot. */
    HRESULT hr=VTABLE(PFN_ID3D11Fence_SetEventOnCompletion,fence,NPT_VTBL_ID3D11Fence_SetEventOnCompletion)(
        fence,withheld?UINT64_MAX:value,(HANDLE)(uintptr_t)entry->event);
    if(NPT_FAILED(hr)) { close(ready); lib->pfn_event_close(entry->event); entry->event=NULL; goto no_capture; }
    VTABLE(PFN_ID3D11DeviceContext_CopyResource,writer,NPT_VTBL_ID3D11DeviceContext_CopyResource)(writer,entry->snapshot,entry->texture);
    hr=original(writer,fence,value);
    if(NPT_FAILED(hr)) { close(ready); invalid_scope=true; rejected_scope++; unlock(); return hr; }
    entry->busy=true; entry->value=value; entry->fence=fence; npt_com_add_ref(fence);
    if(++sequence==0) { invalid_scope=true; close(ready); unlock(); return hr; }
    entry->generation=sequence;
    PerpSnapshotPacket packet={ .magic=PERP_SNAPSHOT_MAGIC,.version=1,.generation=sequence,
        .context_id=ctx->ctx_id,.blob_id=entry->blob_id,.texture=entry->layout };
    packet.texture.fd=-1;
    if(perp_snapshot_send(channel,&packet,entry->layout.fd,ready)<0) { invalid_scope=true; rejected_scope++; }
    else captures++;
    close(ready); unlock(); return hr;
no_capture:
    unlock(); return original(writer,fence,value);
}

char *perp_snapshot_stats(void)
{
    lock(); unsigned active=0,exports=0;
    for(unsigned i=0;i<MAX_EXPORTS;i++) { exports+=entries[i].ctx!=NULL; active+=entries[i].busy; }
    char *result=NULL;
    asprintf(&result,"{\"captures\":%"PRIu64",\"acked\":%"PRIu64",\"active\":%u,\"exports\":%u,"
        "\"dropped_busy\":%"PRIu64",\"rejected_owner\":%"PRIu64",\"rejected_import\":%"PRIu64","
        "\"rejected_scope\":%"PRIu64",\"rejected_layout\":%"PRIu64",\"contexts\":%u,\"invalid_scope\":%s}",
        captures,acked,active,exports,dropped_busy,rejected_owner,rejected_import,rejected_scope,rejected_layout,
        contexts,invalid_scope?"true":"false");
    unlock(); return result;
}
