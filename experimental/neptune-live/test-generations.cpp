// SPDX-License-Identifier: MIT
// Real pinned native DXMT allocations/GPU writes; no guest, decoder or window.
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <dxmt-native/dxmt_native.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define LIVE_MAX_CANDIDATES 4u
#define LIVE_MAX_BYTES (64u*1024u*1024u)
struct npt_context { unsigned identity; };
typedef struct Export {
    npt_context *ctx;
    uint64_t object_id,blob_id;
    void *texture,*owner,*writer,*snapshot;
    dxmt_shared_texture_handle layout;
    void *event; ID3D11Fence *fence; uint64_t value,source_bytes;
    uint32_t generation; bool busy;
} Export;
static uint64_t live_snapshot_bytes;
static void release(void **value) { if (*value) static_cast<IUnknown *>(*value)->Release(); *value=nullptr; }
static void dispose(Export *e) {
    if (e->event) dxmt_event_close(e->event);
    release(reinterpret_cast<void **>(&e->fence));
    if (e->snapshot) live_snapshot_bytes-=e->layout.size;
    release(&e->snapshot); release(&e->texture); release(&e->owner); release(&e->writer);
    std::memset(e,0,sizeof(*e));
}
#include "worker-generations.inc"

template<class T> struct Com {
    T *ptr=nullptr;
    ~Com() { if (ptr) ptr->Release(); }
    T *operator->() { return ptr; }
};
static void check(bool value,const char *message) { if (!value) throw std::runtime_error(message); }
static void hr(HRESULT value,const char *message) { check(value>=0,message); }
static uint64_t allocations,pixels,sequence;
static void allocate(Export *e,ID3D11Device *device,unsigned width=64,unsigned height=32) {
    D3D11_TEXTURE2D_DESC d{};
    d.Width=width;d.Height=height;d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;
    d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
    d.MiscFlags=D3D11_RESOURCE_MISC_SHARED;
    Com<ID3D11Texture2D> texture; hr(device->CreateTexture2D(&d,nullptr,&texture.ptr),"native snapshot allocation");
    Com<IDXGIResource> resource;
    hr(texture->QueryInterface(__uuidof(IDXGIResource),reinterpret_cast<void **>(&resource.ptr)),"native shared resource");
    HANDLE h=nullptr;hr(resource->GetSharedHandle(&h),"native descriptor export");
    auto *layout=static_cast<dxmt_shared_texture_handle *>(h);
    check(layout && layout->magic==DXMT_SHARED_TEXTURE_MAGIC && layout->version==2 && layout->fd>=0,"actual DMTX v2");
    check(layout->size<=LIVE_MAX_BYTES-live_snapshot_bytes,"native allocation exceeds test registry budget");
    e->layout=*layout;e->source_bytes=layout->size;e->snapshot=texture.ptr;texture.ptr=nullptr;
    live_snapshot_bytes+=layout->size;allocations++;generation_allocations++;generation_measure();
}
static void fill(Export *e,ID3D11Device *device,ID3D11DeviceContext *context,ID3D11DeviceContext4 *writer,
                 ID3D11Fence *fence,float red,float green,float blue) {
    Com<ID3D11RenderTargetView> view;
    hr(device->CreateRenderTargetView(static_cast<ID3D11Texture2D *>(e->snapshot),nullptr,&view.ptr),"native render target");
    float color[]={red,green,blue,1};context->ClearRenderTargetView(view.ptr,color);
    e->event=dxmt_event_create(1,0);check(e->event,"native completion event");
    e->value=++sequence;e->generation=static_cast<uint32_t>(sequence);e->busy=true;
    e->fence=fence;fence->AddRef();
    hr(fence->SetEventOnCompletion(e->value,e->event),"native completion subscription");
    hr(writer->Signal(fence,e->value),"native GPU signal");context->Flush();
    check(dxmt_event_wait(e->event,5000000000ull)==DXMT_WAIT_SIGNALED,"actual GPU completion");
}
static void retire(Export *e,bool abandon) {
    check(e && e->busy && e->fence && e->fence->GetCompletedValue()>=e->value,"retire before actual GPU completion");
    dxmt_event_close(e->event);e->event=nullptr;release(reinterpret_cast<void **>(&e->fence));
    generation_retire(e,abandon);
}
static void verify(int fd,uint8_t red,uint8_t green,uint8_t blue,const char *message) {
    struct stat st;check(fstat(fd,&st)==0 && st.st_size>=8192,"retained descriptor extent");
    auto *bytes=static_cast<uint8_t *>(mmap(nullptr,st.st_size,PROT_READ,MAP_SHARED,fd,0));
    check(bytes!=MAP_FAILED,"retained descriptor map");
    bool correct=true;
    for (unsigned i=0;i<8192;i+=4)
        if (bytes[i]!=blue || bytes[i+1]!=green || bytes[i+2]!=red || bytes[i+3]!=255) correct=false;
    munmap(bytes,st.st_size);check(correct,message);pixels+=2048;
}

