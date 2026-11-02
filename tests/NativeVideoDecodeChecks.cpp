// Real D3D11 video buffer submission -> VP9 hardware -> NV12 -> readback.
// Compare a short IVF stream with an independently decoded tight NV12 file.
#include <d3d11_4.h>
#include "../graphics/backend/video-resource-submit.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <chrono>

static void check(HRESULT hr, const char *operation) {
  if (FAILED(hr)) { std::fprintf(stderr, "%s: %08x\n", operation, unsigned(hr)); std::exit(1); }
}
static uint32_t little(const uint8_t *p, unsigned n) {
  uint32_t v = 0; for (unsigned i = 0; i < n; ++i) v |= uint32_t(p[i]) << (i * 8); return v;
}
int main(int argc, char **argv) {
  bool resources = argc == 4 && !std::strcmp(argv[3], "--resources");
  if (argc != 3 && !resources) { std::fprintf(stderr, "Usage: check-video stream.ivf reference.nv12 [--resources]\n"); return 2; }
  FILE *input = std::fopen(argv[1], "rb"), *reference = std::fopen(argv[2], "rb");
  if (!input || !reference) return 2;
  uint8_t header[32];
  if (std::fread(header, 1, sizeof(header), input) != sizeof(header) || std::memcmp(header, "DKIF", 4) ||
      std::memcmp(header + 8, "VP90", 4) || little(header + 6, 2) != 32) return 2;
  UINT width = little(header + 12, 2), height = little(header + 14, 2);
  if (!width || !height || (width & 1) || (height & 1) || width > 4096 || height > 2160) return 2;
  ID3D11Device *device = nullptr;
  ID3D11DeviceContext *context = nullptr;
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  UINT flags = 0;
#if defined(_WIN32) && !defined(__APPLE__)
  flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
#endif
  HRESULT created = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, &level, 1,
      D3D11_SDK_VERSION, &device, nullptr, &context);
#if defined(_WIN32) && !defined(__APPLE__)
  // Registry settings alone do not prove which UMD the runtime loaded.
  for (auto name : {L"neptune_umd.dll", L"neptune_umd_arm64.dll"}) {
    wchar_t path[1024]; HMODULE module = GetModuleHandleW(name);
    if (module && GetModuleFileNameW(module, path, 1024))
      std::printf("Loaded Windows UMD: %ls\n", path);
  }
