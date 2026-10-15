/* SPDX-License-Identifier: MIT
 * Development worker embedding the actual render_context_main and Neptune ring.
 * Native object bootstrap is fixture-only; it is never a guest command. */
#include "npt_context.h"
#include "npt_library.h"
#include "snapshot.h"
#include "wire.h"
#include "broker.h"
#include "render_context.h"
#include <poll.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

#define VTABLE(type,obj,slot) NPT_COM_VTBL_FUNC(type,npt_com_vtable(obj),slot)
static struct npt_context *context;
static int channel=-1,ack_pair[2]={-1,-1};
static uint64_t session,epoch;
static uint32_t context_id,width,height;
static PerpBrokerHeader binding;
static uint64_t export_blob,export_object,claim_blob;
static uint32_t claim_resource;
static bool failed,retired;
static once_flag once=ONCE_FLAG_INIT;
static mtx_t guard;
static ID3D11Device *device;
static ID3D11DeviceContext *base;
static void *device5,*writer,*fence;
static ID3D11Texture2D *texture,*staging;
static ID3D11RenderTargetView *view;
static void initialize(void) { mtx_init(&guard,mtx_plain); }
static void lock(void) { call_once(&once,initialize); mtx_lock(&guard); }
static void unlock(void) { mtx_unlock(&guard); }
static void require(bool good,const char *stage)
{
    if(!good) { fprintf(stderr,"worker fixture: %s errno=%d\n",stage,errno); exit(2); }
}
static void hr(HRESULT result,const char *stage) { require(NPT_SUCCEEDED(result),stage); }
static void *query(void *object,const GUID *iid)
{
    void *value=NULL; hr(npt_com_query_interface(object,iid,&value),"QueryInterface"); require(value,"QI value"); return value;
}
static PerpBrokerHeader header(unsigned kind)
{
    return (PerpBrokerHeader){.magic=PERP_BROKER_MAGIC,.version=PERP_BROKER_VERSION,
        .kind=kind,.bytes=sizeof(PerpBrokerHeader),.session=session,.worker_epoch=epoch,.context_id=context_id};
}
/* Sender calls are serialized. At most 248 bytes and two rights. A short or
 * blocked send invalidates capture; retrying rights could duplicate ownership.
 * A dedicated nonblocking bounded queue is still required for production. */
