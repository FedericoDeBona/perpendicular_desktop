/* SPDX-License-Identifier: MIT
 * Small check against the actual packaged D3D backend, outside the VM.
 * No guest or document changes. More simultaneous imports than the old cap.
 */
#include "import-marker.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#define CALL(type,obj,slot) NPT_COM_VTBL_FUNC(type,npt_com_vtable(obj),slot)
int main(int argc,char **argv)
{
    assert(argc==2);
    void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!library){fprintf(stderr,"%s\n",dlerror());return 1;}
    PFN_D3D11CreateDevice create=(PFN_D3D11CreateDevice)dlsym(library,"D3D11CreateDevice");
    assert(create);
    ID3D11Device *device=NULL;ID3D11DeviceContext *context=NULL;
    D3D_FEATURE_LEVEL level=0;
    assert(NPT_SUCCEEDED(create(NULL,D3D_DRIVER_TYPE_HARDWARE,0,0,NULL,0,7,&device,&level,&context)));
    GUID key;arc4random_buf(&key,sizeof(key));
    void *textures[257]={0};
    D3D11_TEXTURE2D_DESC desc={.Width=4,.Height=4,.MipLevels=1,.ArraySize=1,
        .Format=DXGI_FORMAT_B8G8R8A8_UNORM,.SampleDesc={.Count=1},.Usage=D3D11_USAGE_DEFAULT};
    PFN_ID3D11Device_CreateTexture2D texture=CALL(PFN_ID3D11Device_CreateTexture2D,device,NPT_VTBL_ID3D11Device_CreateTexture2D);
    for(unsigned i=0;i<257;i++) {
        assert(NPT_SUCCEEDED(texture(device,&desc,NULL,(ID3D11Texture2D **)&textures[i])));
        bool imported=true;assert(perp_import_marker(textures[i],&key,false,&imported) && !imported);
        assert(perp_import_marker(textures[i],&key,true,&imported) && imported);
    }
    // QI aliases retain the same provenance, with no registry-held reference.
    void *alias=NULL;
    assert(NPT_SUCCEEDED(npt_com_query_interface(textures[0],&NPT_IID_IDXGIResource,&alias)));
    bool imported=false;assert(perp_import_marker(alias,&key,false,&imported) && imported);
    npt_com_release(alias);
    for(unsigned i=0;i<257;i++)npt_com_release(textures[i]);
    void *fresh=NULL;assert(NPT_SUCCEEDED(texture(device,&desc,NULL,(ID3D11Texture2D **)&fresh)));
    assert(perp_import_marker(fresh,&key,false,&imported) && !imported);
    // An unexpected private-data value must fail closed.
    uint8_t bad=1;
    assert(NPT_SUCCEEDED(CALL(PFN_ID3D11DeviceChild_SetPrivateData,fresh,NPT_VTBL_ID3D11DeviceChild_SetPrivateData)(fresh,&key,1,&bad)));
    assert(!perp_import_marker(fresh,&key,false,&imported));
    npt_com_release(fresh);npt_com_release(context);npt_com_release(device);
    puts("Actual backend: 257 simultaneous marked textures, alias identity, fresh resource and malformed marker checked.");
    return 0;
}
