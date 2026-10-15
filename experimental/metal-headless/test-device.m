/* SPDX-License-Identifier: MIT
 * Explicitly synthetic host-only QOM device. No guest CPU, disks or drivers.
 */
#include "qemu/osdep.h"
#include "qemu/module.h"
#include "qapi/error.h"
#include "hw/qdev-core.h"
#include "qom/object.h"
#include "ui/console.h"
#include "ui/egl-helpers.h"
#include "adapter.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#define TYPE_PERP_METAL_TEST "perp-metal-test"
OBJECT_DECLARE_SIMPLE_TYPE(PerpMetalTest, PERP_METAL_TEST)

struct PerpMetalTest {
    DeviceState parent_obj;
    QemuConsole *con;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLSharedEvent> delayed_event;
    id<MTLCommandBuffer> delayed_command;
    uint64_t delayed_value, sequence, done, abandoned;
    char *scene;
};

static uint64_t native_cleanups;
static void native_cleanup(ScanoutTextureNative *native)
{
    [(id<MTLTexture>)native->handle release];
    native_cleanups++;
}

static void lease_done(void *opaque, PerpMetalCompletion result)
{
    PerpMetalTest *s = opaque;
    if (result == PERP_METAL_READ_COMPLETE) { s->done++; }
    else { s->abandoned++; }
}

static bool prepare_pipeline(PerpMetalTest *s, Error **errp)
{
    id<MTLDevice> device = (id<MTLDevice>)qemu_egl_angle_native_device;
    if (!device) { error_setg(errp, "Test needs explicit Metal headless backend"); return false; }
    if (s->pipeline) { return true; }
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "fragment float4 fs(float4 p [[position]],constant uint2 &sz [[buffer(0)]]) { if(uint(p.x)==sz.x/2 || uint(p.y)==sz.y/2) return float4(17.0f/255,136.0f/255,204.0f/255,1); if(p.y<float(sz.y/2)) return p.x<float(sz.x/2)?float4(1,0,0,1):float4(0,1,0,1); return p.x<float(sz.x/2)?float4(0,0,1,1):float4(1,1,1,1); }";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) { error_setg(errp, "Metal shader: %s", error.localizedDescription.UTF8String); return false; }
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vs"];
    desc.fragmentFunction = [library newFunctionWithName:@"fs"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    s->pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    s->queue = [device newCommandQueue];
    [desc.vertexFunction release]; [desc.fragmentFunction release];
    [desc release]; [library release];
    if (!s->pipeline || !s->queue) {
        [s->pipeline release]; [s->queue release]; s->pipeline = nil; s->queue = nil;
        error_setg(errp, "Metal pipeline creation failed"); return false;
    }
    return true;
}

static void set_scene(Object *obj, const char *name, Error **errp)
{
    PerpMetalTest *s = PERP_METAL_TEST(obj);
    if (!strcmp(name, "2d")) {
        dpy_gl_scanout_disable(s->con);
        qemu_console_resize(s->con, 320, 200);
        DisplaySurface *surface = qemu_console_surface(s->con);
        for (unsigned y = 0; y < 200; y++) {
            uint32_t *row = (uint32_t *)(surface_data(surface) + y * surface_stride(surface));
            for (unsigned x = 0; x < 320; x++) { row[x] = 0xff1188ccu; }
        }
        dpy_gfx_update(s->con, 0, 0, 320, 200);
        g_free(s->scene); s->scene = g_strdup(name);
        return;
    }
    bool linear = !strcmp(name, "linear");
    bool crop = !strcmp(name, "crop");
    bool delayed = !strcmp(name, "delayed");
    bool missing = !strcmp(name, "no-fence");
    bool timeout = !strcmp(name, "timeout");
    bool invalid = !strcmp(name, "invalid-crop");
    if (strcmp(name, "private") && !linear && !crop && !delayed && !missing && !timeout && !invalid) {
        error_setg(errp, "Unknown fixed synthetic scene"); return;
    }
    if (!prepare_pipeline(s, errp)) { return; }
    unsigned width = linear ? 1920 : crop ? 803 : 800;
    unsigned height = linear ? 1080 : crop ? 607 : 600;
    unsigned x = crop ? 7 : 0, y = crop ? 11 : 0;
    unsigned backing_width = width + (crop ? 22 : 0);
    unsigned backing_height = height + (crop ? 26 : 0);
    id<MTLDevice> device = (id<MTLDevice>)qemu_egl_angle_native_device;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:backing_width height:backing_height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> source = [device newTextureWithDescriptor:desc];
    id<MTLTexture> scanout = [source retain];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = source;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> command = [s->queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    uint32_t size[] = { backing_width, backing_height };
    [encoder setRenderPipelineState:s->pipeline];
    [encoder setViewport:(MTLViewport){0,0,backing_width,backing_height,0,1}];
    [encoder setFragmentBytes:size length:sizeof(size) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    if (linear) {
        NSUInteger alignment = [device minimumLinearTextureAlignmentForPixelFormat:desc.pixelFormat];
        NSUInteger pitch = (width * 4 + alignment - 1) / alignment * alignment;
        id<MTLBuffer> backing = [device newBufferWithLength:pitch * height options:MTLResourceStorageModeShared];
        desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
        [scanout release];
        scanout = [backing newTextureWithDescriptor:desc offset:0 bytesPerRow:pitch];
        [backing release];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit copyFromTexture:source sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1)
            toTexture:scanout destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding];
    }
    id<MTLSharedEvent> ready = [device newSharedEvent];
    uint64_t value = ++s->sequence;
    if (!delayed && !timeout) { [command encodeSignalEvent:ready value:value]; }
    [command commit]; /* deliberately no CPU wait on the ordinary producer */
    [source release];
    if (delayed || timeout) {
        /* Negative fixture withholds the ready token after actual GPU writes
         * complete. A mutation bypassing the token is detected without ever
         * racing an unfinished GPU producer in the test itself. */
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) {
            [scanout release]; [ready release]; error_setg(errp, "Fixture producer failed"); return;
        }
    }
    if (delayed) {
        [s->delayed_event release]; [s->delayed_command release];
        s->delayed_event = [ready retain];
        s->delayed_command = [command retain]; s->delayed_value = value;
    }
    qemu_console_resize(s->con, width, height);
    if (!missing && !perp_metal_headless_publish(s->con, scanout, ready, value, lease_done, s)) {
        [ready release]; [scanout release]; error_setg(errp, "Lease publication refused"); return;
    }
    ScanoutTextureNative native = { SCANOUT_TEXTURE_NATIVE_TYPE_METAL, scanout };
    dpy_gl_scanout_texture(s->con, 0, false, backing_width, backing_height,
                            invalid ? backing_width : x, y, width, height,
                            native, native_cleanup); /* transfers scanout retain */
    dpy_gl_update(s->con, 0, 0, width, height);
    [ready release];
    g_free(s->scene); s->scene = g_strdup(name);
}

