/* SPDX-License-Identifier: MIT
 * Matched Wire1 broker snapshot -> native publisher, with no PBO/readback.
 * The worker copy-before-Signal and broker readiness precede this GPU copy.
 * Its completion, not an unrelated FLUSH, retires the worker snapshot lease. */
#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "qemu/atomic.h"
#include "qemu/main-loop.h"
#include "ui/egl-helpers.h"
#include "qemu-live.h"
#include "live.h"
#include "publisher.h"
#include <sys/mman.h>
#include <sys/stat.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

typedef struct NativeRead {
    uint64_t generation;
    PerpLiveLease lease;
    bool success;
} NativeRead;
static struct {
    void *owner; QemuConsole *console;
    uint32_t resource,width,height,x,y,crop_width,crop_height;
    uint64_t generation;
    NativeRead *current;
    bool failed;
} display;
static QEMUTimer *timer;
static id<MTLCommandQueue> queue;
static id<MTLSharedEvent> held_event;
static bool hold_read, hold_gpu, delay_done;
static NativeRead *delayed;
static uint64_t generations, copies, cancelled, mappings_released, blocked_flushes;

static void completed(void *opaque) {
    NativeRead *read = opaque;
    if (delay_done && !delayed) { delayed = read; return; }
    bool active = read->generation == display.generation && read == display.current;
    perp_live_scanout_done(&read->lease, read->success && active);
    if (read->success && active) copies++; else cancelled++;
    if (active) display.current = NULL;
    g_free(read);
}
bool perp_live_qemu_hold_read(void) { return hold_read; }
void perp_live_qemu_set_hold_read(bool value) { hold_read = value; }
bool perp_live_qemu_delay_done(void) { return delay_done; }
void perp_live_qemu_set_delay_done(bool value) {
    delay_done = value;
    if (!value && delayed) { NativeRead *read = delayed; delayed = NULL; completed(read); }
}
bool perp_live_qemu_hold_adapter(void) { return hold_gpu; }
void perp_live_qemu_set_hold_adapter(bool value) {
    hold_gpu = value;
    if (!value && held_event) { held_event.signaledValue = 1; [held_event release]; held_event = nil; }
}