int main(int argc,char **argv) {
    try {
        bool unsafe=argc==2 && !std::strcmp(argv[1],"--cancel-as-ack");
        check(argc==1 || unsafe,"arguments");
        Com<ID3D11Device> device;Com<ID3D11DeviceContext> context;D3D_FEATURE_LEVEL level;
        hr(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr,0,D3D11_SDK_VERSION,&device.ptr,&level,&context.ptr),"native device");
        Com<ID3D11Device5> d5;Com<ID3D11DeviceContext4> writer;Com<ID3D11Fence> fence;
        hr(device->QueryInterface(__uuidof(ID3D11Device5),reinterpret_cast<void **>(&d5.ptr)),"Device5");
        hr(context->QueryInterface(__uuidof(ID3D11DeviceContext4),reinterpret_cast<void **>(&writer.ptr)),"Context4");
        hr(d5->CreateFence(0,D3D11_FENCE_FLAG_NONE,__uuidof(ID3D11Fence),reinterpret_cast<void **>(&fence.ptr)),"fence");
        npt_context ctx{1};Export current{};current.ctx=&ctx;current.blob_id=100;current.object_id=20;
        allocate(&current,device.ptr);fill(&current,device.ptr,context.ptr,writer.ptr,fence.ptr,1,0,0);
        int red=dup(current.layout.fd);check(red>=0,"red FD duplicate");verify(red,255,0,0,"initial red");
        Export *chosen[]={&current};
        Export *duplicate[]={&current,&current};
        check(!generation_prepare(duplicate,2) && current.busy && current.snapshot,"duplicate capture plan accepted");
        check(generation_prepare(chosen,1) && !current.snapshot,"busy generation not detached");
        check(generation_blob_busy(&ctx,100),"retained busy blob not found");
        generation_forget_blob(&ctx,100);
        check(generation_find(&ctx,1),"forget released a leased generation");
        allocate(&current,device.ptr);fill(&current,device.ptr,context.ptr,writer.ptr,fence.ptr,0,1,0);
        int green=dup(current.layout.fd);check(green>=0,"green FD duplicate");
        verify(red,255,0,0,"old red changed during next GPU generation");
        verify(green,0,255,0,"current green");
        retire(generation_find(&ctx,1),false);
        check(generation_prepare(chosen,1) && generation_reuse(&current),"ACK-retired generation not reused");
        check(allocations==2,"ACK reuse allocated a third backing");
        fill(&current,device.ptr,context.ptr,writer.ptr,fence.ptr,0,0,1);
        verify(red,0,0,255,"actual backing reuse did not reach the original FD");
        verify(green,0,255,0,"unacknowledged green changed during reuse");
        retire(generation_find(&ctx,2),!unsafe);
        check(generation_prepare(chosen,1),"next generation could not preserve blue");
        if (!generation_reuse(&current)) allocate(&current,device.ptr);
        fill(&current,device.ptr,context.ptr,writer.ptr,fence.ptr,1,0,1);
        verify(green,0,255,0,"abandoned backing changed");
        verify(current.layout.fd,255,0,255,"current magenta");
        dispose(&current);generation_destroy_context(&ctx);close(red);close(green);
        check(!live_snapshot_bytes && generation_reuses>=1 && generation_abandoned==1 && generation_allocations==allocations,"generation cleanup/counters");
        // A real 64-MiB registry cannot preserve another 64 MiB of generations.
        npt_context bigctx{2};Export big[2]{};Export *both[]={&big[0],&big[1]};
        for (unsigned i=0;i<2;i++) {
            big[i].ctx=&bigctx;big[i].object_id=30+i;big[i].blob_id=200+i;
            allocate(&big[i],device.ptr,4096,2048);big[i].busy=true;
        }
        check(live_snapshot_bytes==LIVE_MAX_BYTES,"actual large registry byte size");
        void *first=big[0].snapshot,*second=big[1].snapshot;
        check(!generation_prepare(both,2) && big[0].snapshot==first && big[1].snapshot==second,"byte budget allowed destructive detach");
        dispose(&big[0]);dispose(&big[1]);generation_destroy_context(&bigctx);
        check(!live_snapshot_bytes,"large budget cleanup");
        std::printf("{\"result\":\"pass\",\"actual_native_GPU\":true,\"exact_pixels\":%llu,\"backing_reuses\":%llu,\"abandoned_allocations\":%llu,\"peak_retained\":%u,\"byte_budget\":%u,\"bytes_after_cleanup\":%llu,\"Windows_tested\":false}\n",
            (unsigned long long)pixels,(unsigned long long)generation_reuses,(unsigned long long)generation_abandoned,
            generation_peak_held,LIVE_MAX_BYTES,(unsigned long long)live_snapshot_bytes);
        return 0;
    } catch (const std::exception &error) { std::fprintf(stderr,"generation fixture: %s\n",error.what()); return 1; }
}
