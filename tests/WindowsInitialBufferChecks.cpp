#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static const UINT N=512*1024, PATCH=4096, COUNT=32;
static uint8_t expected[N];
static ID3D11Device *device;static ID3D11DeviceContext *context;
static ID3D11Buffer *buffer,*staging;static ID3D11ShaderResourceView *view;
static bool check(HRESULT hr,const char *stage){if(SUCCEEDED(hr))return true;printf("{\"stage\":\"%s\",\"hr\":\"%08lx\"}\n",stage,(unsigned long)hr);return false;}
static int readback(const char *stage){
 context->CopyResource(staging,buffer);D3D11_MAPPED_SUBRESOURCE m={};
 if(!check(context->Map(staging,0,D3D11_MAP_READ,0,&m),"readback-map"))return -1;
 UINT bad=0,first=N;unsigned actual=0,want=0;
 for(UINT i=0;i<N;i++)if(((const uint8_t*)m.pData)[i]!=expected[i]){bad++;if(first==N){first=i;actual=((const uint8_t*)m.pData)[i];want=expected[i];}}
 context->Unmap(staging,0);printf("{\"stage\":\"%s\",\"bytes\":%u,\"mismatches\":%u,\"first\":%u,\"actual\":%u,\"expected\":%u}\n",stage,N,bad,first,actual,want);fflush(stdout);return bad?1:0;
}
static int run(){
 D3D_FEATURE_LEVEL level,levels[]={D3D_FEATURE_LEVEL_11_0};
 if(!check(D3D11CreateDevice(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,levels,1,D3D11_SDK_VERSION,&device,&level,&context),"create-device"))return 2;
 HMODULE umd=GetModuleHandleW(L"neptune_umd_arm64.dll");char module[MAX_PATH]={};if(!umd||!GetModuleFileNameA(umd,module,MAX_PATH))return 11;printf("UMD|%s\n",module);
 IDXGIDevice *dxgi=NULL;IDXGIAdapter *adapter=NULL;DXGI_ADAPTER_DESC desc={};
 if(!check(device->QueryInterface(__uuidof(IDXGIDevice),(void**)&dxgi),"dxgi-device"))return 2;
 if(!check(dxgi->GetAdapter(&adapter),"adapter"))return 2;
 adapter->GetDesc(&desc);adapter->Release();dxgi->Release();
 printf("{\"adapterVendor\":%u,\"featureLevel\":%u}\n",desc.VendorId,(UINT)level);
 if(desc.VendorId!=0x1af4)return 3;
 D3D11_FEATURE_DATA_D3D11_OPTIONS options={};
 if(!check(device->CheckFeatureSupport(D3D11_FEATURE_D3D11_OPTIONS,&options,sizeof(options)),"options"))return 4;
 printf("{\"mapNoOverwriteDynamicSRV\":%s}\n",options.MapNoOverwriteOnDynamicBufferSRV?"true":"false");
 if(!options.MapNoOverwriteOnDynamicBufferSRV)return 5;
 for(UINT i=0;i<N;i++)expected[i]=(uint8_t)((i*13+37)&255);
 D3D11_BUFFER_DESC d={};d.ByteWidth=N;d.Usage=D3D11_USAGE_DYNAMIC;d.BindFlags=D3D11_BIND_SHADER_RESOURCE;d.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE;
 D3D11_SUBRESOURCE_DATA init={expected,0,0};
 if(!check(device->CreateBuffer(&d,&init,&buffer),"create-initialized-buffer"))return 6;
 D3D11_SHADER_RESOURCE_VIEW_DESC sd={};sd.Format=DXGI_FORMAT_R8_UINT;sd.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;sd.Buffer.NumElements=N;
 if(!check(device->CreateShaderResourceView(buffer,&sd,&view),"create-r8-view"))return 6;
 d.Usage=D3D11_USAGE_STAGING;d.BindFlags=0;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
 if(!check(device->CreateBuffer(&d,NULL,&staging),"create-staging"))return 6;
 if(readback("initialized-baseline")!=0)return 7;
 D3D11_MAPPED_SUBRESOURCE m={};
 if(!check(context->Map(buffer,0,D3D11_MAP_WRITE_NO_OVERWRITE,0,&m),"first-nooverwrite-map"))return 8;
 memset((uint8_t*)m.pData+PATCH,0xc7,COUNT);context->Unmap(buffer,0);memset(expected+PATCH,0xc7,COUNT);
 return readback("first-nooverwrite-preserve")?9:0;
}
int main(){int rc=run();if(view)view->Release();if(staging)staging->Release();if(buffer)buffer->Release();if(context){context->ClearState();context->Release();}if(device)device->Release();printf("{\"exit\":%d}\n",rc);return rc;}