static bool emit(PerpBrokerHeader *h,const void *body,size_t size,const int *fds,unsigned count)
{
    if(failed || size>176 || count>2) return false;
    unsigned char bytes[248]; h->bytes=sizeof(*h)+size; h->fd_count=count;
    memcpy(bytes,h,sizeof(*h)); if(size) memcpy(bytes+sizeof(*h),body,size);
    struct iovec io={bytes,h->bytes}; struct msghdr message={.msg_iov=&io,.msg_iovlen=1};
    union { struct cmsghdr align; char bytes[CMSG_SPACE(2*sizeof(int))]; } rights={0};
    if(count) {
        message.msg_control=rights.bytes; message.msg_controllen=CMSG_SPACE(count*sizeof(int));
        struct cmsghdr *c=CMSG_FIRSTHDR(&message); c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;
        c->cmsg_len=CMSG_LEN(count*sizeof(int));memcpy(CMSG_DATA(c),fds,count*sizeof(int));
    }
    if(sendmsg(channel,&message,MSG_DONTWAIT)!=(ssize_t)h->bytes) { failed=true;return false; }
    return true;
}
static void bootstrap(struct npt_context *ctx)
{
    struct npt_d3d_library *lib=npt_renderer_get_library(); D3D_FEATURE_LEVEL level=0;
    hr(lib->pfn_D3D11CreateDevice(NULL,1,0,0x20,NULL,0,7,&device,&level,&base),"Hardware DXMT device");
    device5=query(device,&NPT_IID_ID3D11Device5);writer=query(base,&NPT_IID_ID3D11DeviceContext4);
    hr(VTABLE(PFN_ID3D11Device5_CreateFence,device5,NPT_VTBL_ID3D11Device5_CreateFence)(device5,0,0,&NPT_IID_ID3D11Fence,&fence),"Fence");
    D3D11_TEXTURE2D_DESC d={0};d.Width=width;d.Height=height;d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;
    d.Format=87;d.BindFlags=0x8|0x20;d.MiscFlags=0x2|DXN_MISC_LINEAR_EXPORT;
    hr(VTABLE(PFN_ID3D11Device_CreateTexture2D,device,NPT_VTBL_ID3D11Device_CreateTexture2D)(device,&d,NULL,&texture),"Texture");
    hr(VTABLE(PFN_ID3D11Device_CreateRenderTargetView,device,NPT_VTBL_ID3D11Device_CreateRenderTargetView)(device,(void *)texture,NULL,&view),"View");
    d.Usage=3;d.CPUAccessFlags=0x20000;d.BindFlags=d.MiscFlags=0;
    hr(VTABLE(PFN_ID3D11Device_CreateTexture2D,device,NPT_VTBL_ID3D11Device_CreateTexture2D)(device,&d,NULL,&staging),"Staging");
    npt_context_register_object(ctx,1,writer,NPT_OBJECT_TYPE_ID3D11DEVICECONTEXT4);
    npt_context_register_object(ctx,2,fence,NPT_OBJECT_TYPE_ID3D11FENCE);
    npt_context_register_object(ctx,3,view,NPT_OBJECT_TYPE_ID3D11RENDERTARGETVIEW);
    npt_context_register_object(ctx,4,texture,NPT_OBJECT_TYPE_ID3D11TEXTURE2D);
}
void perp_worker_created(struct npt_context *ctx)
{
    require(!context && ctx->ctx_id==context_id,"One actual context per worker");context=ctx;
    require(perp_snapshot_fixture_admit(ctx,ack_pair[0]),"Attach closed fixture registry");
    bootstrap(ctx);lock();PerpBrokerHeader h=header(PERP_HELLO);emit(&h,NULL,0,NULL,0);unlock();
}
void perp_worker_destroying(struct npt_context *ctx)
{
    require(context==ctx,"Context destruction identity");
    lock();binding.resource_epoch=0;context=NULL;unlock();
    /* Ring threads and snapshot leases have drained. Release while the real
     * backend library still exists; main's render_state_fini later unloads it. */
    if(view)npt_com_release(view);if(staging)npt_com_release(staging);if(texture)npt_com_release(texture);
    if(fence)npt_com_release(fence);if(writer)npt_com_release(writer);if(device5)npt_com_release(device5);
    if(base)npt_com_release(base);if(device)npt_com_release(device);
}
void perp_worker_export(struct npt_context *ctx,uint64_t object,uint64_t blob)
{
    /* Deterministic development interleaving: pending blob already exists,
     * but its ring-side broker observation is held behind control claims. */
    const char *delay=getenv("PERP_BROKER_EXPORT_DELAY_US");
    if(delay) {unsigned us=atoi(delay);require(us<=500000,"Bounded interleaving delay");usleep(us);}
    lock();
    if(ctx!=context || (export_blob && (export_blob!=blob || export_object!=object))) failed=true;
    else {export_blob=blob;export_object=object;PerpBrokerHeader h=header(PERP_EXPORT);h.blob_id=blob;h.object_id=object;emit(&h,NULL,0,NULL,0);}
    unlock();
}
void perp_worker_claim(uint32_t ctx,uint32_t resource,uint64_t blob,bool good,bool begin)
{
    lock();
    if(ctx!=context_id) failed=true;
    else {
        PerpBrokerHeader h=header(begin?PERP_CLAIM_BEGIN:PERP_CLAIM);h.resource_id=resource;h.blob_id=blob;h.status=good;
        if(!begin && good && blob) {
            if(claim_resource && (claim_resource!=resource || claim_blob!=blob)) failed=true;
            claim_resource=resource;claim_blob=blob;
        }
        emit(&h,NULL,0,NULL,0);
    }
    unlock();
}
void perp_worker_resource(uint32_t ctx,uint32_t resource,bool destroy)
{
    lock();
    if(ctx!=context_id) failed=true;
    else {
        if(resource==claim_resource) retired=true;
        PerpBrokerHeader h=header(destroy?PERP_DESTROY:PERP_IMPORT);h.resource_id=resource;emit(&h,NULL,0,NULL,0);
    }
    unlock();
    if(destroy && resource==claim_resource) perp_snapshot_forget_export(context,claim_blob);
}
void perp_worker_import_result(uint32_t ctx,uint32_t resource,bool good)
{
    lock();
    if(ctx!=context_id)failed=true;
    else {PerpBrokerHeader h=header(PERP_IMPORT_RESULT);h.resource_id=resource;h.status=good;emit(&h,NULL,0,NULL,0);}
    unlock();
}
bool perp_worker_capture_allowed(struct npt_context *ctx,uint64_t blob,uint64_t object)
{
    lock();bool ok=!failed && !retired && ctx==context && binding.resource_epoch &&
        binding.blob_id==blob && binding.object_id==object;unlock();return ok;
}
int perp_snapshot_send(int ignored,const PerpSnapshotPacket *packet,int memory_fd,int ready_fd)
{
    (void)ignored;lock();PerpBrokerHeader h=binding;h.kind=PERP_FRAME;h.snapshot_generation=packet->generation;
    int fds[]={memory_fd,ready_fd};bool ok=!failed && h.resource_epoch && emit(&h,packet,sizeof(*packet),fds,2);unlock();return ok?0:-1;
}
static bool same_binding(const PerpBrokerHeader *h)
{
    return h->resource_id==binding.resource_id && h->resource_epoch==binding.resource_epoch &&
        h->blob_id==binding.blob_id && h->object_id==binding.object_id;
}
static void verify_overwrite(void)
{
    struct npt_d3d_library *lib=npt_renderer_get_library();
    void *verify_fence=NULL;
    hr(VTABLE(PFN_ID3D11Device5_CreateFence,device5,NPT_VTBL_ID3D11Device5_CreateFence)(
        device5,0,0,&NPT_IID_ID3D11Fence,&verify_fence),"Independent verification fence");
    VTABLE(PFN_ID3D11DeviceContext_CopyResource,writer,NPT_VTBL_ID3D11DeviceContext_CopyResource)(writer,(void *)staging,(void *)texture);
    void *event=lib->pfn_event_create(1,0);require(event,"Verification event");int fd=lib->pfn_event_dup_fd(event);require(fd>=0,"Verification fd");
    hr(VTABLE(PFN_ID3D11Fence_SetEventOnCompletion,verify_fence,NPT_VTBL_ID3D11Fence_SetEventOnCompletion)(verify_fence,1,(HANDLE)(uintptr_t)event),"Verify registration");
    hr(VTABLE(PFN_ID3D11DeviceContext4_Signal,writer,NPT_VTBL_ID3D11DeviceContext4_Signal)(writer,verify_fence,1),"Verify Signal");
    struct pollfd p={fd,POLLIN,0};require(poll(&p,1,5000)==1 && p.revents&POLLIN,"Verify GPU complete");close(fd);lib->pfn_event_close(event);
    D3D11_MAPPED_SUBRESOURCE map={0};hr(VTABLE(PFN_ID3D11DeviceContext_Map,writer,NPT_VTBL_ID3D11DeviceContext_Map)(writer,(void *)staging,0,1,0,&map),"Verify Map");
    require(map.pData && map.RowPitch>=width*4,"Verify row pitch");
    for(unsigned y=0;y<height;y++) for(unsigned x=0;x<width;x++) {
        uint8_t *p=(uint8_t *)map.pData+(size_t)y*map.RowPitch+x*4;
        require(p[0]==255 && p[1]==0 && p[2]==255 && p[3]==255,"Original overwritten magenta");
    }
    VTABLE(PFN_ID3D11DeviceContext_Unmap,writer,NPT_VTBL_ID3D11DeviceContext_Unmap)(writer,(void *)staging,0);
    npt_com_release(verify_fence);
}
bool perp_worker_command(uint32_t ctx,const void *data,size_t bytes)
{
    if(bytes!=sizeof(PerpBrokerHeader)) return false;
    const PerpBrokerHeader *h=data;
    if(ctx!=context_id || h->magic!=PERP_BROKER_MAGIC || h->version!=1 || h->bytes!=bytes || h->fd_count ||
       h->session!=session || h->worker_epoch!=epoch || h->context_id!=context_id) return false;
    if(h->kind==PERP_BIND) {
        lock();bool good=!failed && !retired && !binding.resource_epoch && h->resource_epoch &&
            h->resource_id==claim_resource && h->blob_id==claim_blob && h->blob_id==export_blob && h->object_id==export_object &&
            !h->snapshot_generation && !h->status;
        if(good) {binding=*h;PerpBrokerHeader reply=binding;reply.kind=PERP_BOUND;good=emit(&reply,NULL,0,NULL,0);}
        unlock();return good;
    }
    if(h->kind==PERP_ACK) {
        lock();bool good=!failed && same_binding(h) && h->snapshot_generation && h->status<=1;unlock();
        if(!good) return false;
        PerpSnapshotAck ack={PERP_SNAPSHOT_MAGIC,h->snapshot_generation,h->status,0};
        if(send(ack_pair[1],&ack,sizeof(ack),0)!=(ssize_t)sizeof(ack) || !perp_snapshot_drain_ack(context,false)) return false;
        lock();bool forget=retired;unlock();
        if(forget)perp_snapshot_forget_export(context,h->blob_id);
        lock();PerpBrokerHeader reply=*h;reply.kind=PERP_ACKED;good=emit(&reply,NULL,0,NULL,0);unlock();return good;
    }
    if(h->kind==PERP_UNBIND) {
        lock();bool good=same_binding(h);
        if(good) {retired=true;PerpBrokerHeader reply=*h;reply.kind=PERP_BOUND;reply.status=1;good=emit(&reply,NULL,0,NULL,0);}
        unlock();return good;
    }
    if(h->kind==PERP_VERIFY) {verify_overwrite();lock();PerpBrokerHeader reply=header(PERP_VERIFIED);bool good=emit(&reply,NULL,0,NULL,0);unlock();return good;}
    if(h->kind==PERP_STATUS) {
        char *stats=perp_snapshot_stats();printf("{\"epoch\":%"PRIu64",\"registry\":%s}\n",epoch,stats);free(stats);fflush(stdout);
        lock();PerpBrokerHeader reply=header(PERP_STATS);bool good=emit(&reply,NULL,0,NULL,0);unlock();return good;
    }
    return false;
}
int main(int argc,char **argv)
{
    if(argc==2 && !strcmp(argv[1],"--schema")) {
        printf("{\"clear\":%u,\"signal\":%u,\"export\":%u,\"ring_create\":%u,\"ring_notify\":%u,\"ring_destroy\":%u,\"create_ring_size\":%zu}\n",
            NPT_CMD_TYPE(255,NPT_IFACE_ID_ID3D11DeviceContext1,NPT_METHOD_ID3D11DeviceContext1_ClearView),
            NPT_CMD_TYPE(255,NPT_IFACE_ID_ID3D11DeviceContext4,NPT_METHOD_ID3D11DeviceContext4_Signal),
            NPT_TRANSPORT_CMD_TYPE(NPT_TRANSPORT_SUBGROUP_SHARED,NPT_TRANSPORT_SHARED_EXPORT_BLOB),
            NPT_TRANSPORT_CMD_TYPE(NPT_TRANSPORT_SUBGROUP_RING,NPT_TRANSPORT_RING_CREATE),
            NPT_TRANSPORT_CMD_TYPE(NPT_TRANSPORT_SUBGROUP_RING,NPT_TRANSPORT_RING_NOTIFY),
            NPT_TRANSPORT_CMD_TYPE(NPT_TRANSPORT_SUBGROUP_RING,NPT_TRANSPORT_RING_DESTROY),sizeof(struct npt_cmd_create_ring));return 0;
    }
    require(argc==9,"controlfd brokerfd session epoch context width height fixture-token");
    require(!strcmp(argv[8],"host-fixture-only"),"Explicit development bootstrap");
    int control=atoi(argv[1]);channel=atoi(argv[2]);session=strtoull(argv[3],NULL,10);epoch=strtoull(argv[4],NULL,10);
    context_id=atoi(argv[5]);width=atoi(argv[6]);height=atoi(argv[7]);
    require(session && epoch && context_id && width>=640 && height>=480 && width<=1920 && height<=1080,"Fixture bounds");
    int enabled=1;require(!setsockopt(channel,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled)),"No SIGPIPE");
    require(!socketpair(AF_UNIX,SOCK_STREAM,0,ack_pair),"Internal ACK queue");
    struct render_context_args args={.valid=true,.init_flags=(1u<<7)|(1u<<15),.ctx_id=context_id,.ctx_fd=control};
    strcpy(args.ctx_name,"broker-host-fixture");render_log_init();(void)render_context_main(&args);
    close(ack_pair[0]);close(ack_pair[1]);close(channel);return 0;
}