static char *get_scene(Object *obj, Error **errp)
{
    return g_strdup(PERP_METAL_TEST(obj)->scene ?: "initial");
}

static void signal_ready(Object *obj, bool value, Error **errp)
{
    PerpMetalTest *s = PERP_METAL_TEST(obj);
    if (value && s->delayed_event) {
        [s->delayed_command waitUntilCompleted];
        if (s->delayed_command.status != MTLCommandBufferStatusCompleted) {
            error_setg(errp, "Delayed producer failed"); return;
        }
        s->delayed_event.signaledValue = s->delayed_value;
    }
}

static bool ready_state(Object *obj, Error **errp)
{
    PerpMetalTest *s = PERP_METAL_TEST(obj);
    return s->delayed_event && s->delayed_event.signaledValue >= s->delayed_value;
}

static void close_backend(Object *obj, bool value, Error **errp)
{
    if (value) {
        perp_metal_headless_shutdown();
        /* Release the console-owned native handle too, after the adapter's
         * read lease and separate native retain have both been released. */
        dpy_gl_scanout_disable(PERP_METAL_TEST(obj)->con);
    }
}

static char *stats(Object *obj, Error **errp)
{
    PerpMetalTest *s = PERP_METAL_TEST(obj);
    char *backend = perp_metal_headless_stats();
    char *result = g_strdup_printf("{\"backend\":%s,\"done\":%" PRIu64
        ",\"abandoned\":%" PRIu64 ",\"native_cleanups\":%" PRIu64 "}",
        backend, s->done, s->abandoned, native_cleanups);
    g_free(backend); return result;
}

static void hardware_update(void *opaque) { }
static const GraphicHwOps hardware_ops = { .gfx_update = hardware_update };
static void realize(DeviceState *dev, Error **errp)
{
    PerpMetalTest *s = PERP_METAL_TEST(dev);
    s->con = graphic_console_init(dev, 0, &hardware_ops, s);
}

static void unrealize(DeviceState *dev)
{
    PerpMetalTest *s = PERP_METAL_TEST(dev);
    dpy_gl_scanout_disable(s->con);
    graphic_console_close(s->con);
    [s->delayed_command release]; [s->delayed_event release];
    [s->queue release]; [s->pipeline release]; g_free(s->scene);
}

static void class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    dc->realize = realize; dc->unrealize = unrealize;
    dc->desc = "Synthetic Metal scanout test; no guest or disks";
    object_class_property_add_str(klass, "scene", get_scene, set_scene);
    object_class_property_add_str(klass, "stats", stats, NULL);
    object_class_property_add_bool(klass, "ready", ready_state, signal_ready);
    object_class_property_add_bool(klass, "closed", NULL, close_backend);
}

static const TypeInfo info = { .name = TYPE_PERP_METAL_TEST,
    .parent = TYPE_DEVICE, .instance_size = sizeof(PerpMetalTest),
    .class_init = class_init };
static void register_test(void) { type_register_static(&info); }
type_init(register_test);
