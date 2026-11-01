// A real NV12 upload/copy/readback on the native Metal-backed D3D11 device.
// This checks the video surface prerequisite, not browser decode or frame rate.
#include <d3d11_4.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static void check(HRESULT hr, const char *operation) {
  if (FAILED(hr)) {
    std::fprintf(stderr, "%s: %08x\n", operation, unsigned(hr));
    std::exit(1);
  }
}

int main() {
  ID3D11Device *device = nullptr;
  ID3D11DeviceContext *context = nullptr;
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
      &level, 1, D3D11_SDK_VERSION, &device, nullptr, &context), "device");
  constexpr UINT width = 64, height = 32;
  std::vector<uint8_t> pixels(width * height * 3 / 2);
  for (size_t i = 0; i < pixels.size(); ++i) pixels[i] = uint8_t(i * 7 + i / width);
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
  desc.Format = DXGI_FORMAT_NV12;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA initial = {pixels.data(), width, 0};
  ID3D11Texture2D *texture = nullptr;
  check(device->CreateTexture2D(&desc, &initial, &texture), "NV12 texture");
  ID3D11Device3 *device3 = nullptr;
  check(device->QueryInterface(__uuidof(ID3D11Device3), (void **)&device3), "device3");
  for (UINT plane = 0; plane < 2; ++plane) {
    D3D11_SHADER_RESOURCE_VIEW_DESC1 viewDesc = {};
    viewDesc.Format = plane ? DXGI_FORMAT_R8G8_UNORM : DXGI_FORMAT_R8_UNORM;
    viewDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    viewDesc.Texture2D.MipLevels = 1;
    viewDesc.Texture2D.PlaneSlice = plane;
    ID3D11ShaderResourceView1 *view = nullptr;
    check(device3->CreateShaderResourceView1(texture, &viewDesc, &view), "plane SRV");
    view->Release();
  }
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Texture2D *staging = nullptr;
  check(device->CreateTexture2D(&desc, nullptr, &staging), "staging");
  for (UINT pass = 0; pass < 2; ++pass) {
    if (pass) {
      for (auto &pixel : pixels) pixel ^= 0xa5;
      context->UpdateSubresource(texture, 0, nullptr, pixels.data(), width, 0);
    }
    context->CopyResource(staging, texture);
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    check(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped), "readback");
    bool equal = mapped.RowPitch >= width;
    for (UINT row = 0; row < height * 3 / 2 && equal; ++row) {
      const auto *actual = (const uint8_t *)mapped.pData + row * mapped.RowPitch;
      for (UINT column = 0; column < width; ++column)
        if (actual[column] != pixels[row * width + column]) { equal = false; break; }
    }
    context->Unmap(staging, 0);
    if (!equal) {
      std::fprintf(stderr, "NV12 pixels differ after %s\n", pass ? "update" : "initial upload");
      return 2;
    }
  }
  staging->Release();
  device3->Release();
  texture->Release();
  context->Release();
  device->Release();
  std::puts("NV12 initial upload, two plane SRVs, update and full readback PASS");
}
