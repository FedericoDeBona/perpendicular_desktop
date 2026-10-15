// SPDX-License-Identifier: MIT
// Real native DXMT D3D11 producer, no Windows/VM or arbitrary commands.
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <dxmt-native/dxmt_native.h>
#include "wire.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <string>

template<class T> struct Com {
    T *ptr=nullptr;
    ~Com() { if(ptr) ptr->Release(); }
    T *operator->() { return ptr; }
};
static void hr(HRESULT result, const char *stage) {
    if(result<0) { fprintf(stderr,"%s HRESULT 0x%08x\n",stage,unsigned(result)); check(false,stage); }
}
int main(int argc,char **argv) {
    try {
        check(argc==2 || (argc==3 && !std::strcmp(argv[2],"--withhold-first")),"Usage: producer inherited-socket-fd [--withhold-first]");
        bool withhold=argc==3;
        int socket=std::atoi(argv[1]); configure_socket(socket);
        check(dxmt_native_abi_version()==DXN_ABI_VERSION,"Native backend ABI mismatch");
        Com<ID3D11Device> device; Com<ID3D11DeviceContext> context;
        D3D_FEATURE_LEVEL level{};
        hr(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr,0,D3D11_SDK_VERSION,&device.ptr,&level,&context.ptr),"D3D11CreateDevice hardware");
        Com<ID3D11Device5> device5; Com<ID3D11DeviceContext4> context4;
        hr(device->QueryInterface(__uuidof(ID3D11Device5),reinterpret_cast<void **>(&device5.ptr)),"Device5");
        hr(context->QueryInterface(__uuidof(ID3D11DeviceContext4),reinterpret_cast<void **>(&context4.ptr)),"Context4");
        Com<ID3D11Fence> fence;
        hr(device5->CreateFence(0,D3D11_FENCE_FLAG_NONE,__uuidof(ID3D11Fence),reinterpret_cast<void **>(&fence.ptr)),"CreateFence");
        uint32_t sequence=0;
        for(auto dimensions : {std::array<UINT,2>{800,600}, {1920,1080}, {803,607}, {800,600}}) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width=dimensions[0]; desc.Height=dimensions[1]; desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
            desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM; desc.Usage=D3D11_USAGE_DEFAULT;
            desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
            desc.MiscFlags=0;
            Com<ID3D11Texture2D> texture;
            hr(device->CreateTexture2D(&desc,nullptr,&texture.ptr),"Create private producer texture");
            D3D11_TEXTURE2D_DESC shared_desc=desc;
            shared_desc.MiscFlags=D3D11_RESOURCE_MISC_SHARED|DXN_MISC_LINEAR_EXPORT;
            Com<ID3D11Texture2D> snapshot;
            hr(device->CreateTexture2D(&shared_desc,nullptr,&snapshot.ptr),"Create shared linear snapshot");
            D3D11_TEXTURE2D_DESC staging_desc=desc;
            staging_desc.Usage=D3D11_USAGE_STAGING; staging_desc.BindFlags=0;
            staging_desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
            Com<ID3D11Texture2D> staging;
            hr(device->CreateTexture2D(&staging_desc,nullptr,&staging.ptr),"Create overwrite verification staging texture");
            Com<ID3D11RenderTargetView> view;
            hr(device->CreateRenderTargetView(texture.ptr,nullptr,&view.ptr),"CreateRenderTargetView");
            Com<IDXGIResource> resource;
            hr(snapshot->QueryInterface(__uuidof(IDXGIResource),reinterpret_cast<void **>(&resource.ptr)),"Snapshot IDXGIResource");
            HANDLE handle=nullptr; hr(resource->GetSharedHandle(&handle),"GetSharedHandle");
            auto *shared=static_cast<dxn_shared_texture *>(handle);
            check(dxn_shared_check(shared,DXN_SHARED_TEXTURE_MAGIC,sizeof(*shared)) && shared->fd>=0,"Shared descriptor");
            // Reuse snapshot backing only after each consumer ACK. Generation 2
            // reverses quadrant colors, so stale previous-generation reads fail.
            for(unsigned generation=0;generation<2;generation++) {
                const float colors[4][4]={{1,0,0,1},{0,1,0,1},{0,0,1,1},{1,1,1,1}};
                for(unsigned quadrant=0;quadrant<4;quadrant++) {
                    LONG left=(quadrant%2)?LONG(desc.Width/2):0, top=(quadrant/2)?LONG(desc.Height/2):0;
                    D3D11_RECT rect{left,top,(quadrant%2)?LONG(desc.Width):LONG(desc.Width/2),
                        (quadrant/2)?LONG(desc.Height):LONG(desc.Height/2)};
                    context4->ClearView(view.ptr,colors[generation?3-quadrant:quadrant],&rect,1);
                }
                float cross[]={17.f/255,136.f/255,204.f/255,1};
                D3D11_RECT middle[]={{LONG(desc.Width/2),0,LONG(desc.Width/2)+1,LONG(desc.Height)},
                    {0,LONG(desc.Height/2),LONG(desc.Width),LONG(desc.Height/2)+1}};
                context4->ClearView(view.ptr,cross,middle,2);
                // This is the ordered insertion proposed for Neptune's actual
                // Context4::Signal override: freeze a copy before its Signal,
                // independent of a later RESOURCE_FLUSH on another channel.
                context4->CopyResource(snapshot.ptr,texture.ptr);
                void *event=dxmt_event_create(1,0); check(event,"Create backend event");
                int event_fd=dxmt_event_dup_fd(event); check(event_fd>=0,"Duplicate event poll fd");
                uint64_t value=uint64_t(++sequence)*2;
                hr(fence->SetEventOnCompletion(value,event),"SetEventOnCompletion");
                Frame frame; frame.sequence=sequence; frame.flags=generation; frame.texture=*shared;
                send_frame(socket,frame,shared->fd,event_fd);
                // Deliberately withhold Signal until consumer confirms it saw
                // a not-ready fd. No consumer is allowed to read pixels yet.
                control(socket,'S');
                if(withhold && sequence==1) {
                    fprintf(stderr,"Fixture deliberately withholds producer Signal\n");
                    context->Flush(); // render may finish; the ready token does not.
                } else {
                    hr(context4->Signal(fence.ptr,value),"GPU ordered Signal");
                    // Prove the immutable object is the snapshot. Finish a
                    // visible overwrite of the original before consumer reads.
                    float overwrite[]={1,0,1,1};
                    context4->ClearRenderTargetView(view.ptr,overwrite);
                    context4->CopyResource(staging.ptr,texture.ptr);
                    void *overwritten=dxmt_event_create(1,0); check(overwritten,"Create overwrite event");
                    hr(fence->SetEventOnCompletion(value+1,overwritten),"Overwrite SetEventOnCompletion");
                    hr(context4->Signal(fence.ptr,value+1),"Overwrite Signal");
                    check(dxmt_event_wait(overwritten,5ull*1000*1000*1000)==DXN_WAIT_SIGNALED,"Original overwrite completion");
                    dxmt_event_close(overwritten);
                    D3D11_MAPPED_SUBRESOURCE mapped{};
                    hr(context->Map(staging.ptr,0,D3D11_MAP_READ,0,&mapped),"Map overwrite verification");
                    check(mapped.pData && mapped.RowPitch>=desc.Width*4,"Overwrite staging layout");
                    for(unsigned y=0;y<desc.Height;y++) for(unsigned x=0;x<desc.Width;x++) {
                        auto pixel=static_cast<const uint8_t *>(mapped.pData)+size_t(y)*mapped.RowPitch+x*4;
                        check(pixel[0]==255 && pixel[1]==0 && pixel[2]==255 && pixel[3]==255,"Original overwrite pixel mismatch");
                    }
                    context->Unmap(staging.ptr,0);
                    notify(socket,'O');
                }
                control(socket,'A'); // consumer has finished all GPU/CPU reads.
                check(fence->GetCompletedValue()>=value,"ACK arrived before producer completion");
                close(event_fd); dxmt_event_close(event);
                printf("{\"producer_frame\":%u,\"width\":%u,\"height\":%u,\"generation\":%u,\"original_overwrite_pixels_verified\":true,\"original_overwritten_before_read\":true,\"acknowledged\":true}\n",
                    sequence,desc.Width,desc.Height,generation); fflush(stdout);
            }
        }
        notify(socket,'E'); close(socket);
        printf("{\"result\":\"pass\",\"frames\":%u,\"feature_level\":%u,\"native_abi\":%u}\n",sequence,level,dxmt_native_abi_version());
        return 0;
    } catch(const std::exception &error) {
        fprintf(stderr,"DXMT producer failed: %s\n",error.what()); return 1;
    }
}
