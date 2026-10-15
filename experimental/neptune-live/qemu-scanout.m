/* SPDX-License-Identifier: MIT
 * Called by actual virtio-gpu-virgl SET_SCANOUT_BLOB/RESOURCE_FLUSH/reset.
 * No fixture device, native object bootstrap or driver-side opcode. */
#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "qemu/atomic.h"
#include "ui/egl-helpers.h"
#include "qemu-live.h"
#include "live.h"
#include "adapter.h"
#include <sys/mman.h>
#include <sys/stat.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

typedef struct LiveRead LiveRead;
typedef struct LiveConsole {
    void *owner;QemuConsole *console;uint32_t resource,width,height,x,y,crop_width,crop_height;
    uint64_t generation;bool active,failed;
    LiveRead *current_read;
} LiveConsole;
struct LiveRead {LiveConsole *console;uint64_t generation;PerpLiveLease lease;};
static LiveConsole display;
static QEMUTimer *timer;
static uint64_t configuration_sequence;
static uint64_t reads,cancels,mappings_released,native_released,flushes,selects;
static bool hold_read;
static bool delay_done,hold_adapter;
static LiveRead *delayed_done;
static id<MTLSharedEvent> held_event;
static uint64_t held_value;
bool perp_live_qemu_hold_read(void) {return hold_read;}
void perp_live_qemu_set_hold_read(bool hold) {hold_read=hold;}
static void finish_console_state(LiveRead *read)
{
    LiveConsole *con=read->console;
    if(con->generation==read->generation && con->current_read==read) {
        con->active=false;con->current_read=NULL;
    }
    g_free(read);
}
bool perp_live_qemu_delay_done(void) {return delay_done;}
void perp_live_qemu_set_delay_done(bool delay)
{
    delay_done=delay;
    if(!delay && delayed_done) {LiveRead *old=delayed_done;delayed_done=NULL;finish_console_state(old);}
}
bool perp_live_qemu_hold_adapter(void) {return hold_adapter;}
void perp_live_qemu_set_hold_adapter(bool hold)
{
    hold_adapter=hold;
    if(!hold && held_event) {held_event.signaledValue=held_value;[held_event release];held_event=nil;}
}
static void tick(void *opaque);
static void cleanup_native(ScanoutTextureNative *native) {[(id<MTLTexture>)native->handle release];native_released++;}
static void completed_read(void *opaque,PerpMetalCompletion result)
{
    LiveRead *read=opaque;LiveConsole *con=read->console;
    bool good=result==PERP_METAL_READ_COMPLETE && con->generation==read->generation && con->current_read==read;
    perp_live_scanout_done(&read->lease,good);if(good)reads++;else cancels++;
    /* The development adversarial hook delays only this post-ACK state
     * continuation. It retains no GPU object, snapshot fd or worker budget. */
    if(delay_done && !delayed_done)delayed_done=read;else finish_console_state(read);
}
static void fail(LiveConsole *con,const char *reason)
{
    if(!con->failed)fprintf(stderr,"perp-live console: capture closed: %s\n",reason);
    con->failed=true;
}
static bool publish(LiveConsole *con,PerpLiveLease *lease)
{
    const dxn_shared_texture *d=&lease->texture;uint64_t width=d->meta.width,height=d->meta.height;
    if(lease->version!=1 || lease->resource_id!=con->resource || !lease->worker_epoch || !lease->resource_epoch ||
       !dxn_shared_check(d,DXN_SHARED_TEXTURE_MAGIC,sizeof(*d)) || width!=con->width || height!=con->height ||
       !width || !height || width>4096 || height>4096 || width*height>8*1024*1024 ||
       d->meta.dxgi_format!=87 || d->meta.mip_levels!=1 || d->meta.array_size!=1 || d->meta.sample_count!=1 ||
       d->meta.sample_quality || d->meta.cpu_access_flags || d->meta.usage || d->plane_count!=1 || d->reserved ||
       d->drm_modifier || d->planes[0].offset || d->planes[0].pitch<width*4 || d->planes[0].pitch>65536 ||
       d->size!=(uint64_t)d->planes[0].pitch*height || d->size>LIVE_MAX_BYTES ||
       con->x>width || con->crop_width>width-con->x || con->y>height || con->crop_height>height-con->y) {
        fail(con,"resource/epoch/layout/crop");return false;
    }
    size_t page=getpagesize(),bytes=(d->size+page-1)&~(page-1);struct stat st;
    if(fstat(lease->memory_fd,&st) || st.st_size<0 || (uint64_t)st.st_size<bytes || st.st_size>LIVE_MAX_BYTES ||
       (!S_ISREG(st.st_mode) && (st.st_mode&S_IFMT))) {fail(con,"snapshot extent");return false;}
    id<MTLDevice> device=(id<MTLDevice>)qemu_egl_angle_native_device;
    NSUInteger alignment=[device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
    if(!device || !alignment || d->planes[0].pitch%alignment) {fail(con,"Metal alignment");return false;}
    void *mapping=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,lease->memory_fd,0);
    if(mapping==MAP_FAILED) {fail(con,"snapshot mmap");return false;}
    id<MTLBuffer> backing=[device newBufferWithBytesNoCopy:mapping length:bytes options:MTLResourceStorageModeShared
        deallocator:^(void *pointer,NSUInteger length) {munmap(pointer,length);qatomic_inc(&mappings_released);}];
    if(!backing) {munmap(mapping,bytes);fail(con,"Metal backing");return false;}
    MTLTextureDescriptor *format=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    format.storageMode=MTLStorageModeShared;format.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[backing newTextureWithDescriptor:format offset:0 bytesPerRow:d->planes[0].pitch];[backing release];
    if(!texture) {fail(con,"Metal texture");return false;}
    id<MTLSharedEvent> ready=[device newSharedEvent];
    if(!ready) {[texture release];fail(con,"consumer notification");return false;}
    /* Renderer broker take() proved actual producer POLLIN without EOF/HUP.
     * This local event only records that already-established completion. */
    if(hold_adapter) {held_event=[ready retain];held_value=lease->generation;}
    else ready.signaledValue=lease->generation;
    qemu_console_resize(con->console,con->crop_width,con->crop_height);
    LiveRead *read=g_new0(LiveRead,1);*read=(LiveRead){con,con->generation,*lease};
    if(!perp_metal_headless_publish(con->console,texture,ready,lease->generation,completed_read,read)) {
        [ready release];[texture release];g_free(read);fail(con,"adapter lease rejected");return false;
    }
    [ready release];con->active=true;con->current_read=read;
    ScanoutTextureNative native={SCANOUT_TEXTURE_NATIVE_TYPE_METAL,texture};
    dpy_gl_scanout_texture(con->console,0,false,width,height,con->x,con->y,con->crop_width,con->crop_height,native,cleanup_native);
    dpy_gl_update(con->console,0,0,con->crop_width,con->crop_height);return true;
}
static void tick(void *opaque)
{
    (void)opaque;perp_live_scanout_pump();
    if(display.resource && !display.active && !display.failed && !hold_read) {
        PerpLiveLease lease;
        if(perp_live_scanout_take(display.resource,&lease)) {
            if(!publish(&display,&lease))perp_live_scanout_done(&lease,false);
            close(lease.memory_fd);
        }
    }
    if(display.owner || perp_live_scanout_needs_pump())timer_mod(timer,qemu_clock_get_ms(QEMU_CLOCK_REALTIME)+8);
}
bool perp_live_qemu_select(void *owner,QemuConsole *console,unsigned output,uint32_t resource,
    uint32_t width,uint32_t height,uint32_t x,uint32_t y,uint32_t crop_width,uint32_t crop_height)
{
    if(!perp_live_scanout_select(resource))return false;
    /* Initial live gate supports one controller and output, with exact full
     * framebuffer/crop validation. Other head ownership is rejected. */
    if(output || (display.owner && display.owner!=owner)) {fail(&display,"multiple controller/output");return true;}
    if(display.resource!=resource || display.width!=width || display.height!=height || display.x!=x || display.y!=y ||
       display.crop_width!=crop_width || display.crop_height!=crop_height) {
        display.generation=++configuration_sequence;
        if(!display.generation) {fail(&display,"configuration generation overflow");return true;}
        if(display.console)dpy_gl_scanout_disable(display.console);
        display.active=false;display.current_read=NULL;
        if(held_event) {[held_event release];held_event=nil;}
    }
    display.owner=owner;display.console=console;display.resource=resource;display.width=width;display.height=height;
    display.x=x;display.y=y;display.crop_width=crop_width;display.crop_height=crop_height;selects++;
    if(!timer)timer=timer_new_ms(QEMU_CLOCK_REALTIME,tick,NULL);
    timer_mod(timer,qemu_clock_get_ms(QEMU_CLOCK_REALTIME));return true;
}
bool perp_live_qemu_flush(void *owner,unsigned output,uint32_t resource)
{
    if(display.owner!=owner || output || display.resource!=resource)return false;
    flushes++;tick(NULL);return true;
}
void perp_live_qemu_reset(void *owner)
{
    if(display.owner!=owner)return;
    display.generation=++configuration_sequence;
    if(display.console)dpy_gl_scanout_disable(display.console);
    if(held_event) {[held_event release];held_event=nil;}
    perp_live_scanout_select(0);
    if(timer)timer_del(timer);memset(&display,0,sizeof(display));
    /* Continue only the bounded ACK/revoke drain after scanout is disabled;
     * no console pointer or old configuration may survive this reset. */
    perp_live_scanout_pump();
    if(timer && perp_live_scanout_needs_pump())timer_mod(timer,qemu_clock_get_ms(QEMU_CLOCK_REALTIME)+8);
}
char *perp_live_qemu_stats(void)
{
    char *renderer=perp_live_scanout_stats(),*adapter=perp_metal_headless_stats();
    char *result=g_strdup_printf("{\"selects\":%"PRIu64",\"flushes\":%"PRIu64",\"reads\":%"PRIu64",\"cancelled\":%"PRIu64",\"native_released\":%"PRIu64",\"mappings_released\":%"PRIu64",\"console_active\":%s,\"configuration_generation\":%"PRIu64",\"delayed_done\":%u,\"renderer\":%s,\"adapter\":%s}",
        selects,flushes,reads,cancels,native_released,qatomic_read(&mappings_released),display.active?"true":"false",display.generation,delayed_done?1:0,renderer,adapter);
    free(renderer);g_free(adapter);return result;
}