static bool publish(PerpLiveLease *lease) {
    const dxmt_shared_texture_handle *d = &lease->texture;
    uint64_t width = d->width, height = d->height;
    if (lease->version != 2 || lease->resource_id != display.resource || !lease->worker_epoch || !lease->resource_epoch ||
        !perp_wire1_layout_valid(d) || width != display.width || height != display.height ||
        !width || !height || width > 4096 || height > 4096 || width * height > 8 * 1024 * 1024 ||
        d->dxgi_format != 87 || d->mip_levels != 1 || d->array_size != 1 || d->sample_count != 1 || d->cpu_access ||
        d->offset || d->stride < width * 4 || d->stride > 65536 || d->size != d->stride * height || d->size > LIVE_MAX_BYTES ||
        display.x > width || display.crop_width > width - display.x || display.y > height || display.crop_height > height - display.y)
        return false;
    size_t page = getpagesize(), bytes = (d->size + page - 1) & ~(page - 1);
    struct stat st;
    if (fstat(lease->memory_fd, &st) || st.st_size < 0 || (uint64_t)st.st_size < bytes || st.st_size > LIVE_MAX_BYTES ||
        (!S_ISREG(st.st_mode) && (st.st_mode & S_IFMT))) return false;
    id<MTLDevice> device = (id<MTLDevice>)qemu_egl_angle_native_device;
    NSUInteger alignment = [device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
    if (!device || !alignment || d->stride % alignment) return false;
    void *mapping = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, lease->memory_fd, 0);
    if (mapping == MAP_FAILED) return false;
    id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:mapping length:bytes options:MTLResourceStorageModeShared
        deallocator:^(void *pointer, NSUInteger length) { munmap(pointer, length); qatomic_inc(&mappings_released); }];
    if (!buffer) { munmap(mapping, bytes); return false; }
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [buffer newTextureWithDescriptor:desc offset:0 bytesPerRow:d->stride];
    [buffer release];
    if (!texture) return false;
    if (!queue) queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    if (!command) { [texture release]; return false; }
    if (hold_gpu) {
        if (!held_event) held_event = [device newSharedEvent];
        if (!held_event) { [texture release]; return false; }
        [command encodeWaitForEvent:held_event value:1];
    }
    PNDCaptureResult result = perp_native_display_capture_region(command, texture,
        MTLOriginMake(display.x, display.y, 0), MTLSizeMake(display.crop_width, display.crop_height, 1));
    [texture release];
    if (result != PND_CAPTURE_ENCODED) return false;
    NativeRead *read = g_new0(NativeRead, 1);
    *read = (NativeRead){.generation = display.generation, .lease = *lease};
    display.current = read;
    [command addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        read->success = finished.status == MTLCommandBufferStatusCompleted;
        aio_bh_schedule_oneshot(qemu_get_aio_context(), completed, read);
    }];
    [command commit];
    return true;
}
static void tick(void *opaque) {
    (void)opaque; perp_live_scanout_pump();
    if (display.resource && !display.current && !display.failed && !hold_read && perp_native_display_can_capture()) {
        PerpLiveLease lease;
        if (perp_live_scanout_take(display.resource, &lease)) {
            if (!publish(&lease)) { perp_live_scanout_done(&lease, false); display.failed = true; }
            close(lease.memory_fd);
        }
    }
    if (display.owner || perp_live_scanout_needs_pump()) timer_mod(timer, qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + 8);
}
bool perp_live_qemu_select(void *owner, QemuConsole *console, unsigned output, uint32_t resource,
    uint32_t width, uint32_t height, uint32_t x, uint32_t y, uint32_t crop_width, uint32_t crop_height) {
    const char *enabled = getenv("PERP_NEPTUNE_SCANOUT_BROKER");
    if (!enabled || strcmp(enabled, "1")) return false;
    bool admitted = perp_live_scanout_select(resource);
    if (!admitted || output || (display.owner && display.owner != owner)) { display.failed = true; return true; }
    if (display.resource != resource || display.width != width || display.height != height || display.x != x ||
        display.y != y || display.crop_width != crop_width || display.crop_height != crop_height) {
        display.generation = ++generations; display.current = NULL;
        if (!display.generation) { display.failed = true; return true; }
    }
    display.owner = owner; display.console = console; display.resource = resource;
    display.width = width; display.height = height; display.x = x; display.y = y;
    display.crop_width = crop_width; display.crop_height = crop_height;
    qemu_console_resize(console, crop_width, crop_height);
    if (!timer) timer = timer_new_ms(QEMU_CLOCK_REALTIME, tick, NULL);
    timer_mod(timer, qemu_clock_get_ms(QEMU_CLOCK_REALTIME));
    return true;
}
bool perp_live_qemu_flush(void *owner, unsigned output, uint32_t resource) {
    const char *enabled = getenv("PERP_NEPTUNE_SCANOUT_BROKER");
    if (!enabled || strcmp(enabled, "1")) return false;
    /* An unsupported selection must not re-enter the old unfenced update
     * path through a later FLUSH. Preserve that fallback only when disabled. */
    if (display.owner != owner || output || display.resource != resource) {
        display.failed = true; blocked_flushes++; return true;
    }
    tick(NULL); return true;
}
void perp_live_qemu_reset(void *owner) {
    if (display.owner != owner) return;
    display.generation = ++generations; display.current = NULL;
    display.owner = NULL; display.console = NULL; display.resource = 0;
    display.failed = false;
    perp_native_display_reset();
    perp_live_scanout_select(0);
    if (timer) timer_del(timer);
    perp_live_scanout_pump();
    if (timer && perp_live_scanout_needs_pump()) timer_mod(timer, qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + 8);
}
char *perp_live_qemu_stats(void) {
    char *renderer = perp_live_scanout_stats(), *publisher = perp_native_display_stats();
    char *result = g_strdup_printf("{\"copies\":%"PRIu64",\"cancelled\":%"PRIu64",\"mappings_released\":%"PRIu64
        ",\"blocked_flushes\":%"PRIu64",\"failed\":%s,\"active\":%s,\"publisher_can_capture\":%s,\"renderer\":%s,\"publisher\":%s}",
        copies, cancelled, qatomic_read(&mappings_released), blocked_flushes, display.failed ? "true" : "false", display.current ? "true" : "false",
        perp_native_display_can_capture() ? "true" : "false", renderer, publisher);
    free(renderer); free(publisher); return result;
}
