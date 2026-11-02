// Two native D3D11 devices exchange both NV12 planes through the existing
// shared-resource handle. This checks pixels and ownership, not browser FPS.
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
static void check(HRESULT hr, const char *op) {
  if (FAILED(hr)) { std::fprintf(stderr, "%s: %08x\n", op, unsigned(hr)); std::exit(2); }
}
static void create(ID3D11Device **d, ID3D11DeviceContext **c) {
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,&level,1,
      D3D11_SDK_VERSION,d,nullptr,c), "device");
}
static void verify(ID3D11Device *d, ID3D11DeviceContext *c, ID3D11Texture2D *t,
                   const std::vector<unsigned char> &pixels, const char *op) {
  D3D11_TEXTURE2D_DESC desc; t->GetDesc(&desc);
  desc.Usage=D3D11_USAGE_STAGING; desc.BindFlags=desc.MiscFlags=0;
  desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
  ID3D11Texture2D *staging=nullptr; check(d->CreateTexture2D(&desc,nullptr,&staging),"staging");
  c->CopyResource(staging,t);
  D3D11_MAPPED_SUBRESOURCE map={}; check(c->Map(staging,0,D3D11_MAP_READ,0,&map),"readback");
  for (unsigned y=0;y<desc.Height*3/2;y++) {
    if (map.RowPitch<desc.Width || std::memcmp((char*)map.pData+y*map.RowPitch,
        pixels.data()+y*desc.Width,desc.Width)) {
      std::fprintf(stderr,"%s: row %u differs (%s plane)\n",op,y,y<desc.Height?"Y":"UV");
      std::exit(3);
    }
  }
  c->Unmap(staging,0); staging->Release(); std::printf("%s: both planes exact\n",op);
}
int main() {
  ID3D11Device *a=nullptr,*b=nullptr; ID3D11DeviceContext *ca=nullptr,*cb=nullptr;
  create(&a,&ca);create(&b,&cb);
  D3D11_TEXTURE2D_DESC desc={};desc.Width=64;desc.Height=32;
  desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
  desc.Format=DXGI_FORMAT_NV12;desc.Usage=D3D11_USAGE_DEFAULT;
  desc.BindFlags=D3D11_BIND_DECODER|D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags=D3D11_RESOURCE_MISC_SHARED;
  std::vector<unsigned char> pixels(desc.Width*desc.Height*3/2);
  for(size_t i=0;i<pixels.size();i++)pixels[i]=(i*7+i/desc.Width)&255;
  D3D11_SUBRESOURCE_DATA data={pixels.data(),desc.Width,0};
  ID3D11Texture2D *producer=nullptr,*consumer=nullptr;
  check(a->CreateTexture2D(&desc,&data,&producer),"shared NV12 creation");
  IDXGIResource *resource=nullptr;check(producer->QueryInterface(__uuidof(IDXGIResource),(void**)&resource),"resource");
  HANDLE handle=nullptr;check(resource->GetSharedHandle(&handle),"export");
  check(b->OpenSharedResource(handle,__uuidof(ID3D11Texture2D),(void**)&consumer),"import");
  verify(b,cb,consumer,pixels,"import initialized pixels");
  for(auto &v:pixels)v^=0xa5;
  cb->UpdateSubresource(consumer,0,nullptr,pixels.data(),desc.Width,0);
  verify(b,cb,consumer,pixels,"consumer update completed");
  // Importer releases its resource; the producer's allocation must keep both
  // planes alive and see the completed update, without reinitializing them.
  consumer->Release();resource->Release();
  verify(a,ca,producer,pixels,"producer after consumer release");
  producer->Release();ca->Release();cb->Release();a->Release();b->Release();
  return 0;
}