#endif
  check(created, "device");
  ID3D11VideoDevice *video = nullptr;
  ID3D11VideoContext *vc = nullptr;
  check(device->QueryInterface(__uuidof(ID3D11VideoDevice), (void **)&video), "VideoDevice");
  check(context->QueryInterface(__uuidof(ID3D11VideoContext), (void **)&vc), "VideoContext");
  IUnknown *deviceIdentity = nullptr, *videoIdentity = nullptr;
  check(device->QueryInterface(__uuidof(IUnknown), (void **)&deviceIdentity), "device identity");
  check(video->QueryInterface(__uuidof(IUnknown), (void **)&videoIdentity), "video identity");
  if (deviceIdentity != videoIdentity) return 3;
  deviceIdentity->Release(); videoIdentity->Release();
  IUnknown *contextIdentity = nullptr, *vcIdentity = nullptr;
  check(context->QueryInterface(__uuidof(IUnknown), (void **)&contextIdentity), "context identity");
  check(vc->QueryInterface(__uuidof(IUnknown), (void **)&vcIdentity), "video context identity");
  if (contextIdentity != vcIdentity) return 3;
  contextIdentity->Release(); vcIdentity->Release();
  if (video->GetVideoDecoderProfileCount() != 1) return 3;
  GUID profile;
  check(video->GetVideoDecoderProfile(0, &profile), "profile");
  constexpr GUID vp9 = {0x463707f8,0xa1d0,0x4585,{0x87,0x6d,0x83,0xaa,0x6d,0x60,0xb8,0x9e}};
  if (std::memcmp(&vp9, &profile, sizeof(profile))) return 3;
  D3D11_VIDEO_DECODER_DESC desc = {profile, width, height, DXGI_FORMAT_NV12};
  UINT count = 0;
  check(video->GetVideoDecoderConfigCount(&desc, &count), "config count");
  if (count != 1) return 3;
  D3D11_VIDEO_DECODER_CONFIG config = {};
  check(video->GetVideoDecoderConfig(&desc, 0, &config), "config");
  ID3D11VideoDecoder *decoder = nullptr;
  check(video->CreateVideoDecoder(&desc, &config, &decoder), "hardware decoder");
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = width; td.Height = height;
  td.MipLevels = td.ArraySize = td.SampleDesc.Count = 1;
  // Exercise a nonzero decoder target slice: GPU plane copies must retain
  // the output view's array selection, including chroma.
  td.ArraySize = 2;
  td.Format = DXGI_FORMAT_NV12; td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_DECODER | D3D11_BIND_SHADER_RESOURCE;
  ID3D11Texture2D *texture = nullptr, *staging = nullptr;
  check(device->CreateTexture2D(&td, nullptr, &texture), "NV12 output");
  D3D11_VIDEO_DECODER_OUTPUT_VIEW_DESC vd = {};
  vd.DecodeProfile = profile; vd.ViewDimension = D3D11_VDOV_DIMENSION_TEXTURE2D;
  vd.Texture2D.ArraySlice = 1;
  ID3D11VideoDecoderOutputView *view = nullptr;
  check(video->CreateVideoDecoderOutputView(texture, &vd, &view), "decoder view");
  td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  check(device->CreateTexture2D(&td, nullptr, &staging), "staging");
  if (resources) {
    D3D11_VIDEO_DECODER_EXTENSION query = {};
    query.Function = PERP_VIDEO_RESOURCE_QUERY;
    check(vc->DecoderExtension(decoder, &query), "resource transport version");
  }
  std::vector<uint8_t> expected(size_t(width) * height * 3 / 2), bytes;
  auto started = std::chrono::steady_clock::now();
  unsigned frames = 0;
  for (;;) {
    uint8_t frame[12]; size_t got = std::fread(frame, 1, sizeof(frame), input);
    if (!got) break;
    if (got != sizeof(frame) || frames >= 3) return 2;
    UINT size = little(frame, 4);
    if (!size || size > 16 * 1024 * 1024) return 2;
    bytes.resize(size);
    if (std::fread(bytes.data(), 1, size, input) != size ||
        std::fread(expected.data(), 1, expected.size(), reference) != expected.size()) return 2;
    check(vc->DecoderBeginFrame(decoder, view, 0, nullptr), "begin frame");
    if (resources) {
      D3D11_BUFFER_DESC inputDesc = {};
      inputDesc.ByteWidth = size + 16;
      inputDesc.Usage = D3D11_USAGE_STAGING; inputDesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
      ID3D11Buffer *inputBuffer = nullptr;
      check(device->CreateBuffer(&inputDesc, nullptr, &inputBuffer), "compressed resource");
      D3D11_MAPPED_SUBRESOURCE write = {};
      check(context->Map(inputBuffer, 0, D3D11_MAP_WRITE, 0, &write), "compressed resource map");
      std::memset(write.pData, 0, 16);
      std::memcpy((uint8_t *)write.pData + 16, bytes.data(), size);
      context->Unmap(inputBuffer, 0);
      struct {
        perp_video_resource_header header;
        perp_video_resource_buffer buffer;
      } packet = {{PERP_VIDEO_RESOURCE_VERSION, 1}, {D3D11_VIDEO_DECODER_BUFFER_BITSTREAM, 0, 16, size}};
      ID3D11Resource *list[] = {inputBuffer};
      D3D11_VIDEO_DECODER_EXTENSION extension = {};
      extension.Function = PERP_VIDEO_RESOURCE_SUBMIT;
      extension.pPrivateInputData = &packet; extension.PrivateInputDataSize = sizeof(packet);
      extension.ResourceCount = 1; extension.ppResourceList = list;
      if (!frames) {
        packet.header.version = PERP_VIDEO_RESOURCE_VERSION + 1;
        if (vc->DecoderExtension(decoder, &extension) != E_INVALIDARG) return 3;
        packet.header.version = PERP_VIDEO_RESOURCE_VERSION;
        packet.buffer.offset = inputDesc.ByteWidth;
        if (vc->DecoderExtension(decoder, &extension) != E_INVALIDARG) return 3;
        packet.buffer.offset = 16;
      }
      check(vc->DecoderExtension(decoder, &extension), "resource submit");
      inputBuffer->Release();
      D3D11_VIDEO_DECODER_EXTENSION finish = {};
      finish.Function = PERP_VIDEO_RESOURCE_FINISH;
      check(vc->DecoderExtension(decoder, &finish), "resource finish");
    } else {
    UINT capacity = 0; void *buffer = nullptr;
    check(vc->GetDecoderBuffer(decoder, D3D11_VIDEO_DECODER_BUFFER_BITSTREAM, &capacity, &buffer), "buffer");
    if (size > capacity || !buffer) return 3;
    std::memcpy(buffer, bytes.data(), size);
    check(vc->ReleaseDecoderBuffer(decoder, D3D11_VIDEO_DECODER_BUFFER_BITSTREAM), "release buffer");
    if (!frames) {
      D3D11_VIDEO_DECODER_BUFFER_DESC invalid = {};
      invalid.BufferType = D3D11_VIDEO_DECODER_BUFFER_BITSTREAM;
      invalid.DataOffset = capacity; invalid.DataSize = 1;
      if (vc->SubmitDecoderBuffers(decoder, 1, &invalid) != E_INVALIDARG) return 3;
    }
    D3D11_VIDEO_DECODER_BUFFER_DESC submit = {};
    submit.BufferType = D3D11_VIDEO_DECODER_BUFFER_BITSTREAM; submit.DataSize = size;
    check(vc->SubmitDecoderBuffers(decoder, 1, &submit), "submit");
    check(vc->DecoderEndFrame(decoder), "end frame");
    }
    context->CopyResource(staging, texture);
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    check(context->Map(staging, 1, D3D11_MAP_READ, 0, &mapped), "decoded readback");
    bool equal = mapped.RowPitch >= width;
    for (UINT row = 0; row < height * 3 / 2 && equal; ++row)
      equal = !std::memcmp((uint8_t *)mapped.pData + size_t(row) * mapped.RowPitch,
                           expected.data() + size_t(row) * width, width);
    context->Unmap(staging, 1);
    if (!equal) { std::fprintf(stderr, "Decoded pixels differ in frame %u\n", frames); return 3; }
    ++frames;
  }
  if (!frames || std::fgetc(reference) != EOF) return 2;
  double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
  std::printf("D3D11 VP9 hardware %ux%u (%s): %u frames pixel-identical; decode/upload/readback %.3f ms total\n", width,height,resources ? "resource submit" : "decoder buffer",frames,ms);
  staging->Release(); view->Release(); texture->Release(); decoder->Release();
  vc->Release(); video->Release(); context->Release(); device->Release();
  std::fclose(reference); std::fclose(input);
}
