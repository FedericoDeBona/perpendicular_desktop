/* SPDX-License-Identifier: MIT
 * Actual pinned Neptune command decoder with native DXMT; no guest machine. */
#include "npt_context.h"
#include "npt_library.h"
#include "npt_shared.h"
#include "snapshot.h"
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#define METHOD(type,obj,slot) NPT_COM_VTBL_FUNC(type,npt_com_vtable(obj),slot)
static void require(bool condition,const char *stage)
{
    if(!condition) { fprintf(stderr,"Neptune decoder fixture failed: %s (errno=%d)\n",stage,errno); exit(1); }
}
static void hr(HRESULT result,const char *stage)
{
    if(NPT_FAILED(result)) fprintf(stderr,"HRESULT=0x%08x stage=%s\n",(unsigned)result,stage);
    require(NPT_SUCCEEDED(result),stage);
}
static void control(int fd,char expected)
{
    char value=0; require(recv(fd,&value,1,0)==1 && value==expected,"Control transition");
}
static void notify(int fd,char value) { require(send(fd,&value,1,0)==1,"Control send"); }
static void *query(void *obj,const GUID *iid)
{
    void *value=NULL; hr(npt_com_query_interface(obj,iid,&value),"QueryInterface"); require(value,"QI value"); return value;
}
static void register_object(struct npt_context *ctx,uint64_t id,void *object,npt_object_type type)
{
    /* Keep the one native reference alive until unregister + local Release;
     * this host fixture owns both sides of that lifetime explicitly. */
    npt_context_register_object(ctx,id,object,type);
}
static void append(uint8_t *packet,size_t *size,const void *data,size_t bytes)
{
    require(*size+bytes<=256,"Bounded wire command"); memcpy(packet+*size,data,bytes); *size+=bytes;
}
static void clear(struct npt_context *ctx,const float rgba[4],const D3D11_RECT *rect)
{
    uint8_t packet[256]={0}; size_t size=sizeof(struct npt_command_header);
    struct npt_command_header *head=(void *)packet;
    head->cmd_type=NPT_CMD_TYPE(255,NPT_IFACE_ID_ID3D11DeviceContext1,NPT_METHOD_ID3D11DeviceContext1_ClearView);
    head->object_id=1;
    uint64_t view=3,count=4,rects=1; uint32_t rectangles=1;
    append(packet,&size,&view,8); append(packet,&size,&count,8); append(packet,&size,rgba,16);
    append(packet,&size,&rects,8); append(packet,&size,rect,sizeof(*rect)); append(packet,&size,&rectangles,4);
    head->cmd_size=size;
    require(npt_context_submit_cmd(ctx,packet,size),"Real ClearView wire decoder");
}
static void submit_signal(struct npt_context *ctx,uint64_t value)
{
    struct { struct npt_command_header header; uint64_t fence,value; } packet={0};
    packet.header.cmd_type=NPT_CMD_TYPE(255,NPT_IFACE_ID_ID3D11DeviceContext4,NPT_METHOD_ID3D11DeviceContext4_Signal);
    packet.header.object_id=1; packet.header.cmd_size=sizeof(packet); packet.fence=2; packet.value=value;
    require(npt_context_submit_cmd(ctx,&packet,sizeof(packet)),"Real Signal wire decoder");
}
static void export_texture(struct npt_context *ctx,uint64_t blob_id)
{
    struct npt_cmd_shared_export_blob packet={0};
    packet.header.cmd_type=NPT_TRANSPORT_CMD_TYPE(NPT_TRANSPORT_SUBGROUP_SHARED,NPT_TRANSPORT_SHARED_EXPORT_BLOB);
    packet.header.object_id=4; packet.header.cmd_size=sizeof(packet);
    packet.blob_id=blob_id; packet.data_res_id=9;
    require(npt_context_submit_cmd(ctx,&packet,sizeof(packet)),"Real shared export transport decoder");
}
static int metadata_fd(void)
{
    char name[32]; snprintf(name,sizeof(name),"/perp-npt-%u",arc4random());
    int fd=shm_open(name,O_CREAT|O_EXCL|O_RDWR,0600); require(fd>=0,"Create metadata shm");
    require(shm_unlink(name)==0 && ftruncate(fd,16384)==0,"Size/unlink metadata shm"); return fd;
}
int main(int argc,char **argv)
{
    require(argc==2 || argc==3,"Usage: decoder-fixture inherited-channel [guard]");
    const char *guard=argc==3?argv[2]:NULL;
    bool withheld=getenv("PERP_SNAPSHOT_WITHHOLD") && !strcmp(getenv("PERP_SNAPSHOT_WITHHOLD"),"1");
    int fd=atoi(argv[1]); struct timeval timeout={10,0}; int enabled=1;
    require(setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout))==0,"Socket timeout");
    require(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled))==0,"Socket no SIGPIPE");
    struct npt_renderer_callbacks callbacks={0}; require(npt_renderer_init(0,&callbacks),"Initialize real Neptune renderer");
    struct npt_context *ctx=npt_context_create(1,NULL,7,"fixture"); require(ctx,"Create actual Neptune context");
    if(!guard || strcmp(guard,"unadmitted")) require(perp_snapshot_fixture_admit(ctx,fd),"Closed-world admission");
    struct npt_d3d_library *lib=npt_renderer_get_library(); require(lib && lib->pfn_D3D11CreateDevice,"DXMT library");
    ID3D11Device *device=NULL; ID3D11DeviceContext *base=NULL; D3D_FEATURE_LEVEL level=0;
    hr(lib->pfn_D3D11CreateDevice(NULL,1,0,0x20,NULL,0,7,&device,&level,&base),"Create native hardware device");
    void *device5=query(device,&NPT_IID_ID3D11Device5);
    void *writer=query(base,&NPT_IID_ID3D11DeviceContext4);
    void *fence=NULL;
    hr(METHOD(PFN_ID3D11Device5_CreateFence,device5,NPT_VTBL_ID3D11Device5_CreateFence)(device5,0,0,&NPT_IID_ID3D11Fence,&fence),"Create native fence");
    register_object(ctx,1,writer,NPT_OBJECT_TYPE_ID3D11DEVICECONTEXT4);
    register_object(ctx,2,fence,NPT_OBJECT_TYPE_ID3D11FENCE);
    require(npt_context_import_resource(ctx,9,VIRGL_RESOURCE_FD_SHM,metadata_fd(),16384),"Import export metadata window");
    unsigned widths[]={800,1920,803,800},heights[]={600,1080,607,600};
    uint64_t value=0;
    for(unsigned size=0;size<4;size++) {
        D3D11_TEXTURE2D_DESC desc={0}; desc.Width=widths[size]; desc.Height=heights[size];
        if(guard && !strcmp(guard,"oversize")) { desc.Width=4097; desc.Height=16; }
        desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1; desc.Format=87; desc.BindFlags=0x8|0x20; desc.MiscFlags=0x2|DXN_MISC_LINEAR_EXPORT;
        ID3D11Texture2D *texture=NULL,*staging=NULL; ID3D11RenderTargetView *view=NULL;
        hr(METHOD(PFN_ID3D11Device_CreateTexture2D,device,NPT_VTBL_ID3D11Device_CreateTexture2D)(device,&desc,NULL,&texture),"Create original shared texture");
        hr(METHOD(PFN_ID3D11Device_CreateRenderTargetView,device,NPT_VTBL_ID3D11Device_CreateRenderTargetView)(device,(void *)texture,NULL,&view),"Create target view");
        D3D11_TEXTURE2D_DESC staging_desc=desc; staging_desc.Usage=3; staging_desc.BindFlags=0; staging_desc.MiscFlags=0; staging_desc.CPUAccessFlags=0x20000;
        hr(METHOD(PFN_ID3D11Device_CreateTexture2D,device,NPT_VTBL_ID3D11Device_CreateTexture2D)(device,&staging_desc,NULL,&staging),"Create staging verifier");
        register_object(ctx,3,view,NPT_OBJECT_TYPE_ID3D11RENDERTARGETVIEW);
        register_object(ctx,4,texture,NPT_OBJECT_TYPE_ID3D11TEXTURE2D);
        export_texture(ctx,100+size);
        if(guard) {
            struct npt_context *other_ctx=NULL;
            ID3D11Device *other_device=NULL; ID3D11DeviceContext *other_base=NULL;
            void *other_device5=NULL,*other_writer=NULL,*other_fence=NULL;
            if(!strcmp(guard,"multi-ring")) atomic_store(&ctx->multi_ring,true);
            else if(!strcmp(guard,"multi-context")) {
                other_ctx=npt_context_create(2,NULL,5,"other"); require(other_ctx,"Second real Neptune context");
            } else if(!strcmp(guard,"import")) {
                register_object(ctx,5,device,NPT_OBJECT_TYPE_ID3D11DEVICE);
                struct npt_cmd_shared_open_res command={0}; command.res_id=999;
                require(NPT_FAILED(npt_shared_open_res(ctx,5,&command)),"Unknown imported resource rejected");
                npt_context_unregister_object(ctx,5);
            } else if(!strcmp(guard,"ambiguous-export")) {
                export_texture(ctx,200);
            } else if(!strcmp(guard,"wrong-writer")) {
                hr(lib->pfn_D3D11CreateDevice(NULL,1,0,0x20,NULL,0,7,&other_device,&level,&other_base),"Second native device");
                other_device5=query(other_device,&NPT_IID_ID3D11Device5);
                other_writer=query(other_base,&NPT_IID_ID3D11DeviceContext4);
                hr(METHOD(PFN_ID3D11Device5_CreateFence,other_device5,NPT_VTBL_ID3D11Device5_CreateFence)(
                    other_device5,0,0,&NPT_IID_ID3D11Fence,&other_fence),"Other native fence");
                npt_context_unregister_object(ctx,1); npt_context_unregister_object(ctx,2);
                register_object(ctx,1,other_writer,NPT_OBJECT_TYPE_ID3D11DEVICECONTEXT4);
                register_object(ctx,2,other_fence,NPT_OBJECT_TYPE_ID3D11FENCE);
            } else require(!strcmp(guard,"unadmitted") || !strcmp(guard,"oversize"),"Known guard fixture");
            submit_signal(ctx,10);
            char *stats=perp_snapshot_stats();
            require(strstr(stats,"\"captures\":0"),"Guard exposed no snapshot");
            printf("{\"result\":\"pass\",\"guard\":\"%s\",\"registry\":%s}\n",guard,stats); free(stats); fflush(stdout);
            if(other_ctx) npt_context_destroy(other_ctx);
            if(other_device) {
                npt_context_unregister_object(ctx,1); npt_context_unregister_object(ctx,2);
                npt_com_release(other_fence); npt_com_release(other_writer); npt_com_release(other_device5);
                npt_com_release(other_base); npt_com_release(other_device);
            }
            perp_snapshot_forget_export(ctx,100+size); perp_snapshot_forget_export(ctx,200);
            npt_context_unregister_object(ctx,3); npt_context_unregister_object(ctx,4);
            npt_com_release(view); npt_com_release(texture); npt_com_release(staging);
            break;
        }
        for(unsigned generation=0;generation<2;generation++) {
            control(fd,'N');
            float colors[][4]={{1,0,0,1},{0,1,0,1},{0,0,1,1},{1,1,1,1}};
            for(unsigned q=0;q<4;q++) {
                D3D11_RECT rect={q%2?(LONG)(desc.Width/2):0,q/2?(LONG)(desc.Height/2):0,
                    q%2?(LONG)desc.Width:(LONG)(desc.Width/2),q/2?(LONG)desc.Height:(LONG)(desc.Height/2)};
                clear(ctx,colors[generation?3-q:q],&rect);
            }
            float cross[]={17.f/255,136.f/255,204.f/255,1};
            D3D11_RECT a={(LONG)(desc.Width/2),0,(LONG)(desc.Width/2)+1,(LONG)desc.Height};
            D3D11_RECT b={0,(LONG)(desc.Height/2),(LONG)desc.Width,(LONG)(desc.Height/2)+1};
            clear(ctx,cross,&a); clear(ctx,cross,&b);
            value+=10; submit_signal(ctx,value); submit_signal(ctx,value+1); // busy snapshot must never be rewritten.
            float overwrite[]={1,0,1,1}; D3D11_RECT whole={0,0,(LONG)desc.Width,(LONG)desc.Height};
            clear(ctx,overwrite,&whole);
            METHOD(PFN_ID3D11DeviceContext_CopyResource,writer,NPT_VTBL_ID3D11DeviceContext_CopyResource)(writer,(void *)staging,(void *)texture);
            void *event=lib->pfn_event_create(1,0); require(event,"Overwrite event");
            int ready=lib->pfn_event_dup_fd(event); require(ready>=0,"Overwrite completion fd");
            hr(METHOD(PFN_ID3D11Fence_SetEventOnCompletion,fence,NPT_VTBL_ID3D11Fence_SetEventOnCompletion)(fence,value+2,(HANDLE)(uintptr_t)event),"Overwrite event registration");
            hr(METHOD(PFN_ID3D11DeviceContext4_Signal,writer,NPT_VTBL_ID3D11DeviceContext4_Signal)(writer,fence,value+2),"Unhooked overwrite Signal");
            struct pollfd completion={ready,POLLIN,0}; require(poll(&completion,1,5000)==1 && completion.revents&POLLIN,"Overwrite GPU completion");
            close(ready); lib->pfn_event_close(event);
            D3D11_MAPPED_SUBRESOURCE map={0};
            hr(METHOD(PFN_ID3D11DeviceContext_Map,writer,NPT_VTBL_ID3D11DeviceContext_Map)(writer,(void *)staging,0,1,0,&map),"Verify overwrite map");
            require(map.pData && map.RowPitch>=desc.Width*4,"Overwrite row pitch");
            for(unsigned y=0;y<desc.Height;y++) for(unsigned x=0;x<desc.Width;x++) {
                uint8_t *p=(uint8_t *)map.pData+(size_t)y*map.RowPitch+x*4;
                require(p[0]==255 && p[1]==0 && p[2]==255 && p[3]==255,"Original magenta overwrite pixels");
            }
            METHOD(PFN_ID3D11DeviceContext_Unmap,writer,NPT_VTBL_ID3D11DeviceContext_Unmap)(writer,(void *)staging,0);
            notify(fd,'O');
            require(perp_snapshot_drain_ack(ctx,true),"Consumer exact ACK and snapshot release");
            char *stats=perp_snapshot_stats(); printf("{\"frame\":%u,\"registry\":%s}\n",size*2+generation+1,stats); free(stats); fflush(stdout);
            if(withheld) break;
        }
        perp_snapshot_forget_export(ctx,100+size);
        npt_context_unregister_object(ctx,3); npt_context_unregister_object(ctx,4);
        npt_com_release(view); npt_com_release(texture); npt_com_release(staging);
        if(withheld) break;
    }
    npt_context_unregister_object(ctx,1); npt_context_unregister_object(ctx,2);
    npt_com_release(writer); npt_com_release(base); npt_com_release(fence); npt_com_release(device5); npt_com_release(device);
    npt_context_destroy(ctx); npt_renderer_fini();
    char *stats=perp_snapshot_stats(); printf("{\"result\":\"pass\",\"registry\":%s}\n",stats); free(stats);
    close(fd); return 0;
}
