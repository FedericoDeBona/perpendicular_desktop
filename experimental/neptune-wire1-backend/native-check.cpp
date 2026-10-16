// SPDX-License-Identifier: Apache-2.0
// Owned native DXMT ABI/events/texture fixture; no VM or guest protocol commands.
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <dxmt-native/dxmt_native.h>
#include "renderer-shared-layout.h"
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <poll.h>
#include <sys/mman.h>
#include <unistd.h>

static_assert(sizeof(dxmt_shared_texture_handle) == 72);
static_assert(sizeof(npt_darwin_shared_texture) == sizeof(dxmt_shared_texture_handle));
#define FIELD_MATCH(field) static_assert(offsetof(npt_darwin_shared_texture, field) == offsetof(dxmt_shared_texture_handle, field))
FIELD_MATCH(magic); FIELD_MATCH(version); FIELD_MATCH(fd); FIELD_MATCH(width); FIELD_MATCH(height);
FIELD_MATCH(dxgi_format); FIELD_MATCH(mip_levels); FIELD_MATCH(array_size); FIELD_MATCH(sample_count);
FIELD_MATCH(bind_flags); FIELD_MATCH(misc_flags); FIELD_MATCH(cpu_access); FIELD_MATCH(stride);
FIELD_MATCH(size); FIELD_MATCH(offset);
static_assert(DXMT_SHARED_TEXTURE_MAGIC == NPT_DARWIN_SHARED_TEXTURE_MAGIC);
static_assert(DXMT_SHARED_HANDLE_VERSION == NPT_DARWIN_SHARED_HANDLE_VERSION);

template<class T> struct Com {
    T *ptr = nullptr;
    ~Com() { if (ptr) ptr->Release(); }
    T *operator->() { return ptr; }
};
static void require(bool value, const char *stage) { if (!value) throw std::runtime_error(stage); }
static void hr(HRESULT value, const char *stage) {
    if (value < 0) { std::fprintf(stderr, "%s HRESULT 0x%08x\n", stage, unsigned(value)); require(false, stage); }
}

int main() {
    try {
        void *event = dxmt_event_create(1, 0); require(event, "Create manual-reset event");
        int event_fd = dxmt_event_dup_fd(event); require(event_fd >= 0, "Duplicate poll fd");
        pollfd pfd{event_fd, POLLIN, 0};
        require(dxmt_event_wait(event, 0) == DXMT_WAIT_TIMEOUT && poll(&pfd, 1, 0) == 0, "Initial event not signaled");
        dxmt_event_signal(event);
        require(dxmt_event_wait(event, 0) == DXMT_WAIT_SIGNALED && poll(&pfd, 1, 0) == 1, "Event signal reaches poll fd");
        dxmt_event_clear(event);
        require(dxmt_event_wait(event, 0) == DXMT_WAIT_TIMEOUT && poll(&pfd, 1, 0) == 0, "Event clear reaches poll fd");

        Com<ID3D11Device> device; Com<ID3D11DeviceContext> context; D3D_FEATURE_LEVEL level{};
        hr(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION, &device.ptr, &level, &context.ptr), "Create native hardware device");
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = 64; desc.Height = 32; desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
        Com<ID3D11Texture2D> texture; hr(device->CreateTexture2D(&desc, nullptr, &texture.ptr), "Create shared texture");
        Com<IDXGIResource> resource;
        hr(texture->QueryInterface(__uuidof(IDXGIResource), reinterpret_cast<void **>(&resource.ptr)), "Query shared resource");
        HANDLE handle = nullptr; hr(resource->GetSharedHandle(&handle), "Export shared handle");
        auto *shared = static_cast<dxmt_shared_texture_handle *>(handle);
        require(shared && shared->magic == DXMT_SHARED_TEXTURE_MAGIC && shared->version == 2 && shared->fd >= 0,
            "Actual DMTX v2 exported descriptor");
        require(shared->width == 64 && shared->height == 32 && shared->stride >= 64 * 4 && shared->size >= shared->stride * 32,
            "Actual shared dimensions/stride/size");
        auto altered = *shared; altered.version++;
        Com<ID3D11Texture2D> rejected;
        require(device->OpenSharedResource(&altered, __uuidof(ID3D11Texture2D), reinterpret_cast<void **>(&rejected.ptr)) < 0 && !rejected.ptr,
            "Wrong shared descriptor version is rejected");
        Com<ID3D11Texture2D> imported;
        hr(device->OpenSharedResource(handle, __uuidof(ID3D11Texture2D), reinterpret_cast<void **>(&imported.ptr)), "Import correct DMTX v2 descriptor");

        Com<ID3D11RenderTargetView> view;
        hr(device->CreateRenderTargetView(texture.ptr, nullptr, &view.ptr), "Create render target");
        const float color[] = {17.f / 255, 136.f / 255, 204.f / 255, 1};
        context->ClearRenderTargetView(view.ptr, color);
        Com<ID3D11Device5> device5; Com<ID3D11DeviceContext4> context4; Com<ID3D11Fence> fence;
        hr(device->QueryInterface(__uuidof(ID3D11Device5), reinterpret_cast<void **>(&device5.ptr)), "Query Device5");
        hr(context->QueryInterface(__uuidof(ID3D11DeviceContext4), reinterpret_cast<void **>(&context4.ptr)), "Query Context4");
        hr(device5->CreateFence(0, D3D11_FENCE_FLAG_NONE, __uuidof(ID3D11Fence), reinterpret_cast<void **>(&fence.ptr)), "Create completion fence");
        hr(fence->SetEventOnCompletion(1, event), "Set completion event");
        hr(context4->Signal(fence.ptr, 1), "Signal after actual GPU clear");
        context->Flush();
        require(dxmt_event_wait(event, 5ull * 1000 * 1000 * 1000) == DXMT_WAIT_SIGNALED, "Wait for GPU completion");
        const auto size = shared->offset + shared->size;
        void *mapping = mmap(nullptr, size, PROT_READ, MAP_SHARED, shared->fd, 0);
        require(mapping != MAP_FAILED, "Map exported pixel storage");
        unsigned pixels = 0;
        for (unsigned y = 0; y < 32; y++) for (unsigned x = 0; x < 64; x++) {
            auto p = static_cast<const uint8_t *>(mapping) + shared->offset + y * shared->stride + x * 4;
            require(p[0] == 204 && p[1] == 136 && p[2] == 17 && p[3] == 255, "Actual GPU BGRA pixel mismatch");
            pixels++;
        }
        munmap(mapping, size); close(event_fd); dxmt_event_close(event);
        std::printf("{\"result\":\"pass\",\"feature_level\":%u,\"shared_magic\":\"DMTX\",\"shared_version\":2,\"descriptor_size\":72,\"fd_offset\":8,\"pixels_verified\":%u,\"wrong_version_rejected\":true,\"event_signal_clear_poll\":true,\"Windows_tested\":false}\n", unsigned(level), pixels);
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Native compatible-backend fixture failed: %s\n", error.what());
        return 1;
    }
}
