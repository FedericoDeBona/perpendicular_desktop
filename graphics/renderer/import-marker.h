/* SPDX-License-Identifier: MIT
 * Host-only provenance lives on the COM object, without keeping it alive.
 * The key is random per worker and is never sent through the guest protocol.
 * A failed/ambiguous lookup must close capture, never admit an unknown source.
 */
#ifndef PERP_IMPORT_MARKER_H
#define PERP_IMPORT_MARKER_H
#include "npt_common.h"
#include "npt_com.h"
#include "neptune-protocol/npt_protocol_defs.h"
#include "neptune-protocol/npt_protocol_host_dispatch_types.h"

static bool perp_import_marker(void *object,const GUID *key,bool mark,bool *imported)
{
    void *resource=NULL;
    if(!object)return false;
    HRESULT hr=npt_com_query_interface(object,&NPT_IID_ID3D11Texture2D,&resource);
    bool d3d11=NPT_SUCCEEDED(hr) && resource;
    if(!d3d11) {
        if(resource)npt_com_release(resource);
        resource=NULL;
        hr=npt_com_query_interface(object,&NPT_IID_ID3D12Resource,&resource);
        if(NPT_FAILED(hr) || !resource) {
            if(resource)npt_com_release(resource);
            return false;
        }
    }
    // These inherited methods have identical signatures, but different slots.
    PFN_ID3D11DeviceChild_GetPrivateData get=NPT_COM_VTBL_FUNC(
        PFN_ID3D11DeviceChild_GetPrivateData,npt_com_vtable(resource),
        d3d11?NPT_VTBL_ID3D11DeviceChild_GetPrivateData:NPT_VTBL_ID3D12Object_GetPrivateData);
    PFN_ID3D11DeviceChild_SetPrivateData set=NPT_COM_VTBL_FUNC(
        PFN_ID3D11DeviceChild_SetPrivateData,npt_com_vtable(resource),
        d3d11?NPT_VTBL_ID3D11DeviceChild_SetPrivateData:NPT_VTBL_ID3D12Object_SetPrivateData);
    uint32_t value=1;UINT bytes=sizeof(value);
    bool good=get && set;
    if(good && mark)good=NPT_SUCCEEDED(set(resource,key,sizeof(value),&value));
    if(good) {
        value=0;hr=get(resource,key,&bytes,&value);
        if(!mark && (uint32_t)hr==0x887a0002u) {*imported=false;} // DXGI_ERROR_NOT_FOUND
        else {good=hr==NPT_S_OK && bytes==sizeof(value) && value==1;*imported=good;}
    }
    npt_com_release(resource);
    return good;
}
#endif
