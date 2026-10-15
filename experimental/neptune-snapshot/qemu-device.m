/* SPDX-License-Identifier: MIT
 * Development bridge from actual Neptune snapshot fd to the frozen adapter. */
#include "qemu/osdep.h"
#include "qemu/module.h"
#include "qemu/atomic.h"
#include "qapi/error.h"
#include "hw/qdev-core.h"
#include "hw/qdev-properties.h"
#include "ui/console.h"
#include "ui/egl-helpers.h"
#include "adapter.h"
#include "wire.h"
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#define TYPE_PERP_NEPTUNE_TEST "perp-neptune-test"
OBJECT_DECLARE_SIMPLE_TYPE(PerpNeptuneTest,PERP_NEPTUNE_TEST)
struct PerpNeptuneTest {
    DeviceState parent_obj;
    QemuConsole *con;
    uint32_t channel;
    int ready_fd;
    uint32_t generation;
    bool active,overwritten,ended;
    id<MTLSharedEvent> event;
    uint64_t frames,completed,cancelled;
    char *failure;
};
static uint64_t mappings_released,native_released;
static void fail(PerpNeptuneTest *s,const char *message)
{
    if(!s->failure) { s->failure=g_strdup(message); fprintf(stderr,"perp-neptune bridge: %s\n",message); }
}
static void native_cleanup(ScanoutTextureNative *native)
{
    [(id<MTLTexture>)native->handle release]; native_released++;
}
static void lease_done(void *opaque,PerpMetalCompletion status)
{
    PerpNeptuneTest *s=opaque;
    PerpSnapshotAck ack={PERP_SNAPSHOT_MAGIC,s->generation,status==PERP_METAL_READ_COMPLETE?0:1,0};
    if(send(s->channel,&ack,sizeof(ack),MSG_DONTWAIT)!=(ssize_t)sizeof(ack)) fail(s,"Snapshot ACK send failed");
    if(status==PERP_METAL_READ_COMPLETE) s->completed++; else s->cancelled++;
    if(s->ready_fd>=0) close(s->ready_fd);
    s->ready_fd=-1; [s->event release]; s->event=nil; s->active=false;
}
static bool accept_snapshot(PerpNeptuneTest *s,const PerpSnapshotPacket *packet,int fds[2])
{
    const dxn_shared_texture *desc=&packet->texture;
    unsigned width=desc->meta.width,height=desc->meta.height;
    if(packet->generation<=s->generation || !packet->context_id || !packet->blob_id ||
       !dxn_shared_check(desc,DXN_SHARED_TEXTURE_MAGIC,sizeof(*desc)) || !width || !height ||
       width>4096 || height>4096 || (uint64_t)width*height>8*1024*1024 ||
       desc->meta.dxgi_format!=87 || desc->meta.mip_levels!=1 || desc->meta.array_size!=1 ||
       desc->meta.sample_count!=1 || desc->meta.sample_quality || desc->meta.cpu_access_flags || desc->meta.usage!=0 ||
       desc->plane_count!=1 || desc->reserved || desc->drm_modifier || desc->planes[0].offset ||
       desc->planes[0].pitch<(uint64_t)width*4 || desc->planes[0].pitch>65536 ||
       desc->size!=desc->planes[0].pitch*height || desc->size>64*1024*1024) {
        fail(s,"Rejected snapshot layout"); return false;
    }
    size_t page=getpagesize(),bytes=(desc->size+page-1)&~(page-1);
    struct stat st;
    if(fstat(fds[0],&st) || st.st_size<0 || (uint64_t)st.st_size<bytes || st.st_size>64*1024*1024 ||
       (!S_ISREG(st.st_mode) && (st.st_mode&S_IFMT)!=0)) { fail(s,"Rejected SHM extent"); return false; }
    id<MTLDevice> device=(id<MTLDevice>)qemu_egl_angle_native_device;
    NSUInteger alignment=[device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
    if(!device || !alignment || desc->planes[0].pitch%alignment) { fail(s,"Rejected Metal alignment"); return false; }
    void *mapping=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fds[0],0);
    if(mapping==MAP_FAILED) { fail(s,"Snapshot mmap failed"); return false; }
    id<MTLBuffer> backing=[device newBufferWithBytesNoCopy:mapping length:bytes options:MTLResourceStorageModeShared
        deallocator:^(void *pointer,NSUInteger length) { munmap(pointer,length); qatomic_inc(&mappings_released); }];
    if(!backing) { munmap(mapping,bytes); fail(s,"Snapshot Metal buffer failed"); return false; }
    MTLTextureDescriptor *format=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    format.storageMode=MTLStorageModeShared; format.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[backing newTextureWithDescriptor:format offset:0 bytesPerRow:desc->planes[0].pitch];
    [backing release];
    if(!texture) { fail(s,"Snapshot Metal texture failed"); return false; }
    s->event=[device newSharedEvent]; s->generation=packet->generation; s->overwritten=false;
    if(!s->event) { [texture release]; fail(s,"Consumer ready event failed"); return false; }
    qemu_console_resize(s->con,width,height);
    if(!perp_metal_headless_publish(s->con,texture,s->event,s->generation,lease_done,s)) {
        [s->event release]; s->event=nil; [texture release]; fail(s,"Adapter refused lease"); return false;
    }
    s->active=true; s->ready_fd=fds[1]; fds[1]=-1; s->frames++;
    ScanoutTextureNative native={SCANOUT_TEXTURE_NATIVE_TYPE_METAL,texture};
    dpy_gl_scanout_texture(s->con,0,false,width,height,0,0,width,height,native,native_cleanup);
    dpy_gl_update(s->con,0,0,width,height);
    return true;
}
static void pump(void *opaque)
{
    PerpNeptuneTest *s=opaque;
    if(s->failure || s->ended) return;
    if(!s->active) {
        char peek; ssize_t available=recv(s->channel,&peek,1,MSG_PEEK|MSG_DONTWAIT);
        if(available==0) { s->ended=true; return; }
        PerpSnapshotPacket packet; int fds[2];
        int result=perp_snapshot_receive(s->channel,&packet,fds);
        if(result==1) return;
        if(result<0) { fail(s,"Snapshot packet/fd framing failed"); return; }
        accept_snapshot(s,&packet,fds);
        if(fds[0]>=0) close(fds[0]); if(fds[1]>=0) close(fds[1]);
    }
    if(s->active) {
        if(!s->overwritten) {
            char value=0; ssize_t count=recv(s->channel,&value,1,MSG_DONTWAIT);
            if(count==1 && value=='O') s->overwritten=true;
            else if(count==0 || (count<0 && errno!=EAGAIN && errno!=EWOULDBLOCK) || count>0) fail(s,"Overwrite verification transition failed");
        }
        struct pollfd fd={s->ready_fd,POLLIN,0};
        if(poll(&fd,1,0)>0) {
            if(fd.revents&(POLLHUP|POLLERR|POLLNVAL)) fail(s,"Producer ready fd failed");
            else if(s->overwritten && fd.revents&POLLIN) s->event.signaledValue=s->generation;
        }
    }
}
static void advance(Object *obj,bool value,Error **errp)
{
    PerpNeptuneTest *s=PERP_NEPTUNE_TEST(obj);
    if(!value) return;
    if(s->active || s->failure || s->ended) { error_setg(errp,"Snapshot fixture is not ready to advance"); return; }
    char next='N';
    if(send(s->channel,&next,1,MSG_DONTWAIT)!=1) error_setg(errp,"Producer control send failed");
}
static void close_backend(Object *obj,bool value,Error **errp)
{
    if(value) { perp_metal_headless_shutdown(); dpy_gl_scanout_disable(PERP_NEPTUNE_TEST(obj)->con); }
}
static char *stats(Object *obj,Error **errp)
{
    PerpNeptuneTest *s=PERP_NEPTUNE_TEST(obj);
    char *backend=perp_metal_headless_stats();
    char *result=g_strdup_printf("{\"frames\":%"PRIu64",\"completed\":%"PRIu64",\"cancelled\":%"PRIu64","
        "\"mappings_released\":%"PRIu64",\"native_released\":%"PRIu64",\"active\":%s,\"ended\":%s,"
        "\"error\":%s,\"backend\":%s}",s->frames,s->completed,s->cancelled,qatomic_read(&mappings_released),native_released,
        s->active?"true":"false",s->ended?"true":"false",s->failure?"\"bridge failure; inspect process log\"":"null",backend);
    g_free(backend); return result;
}
static const GraphicHwOps hardware_ops={.gfx_update=pump};
static void realize(DeviceState *dev,Error **errp)
{
    PerpNeptuneTest *s=PERP_NEPTUNE_TEST(dev);
    struct sockaddr address; socklen_t length=sizeof(address); int enabled=1;
    if(s->channel==UINT32_MAX || getsockname(s->channel,&address,&length) || address.sa_family!=AF_UNIX ||
       setsockopt(s->channel,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled))) {
        error_setg(errp,"Test requires an inherited private Unix channel"); return;
    }
    s->ready_fd=-1; s->con=graphic_console_init(dev,0,&hardware_ops,s);
}
static void unrealize(DeviceState *dev)
{
    PerpNeptuneTest *s=PERP_NEPTUNE_TEST(dev);
    dpy_gl_scanout_disable(s->con); graphic_console_close(s->con);
    close(s->channel); g_free(s->failure);
}
static const Property properties[]={ DEFINE_PROP_UINT32("channel",PerpNeptuneTest,channel,UINT32_MAX) };
static void class_init(ObjectClass *klass,void *opaque)
{
    DeviceClass *dc=DEVICE_CLASS(klass); dc->realize=realize; dc->unrealize=unrealize;
    device_class_set_props(dc,properties); dc->desc="Owned Neptune snapshot consumer fixture";
    object_class_property_add_bool(klass,"advance",NULL,advance);
    object_class_property_add_bool(klass,"closed",NULL,close_backend);
    object_class_property_add_str(klass,"stats",stats,NULL);
}
static const TypeInfo info={.name=TYPE_PERP_NEPTUNE_TEST,.parent=TYPE_DEVICE,.instance_size=sizeof(PerpNeptuneTest),.class_init=class_init};
static void register_device(void) { type_register_static(&info); }
type_init(register_device);
