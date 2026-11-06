// Native-only Neptune sequence: create first, upload initial data separately.
// This is a transport reproduction, not legal application use of IMMUTABLE.
// Read the completed shared allocation directly; an extra GPU readback could
// introduce a dependency absent from the failing update/copy sequence.
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <dxmt_native.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>
#include <unistd.h>

static void check(HRESULT result, const char *operation) {
  if (FAILED(result)) {
    std::fprintf(stderr, "%s: %08x\n", operation, unsigned(result));
    std::exit(2);
  }
}

static void complete(ID3D11Device *device, ID3D11DeviceContext *context) {
  D3D11_QUERY_DESC desc = {D3D11_QUERY_EVENT, 0};
  ID3D11Query *query = nullptr;
  check(device->CreateQuery(&desc, &query), "query");
  context->End(query);
  context->Flush();
  for (unsigned i = 0; i < 3000; ++i) {
    BOOL done = FALSE;
    HRESULT result = context->GetData(query, &done, sizeof(done), 0);
    check(result, "query completion");
    if (result == S_OK && done) {
      query->Release();
      return;
    }
    usleep(1000);
  }
  std::fprintf(stderr, "GPU completion timed out\n");
  std::exit(3);
}

int main() {
  ID3D11Device *device = nullptr;
  ID3D11DeviceContext *context = nullptr;
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
                        &level, 1, D3D11_SDK_VERSION, &device, nullptr, &context), "device");
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = 1952;
  desc.Height = 1312;
  desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  ID3D11Texture2D *atlas = nullptr;
  check(device->CreateTexture2D(&desc, nullptr, &atlas), "atlas");
  IDXGIResource *resource = nullptr;
  check(atlas->QueryInterface(__uuidof(IDXGIResource), (void **)&resource), "resource");
  HANDLE handle = nullptr;
  check(resource->GetSharedHandle(&handle), "export");
  const auto *shared = static_cast<const dxmt_shared_texture_handle *>(handle);
  if (shared->magic != DXMT_SHARED_TEXTURE_MAGIC || shared->offset != 0) return 4;
  void *mapping = mmap(nullptr, shared->size, PROT_READ, MAP_SHARED, shared->fd, 0);
  if (mapping == MAP_FAILED) return 5;
  const auto *pixels = static_cast<const uint32_t *>(mapping);
  auto verify = [&](const char *operation, uint32_t expected) {
    complete(device, context);
    std::printf("%s: origin=%08x neighbour=%08x expected=%08x\n",
                operation, pixels[0], pixels[1], expected);
    if (pixels[0] != expected || pixels[1] != 0) std::exit(6);
  };
  verify("initial", 0);
  D3D11_BOX box = {0, 0, 0, 1, 1, 1};
  uint32_t white = 0xffffffff;
  context->UpdateSubresource(atlas, 0, &box, &white, 4, 4);
  verify("direct upload control", white);

  D3D11_TEXTURE2D_DESC tiny = desc;
  tiny.Width = tiny.Height = 1;
  tiny.MiscFlags = tiny.BindFlags = 0;
  tiny.Usage = D3D11_USAGE_STAGING;
  tiny.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  ID3D11Texture2D *source = nullptr;
  check(device->CreateTexture2D(&tiny, nullptr, &source), "staging source");
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  check(context->Map(source, 0, D3D11_MAP_WRITE, 0, &mapped), "map write");
  uint32_t stagingValue = 0xff778899;
  std::memcpy(mapped.pData, &stagingValue, 4);
  context->Unmap(source, 0);
  context->CopySubresourceRegion(atlas, 0, 0, 0, 0, source, 0, nullptr);
  verify("staging copy control", stagingValue);
  source->Release();

  tiny = desc;
  tiny.Width = tiny.Height = 1;
  tiny.MiscFlags = 0;
  uint32_t initialValue = 0xffaabbcc;
  D3D11_SUBRESOURCE_DATA data = {&initialValue, 4, 4};
  check(device->CreateTexture2D(&tiny, &data, &source), "initialized source");
  context->CopySubresourceRegion(atlas, 0, 0, 0, 0, source, 0, nullptr);
  verify("creation data control", initialValue);
  source->Release();

  tiny.Usage = D3D11_USAGE_IMMUTABLE;
  tiny.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  check(device->CreateTexture2D(&tiny, nullptr, &source), "late-initialized source");
  context->UpdateSubresource(source, 0, nullptr, &white, 0, 0);
  context->CopySubresourceRegion(atlas, 0, 0, 0, 0, source, 0, &box);
  verify("immutable separate upload then copy", white);
  source->Release();
  munmap(mapping, shared->size);
  resource->Release();
  atlas->Release();
  context->Release();
  device->Release();
}
