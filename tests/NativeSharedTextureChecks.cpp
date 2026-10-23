// Two independent native devices in one process, on the real Metal backend.
// A shared texture's initialization must retire before an importer can write.
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static void check(HRESULT result, const char *operation) {
  if (FAILED(result)) {
    fprintf(stderr, "%s failed: %08x\n", operation, (unsigned)result);
    exit(2);
  }
}

static void create(ID3D11Device **device, ID3D11DeviceContext **context) {
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1,
                         D3D11_SDK_VERSION, device, nullptr, context), "device");
}

static uint32_t read(ID3D11Device *device, ID3D11DeviceContext *context,
                     ID3D11Texture2D *source) {
  D3D11_TEXTURE2D_DESC desc;
  source->GetDesc(&desc);
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.MiscFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Texture2D *staging = nullptr;
  check(device->CreateTexture2D(&desc, nullptr, &staging), "staging");
  context->CopyResource(staging, source);
  context->Flush();
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  check(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped), "map");
  uint32_t value = *(const uint32_t *)mapped.pData;
  for (unsigned y = 0; y < desc.Height; y++) {
    auto row = (const uint32_t *)((const uint8_t *)mapped.pData + y * mapped.RowPitch);
    for (unsigned x = 0; x < desc.Width; x++) {
      if (row[x] != value) {
        fprintf(stderr, "Nonuniform image\n");
        exit(3);
      }
    }
  }
  context->Unmap(staging, 0);
  staging->Release();
  return value;
}

int main() {
  ID3D11Device *a = nullptr, *b = nullptr;
  ID3D11DeviceContext *ca = nullptr, *cb = nullptr;
  create(&a, &ca);
  create(&b, &cb);
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = desc.Height = 64;
  desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  ID3D11Texture2D *created = nullptr;
  check(a->CreateTexture2D(&desc, nullptr, &created), "shared texture");
  IDXGIResource *resource = nullptr;
  check(created->QueryInterface(__uuidof(IDXGIResource), (void **)&resource), "resource interface");
  HANDLE shared = nullptr;
  check(resource->GetSharedHandle(&shared), "export");
  ID3D11Texture2D *imported = nullptr;
  check(b->OpenSharedResource(shared, __uuidof(ID3D11Texture2D), (void **)&imported), "import");
  ID3D11RenderTargetView *rtv = nullptr;
  check(b->CreateRenderTargetView(imported, nullptr, &rtv), "rtv");
  float color[4] = {0.2f, 0.4f, 0.6f, 1.0f};
  cb->ClearRenderTargetView(rtv, color);
  uint32_t before = read(b, cb, imported); // Completed GPU write, confirmed by CPU read.
  uint32_t after = read(a, ca, created);  // Must not initialize over the peer's pixels.
  printf("Imported GPU write=%08x; exporting device later reads=%08x\n", before, after);
  rtv->Release();
  imported->Release();
  resource->Release();
  created->Release();
  ca->Release(); cb->Release(); a->Release(); b->Release();
  return before == 0xff336699u && after == before ? 0 : 1;
}
