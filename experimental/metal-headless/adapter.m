/* SPDX-License-Identifier: MIT
 * Experimental macOS-only implementation of QEMU's existing egl-headless slot.
 * No window, guest integration, TCP endpoint or producer-fence inference.
 */
#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "qemu/notify.h"
#include "qemu/timer.h"
#include "qapi/error.h"
#include "system/system.h"
#include "ui/console.h"
#include "ui/egl-helpers.h"
#include "adapter.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#define PERP_MAX_DIMENSION 4096u
#define PERP_MAX_PIXELS (8u * 1024u * 1024u)
#define PERP_READY_TIMEOUT_MS 1000

typedef struct PerpLease {
    id<MTLTexture> texture;
    id<MTLSharedEvent> event;
    uint64_t value;
    int64_t deadline;
    void (*done)(void *, PerpMetalCompletion);
    void *opaque;
} PerpLease;

typedef struct PerpDisplay {
    DisplayChangeListener listener;
    DisplayGLCtx gl;
    DisplaySurface *surface; /* borrowed from console; updated by gfx_switch */
    id<MTLTexture> native;   /* separate retain from the console's cleanup */
    uint32_t x, y, width, height;
    bool valid;
    PerpLease lease;
} PerpDisplay;

static GList *displays, *client_contexts;
static EGLContext root_context, read_context;
static EGLSurface pbuffer;
static id<MTLDevice> device;
static bool closed;
static uint64_t submitted, completed, cancelled, rejected, timed_out;
static uint64_t superseded, invalidated, shutdown_cancelled, max_pending_leases;
static uint64_t peak_readback_bytes, max_readback_us;

static PerpDisplay *find_display(QemuConsole *con)
{
    for (GList *item = displays; item; item = item->next) {
        PerpDisplay *d = item->data;
        if (d->listener.con == con) {
            return d;
        }
    }
    return NULL;
}

static void finish_lease(PerpDisplay *d, PerpMetalCompletion result)
{
    PerpLease old = d->lease;
    if (!old.texture) {
        return;
    }
    memset(&d->lease, 0, sizeof(d->lease));
    [old.texture release];
    [old.event release];
    if (result == PERP_METAL_READ_COMPLETE) {
        completed++;
    } else {
        cancelled++;
        if (result == PERP_METAL_TIMEOUT) { timed_out++; }
        if (result == PERP_METAL_SUPERSEDED) { superseded++; }
        if (result == PERP_METAL_INVALID) { invalidated++; }
        if (result == PERP_METAL_SHUTDOWN) { shutdown_cancelled++; }
    }
    old.done(old.opaque, result);
}

bool perp_metal_headless_publish(QemuConsole *con, void *texture,
                                  void *ready_event, uint64_t ready_value,
                                  void (*done)(void *, PerpMetalCompletion),
                                  void *opaque)
{
    PerpDisplay *d = find_display(con);
    id<MTLTexture> tex = (id<MTLTexture>)texture;
    id<MTLSharedEvent> event = (id<MTLSharedEvent>)ready_event;
    if (closed || !d || !tex || !event || !ready_value || !done ||
        tex.device != device || (event.device && event.device != device)) {
        rejected++;
        return false; /* caller keeps its lease on a rejected publication */
    }
    finish_lease(d, PERP_METAL_SUPERSEDED);
    d->lease = (PerpLease) {
        [tex retain], [event retain], ready_value,
        qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + PERP_READY_TIMEOUT_MS,
        done, opaque,
    };
    submitted++;
    uint64_t active = 0;
    for (GList *item = displays; item; item = item->next) {
        active += ((PerpDisplay *)item->data)->lease.texture != nil;
    }
    max_pending_leases = MAX(max_pending_leases, active);
    return true;
}

static bool copy_pixels(PerpDisplay *d)
{
    int64_t started = g_get_monotonic_time();
    EGLDisplay saved_display = eglGetCurrentDisplay();
    EGLContext saved_context = eglGetCurrentContext();
    EGLSurface saved_draw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface saved_read = eglGetCurrentSurface(EGL_READ);
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    GLuint tex = 0, fb = 0, pack = 0;
    size_t bytes = (size_t)d->width * d->height * 4;
    uint8_t *rgba = g_try_malloc(bytes);
    bool ok = false;
    bool gpu_read_issued = false;
    const char *stage = "make_read_context_current";
    /* Account only for our scratch plus GL PBO, not driver/texture memory. */
    peak_readback_bytes = MAX(peak_readback_bytes, bytes * 2);
    if (!rgba || !eglMakeCurrent(qemu_egl_display, pbuffer, pbuffer,
                                 read_context)) {
        error_report("perp-metal: read context unavailable (allocation=%d EGL=0x%x)",
                     rgba != NULL, eglGetError());
        g_free(rgba);
        return false;
    }
    image = eglCreateImageKHR(qemu_egl_display, EGL_NO_CONTEXT,
                              EGL_METAL_TEXTURE_ANGLE,
                              (EGLClientBuffer)d->native, NULL);
    if (image == EGL_NO_IMAGE_KHR) {
        stage = "import_metal_image";
        goto out;
    }
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);
    glGenFramebuffers(1, &fb);
    glBindFramebuffer(GL_FRAMEBUFFER, fb);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_TEXTURE_2D, tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        stage = "complete_framebuffer";
        goto out;
    }
    glGenBuffers(1, &pack);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, pack);
    glBufferData(GL_PIXEL_PACK_BUFFER, bytes, NULL, GL_STREAM_READ);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(d->x, d->y, d->width, d->height,
                  GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    gpu_read_issued = true;
    if (glGetError() != GL_NO_ERROR) {
        stage = "issue_pixel_pack_read";
        goto out;
    }
    void *mapped = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, bytes,
                                     GL_MAP_READ_BIT);
    if (!mapped) {
        stage = "map_pixel_pack";
        goto out;
    }
    /* Mapping waits for the GPU read. Copy before unmap, but do not expose
     * pixels until unmap succeeds. No callback can release the lease early. */
    memcpy(rgba, mapped, bytes);
    if (!glUnmapBuffer(GL_PIXEL_PACK_BUFFER) || glGetError() != GL_NO_ERROR) {
        stage = "unmap_pixel_pack";
        goto out;
    }
    if (surface_format(d->surface) != PIXMAN_x8r8g8b8) {
        stage = "surface_pixel_format";
        goto out;
    }
    for (uint32_t y = 0; y < d->height; y++) {
        uint32_t *dst = (uint32_t *)(surface_data(d->surface) +
                                     y * surface_stride(d->surface));
        const uint8_t *src = rgba + (size_t)y * d->width * 4;
        for (uint32_t x = 0; x < d->width; x++, src += 4) {
            dst[x] = 0xff000000u | (uint32_t)src[0] << 16 |
                     (uint32_t)src[1] << 8 | src[2];
        }
    }
    ok = true;
out:
    if (!ok) { error_report("perp-metal: read failed at %s (EGL 0x%x, GL 0x%x)",
                            stage, eglGetError(), glGetError()); }
    if (gpu_read_issued) {
        /* Even a failed map must drain this consumer's commands before its
         * producer is allowed to reuse the texture. This is not a producer
         * cross-queue fence; that was checked before entering this function. */
        glFinish();
        if (glGetError() != GL_NO_ERROR) {
            error_report("perp-metal: cannot establish consumer completion; stopping experimental process");
            exit(EXIT_FAILURE);
        }
    }
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (pack) { glDeleteBuffers(1, &pack); }
    if (fb) { glDeleteFramebuffers(1, &fb); }
    if (tex) { glDeleteTextures(1, &tex); }
    if (image != EGL_NO_IMAGE_KHR) {
        eglDestroyImageKHR(qemu_egl_display, image);
    }
    g_free(rgba);
    /* GL object destruction follows synchronous mapping, or GL deletion's
     * deferred lifetime rules on failure. No CPU pointer outlives unmap. */
    if (saved_context != EGL_NO_CONTEXT) {
        if (!eglMakeCurrent(saved_display, saved_draw, saved_read, saved_context)) {
            error_report("perp-metal: failed to restore renderer EGL context");
            ok = false;
        }
    } else {
        eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                        EGL_NO_CONTEXT);
    }
    max_readback_us = MAX(max_readback_us, g_get_monotonic_time() - started);
    return ok;
}

static void present(PerpDisplay *d)
{
    if (closed || !d->lease.texture) {
        return;
    }
    if (!d->valid) { finish_lease(d, PERP_METAL_INVALID); return; }
    if (d->lease.texture != d->native) {
        finish_lease(d, PERP_METAL_INVALID);
        return;
    }
    if (d->lease.event.signaledValue < d->lease.value) {
        if (qemu_clock_get_ms(QEMU_CLOCK_REALTIME) >= d->lease.deadline) {
            finish_lease(d, PERP_METAL_TIMEOUT);
        }
        return; /* main loop remains responsive; retry on refresh */
    }
    if (copy_pixels(d)) {
        finish_lease(d, PERP_METAL_READ_COMPLETE);
        dpy_gfx_update(d->listener.con, 0, 0, d->width, d->height);
    } else {
        finish_lease(d, PERP_METAL_INVALID);
    }
}

static void refresh(DisplayChangeListener *listener)
{
    PerpDisplay *d = container_of(listener, PerpDisplay, listener);
    graphic_hw_update(listener->con);
    present(d);
}

static void switch_surface(DisplayChangeListener *listener, DisplaySurface *surface)
{
    PerpDisplay *d = container_of(listener, PerpDisplay, listener);
    finish_lease(d, PERP_METAL_SUPERSEDED);
    [d->native release];
    d->native = nil;
    d->valid = false;
    d->surface = surface;
}

static void disable(DisplayChangeListener *listener)
{
    PerpDisplay *d = container_of(listener, PerpDisplay, listener);
    finish_lease(d, PERP_METAL_SUPERSEDED);
    [d->native release];
    d->native = nil;
    d->valid = false;
}

static void scanout(DisplayChangeListener *listener, uint32_t backing_id,
                      bool backing_y_0_top, uint32_t backing_width,
                      uint32_t backing_height, uint32_t x, uint32_t y,
                      uint32_t width, uint32_t height, ScanoutTextureNative native)
{
    PerpDisplay *d = container_of(listener, PerpDisplay, listener);
    id<MTLTexture> tex = (id<MTLTexture>)native.handle;
    d->valid = false;
    [d->native release];
    d->native = nil;
    if (closed || native.type != SCANOUT_TEXTURE_NATIVE_TYPE_METAL || !tex ||
        tex.device != device || tex.textureType != MTLTextureType2D ||
        (tex.pixelFormat != MTLPixelFormatBGRA8Unorm &&
         tex.pixelFormat != MTLPixelFormatRGBA8Unorm) ||
        !width || !height || width > PERP_MAX_DIMENSION ||
        height > PERP_MAX_DIMENSION || (uint64_t)width * height > PERP_MAX_PIXELS ||
        backing_width != tex.width || backing_height != tex.height ||
        x > backing_width || width > backing_width - x ||
        y > backing_height || height > backing_height - y || !d->surface ||
        surface_width(d->surface) != width || surface_height(d->surface) != height) {
        rejected++;
        finish_lease(d, PERP_METAL_INVALID);
        return;
    }
    /* Metal origin matches Cocoa's native Metal branch: top-left texture
     * coordinates, including crop. backing_y_0_top describes GL-only scanouts;
     * those are deliberately unsupported here. */
    d->native = [tex retain];
    d->x = x; d->y = y; d->width = width; d->height = height;
    d->valid = true;
}

static void update(DisplayChangeListener *listener, uint32_t x, uint32_t y,
                     uint32_t width, uint32_t height)
{
    PerpDisplay *d = container_of(listener, PerpDisplay, listener);
    if (!d->lease.texture) {
        rejected++;
        return; /* handle-only upstream path has no producer ownership proof */
    }
    present(d);
}

static const DisplayChangeListenerOps listener_ops = {
    .dpy_name = "perpendicular-metal-headless-experimental",
    .dpy_refresh = refresh,
    .dpy_gfx_switch = switch_surface,
    .dpy_gl_scanout_disable = disable,
    .dpy_gl_scanout_texture = scanout,
    .dpy_gl_update = update,
};

static bool compatible(DisplayGLCtx *ctx, DisplayChangeListener *listener)
{
    return !listener->ops->dpy_gl_update || listener->ops == &listener_ops;
}

static QEMUGLContext create_context(DisplayGLCtx *ctx, QEMUGLParams *params)
{
    if (closed || params->major_ver > 3) { return NULL; }
    const EGLint attrs[] = { EGL_CONTEXT_CLIENT_VERSION,
                            MAX(2, params->major_ver), EGL_NONE };
    EGLContext value = eglCreateContext(qemu_egl_display, qemu_egl_config,
                                         root_context, attrs);
    if (value != EGL_NO_CONTEXT) { client_contexts = g_list_prepend(client_contexts, value); }
    return value;
}

static void destroy_context(DisplayGLCtx *ctx, QEMUGLContext value)
{
    if (g_list_find(client_contexts, value)) {
        eglDestroyContext(qemu_egl_display, value);
        client_contexts = g_list_remove(client_contexts, value);
    }
}

static int make_current(DisplayGLCtx *ctx, QEMUGLContext value)
{
    return !closed && eglMakeCurrent(qemu_egl_display, pbuffer, pbuffer,
                                      value) ? 0 : -1;
}

static const DisplayGLCtxOps context_ops = {
    .dpy_gl_ctx_is_compatible_dcl = compatible,
    .dpy_gl_ctx_create = create_context,
    .dpy_gl_ctx_destroy = destroy_context,
    .dpy_gl_ctx_make_current = make_current,
};

void perp_metal_headless_shutdown(void)
{
    if (closed) { return; }
    closed = true;
    for (GList *item = displays; item; item = item->next) {
        PerpDisplay *d = item->data;
        unregister_displaychangelistener(&d->listener);
        finish_lease(d, PERP_METAL_SHUTDOWN);
        [d->native release]; d->native = nil; d->valid = false;
        /* Console->gl cannot be unset in this QEMU API. Keep a bounded
         * tombstone with closed context ops until process exit; no dangling ptr. */
    }
    eglMakeCurrent(qemu_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    for (GList *item = client_contexts; item; item = item->next) {
        eglDestroyContext(qemu_egl_display, item->data);
    }
    g_list_free(client_contexts); client_contexts = NULL;
    eglDestroyContext(qemu_egl_display, read_context);
    eglDestroyContext(qemu_egl_display, root_context);
    eglDestroySurface(qemu_egl_display, pbuffer);
    eglTerminate(qemu_egl_display);
    qemu_egl_display = EGL_NO_DISPLAY;
    qemu_egl_rn_ctx = EGL_NO_CONTEXT;
    qemu_egl_angle_native_device = NULL;
    [device release]; device = nil;
}

char *perp_metal_headless_stats(void)
{
    uint64_t active = 0;
    for (GList *item = displays; item; item = item->next) {
        PerpDisplay *d = item->data;
        active += d->lease.texture != nil;
    }
    return g_strdup_printf("{\"submitted\":%" PRIu64 ",\"completed\":%" PRIu64
        ",\"cancelled\":%" PRIu64 ",\"rejected\":%" PRIu64
        ",\"timed_out\":%" PRIu64 ",\"active_leases\":%" PRIu64
        ",\"superseded\":%" PRIu64 ",\"invalidated\":%" PRIu64
        ",\"shutdown_cancelled\":%" PRIu64 ",\"max_pending_leases\":%" PRIu64
        ",\"peak_readback_bytes\":%" PRIu64 ",\"max_readback_us\":%" PRIu64
        ",\"closed\":%s}", submitted, completed, cancelled, rejected,
        timed_out, active, superseded, invalidated, shutdown_cancelled,
        max_pending_leases, peak_readback_bytes, max_readback_us,
        closed ? "true" : "false");
}

static void exit_notify(Notifier *n, void *opaque) { perp_metal_headless_shutdown(); }
static Notifier exit_notifier = { .notify = exit_notify };

static void early_init(DisplayOptions *opts)
{
    PFNEGLGETPLATFORMDISPLAYEXTPROC platform =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    const EGLint attrs[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE,
                             EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    EGLDisplay display = platform ? platform(EGL_PLATFORM_ANGLE_ANGLE, NULL, attrs) : EGL_NO_DISPLAY;
    EGLint major, minor, count;
    const EGLint config[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE };
    const EGLint context[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    const EGLint surface[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
    EGLAttrib egl_device = 0, metal_device = 0;
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor) ||
        !eglBindAPI(EGL_OPENGL_ES_API) ||
        !eglChooseConfig(display, config, &qemu_egl_config, 1, &count) || count != 1) {
        error_report("perp-metal: cannot initialize ANGLE Metal ES3 pbuffer"); exit(1);
    }
    qemu_egl_display = display;
    qemu_egl_mode = DISPLAY_GL_MODE_ES;
    root_context = eglCreateContext(display, qemu_egl_config, EGL_NO_CONTEXT, context);
    read_context = eglCreateContext(display, qemu_egl_config, root_context, context);
    pbuffer = eglCreatePbufferSurface(display, qemu_egl_config, surface);
    if (root_context == EGL_NO_CONTEXT || read_context == EGL_NO_CONTEXT ||
        pbuffer == EGL_NO_SURFACE ||
        !eglMakeCurrent(display, pbuffer, pbuffer, root_context) ||
        !eglQueryDisplayAttribEXT(display, EGL_DEVICE_EXT, &egl_device) ||
        !eglQueryDeviceAttribEXT((EGLDeviceEXT)egl_device, EGL_METAL_DEVICE_ANGLE, &metal_device) ||
        !epoxy_has_egl_extension(display, "EGL_ANGLE_metal_texture_client_buffer")) {
        error_report("perp-metal: incomplete Metal texture-import context"); exit(1);
    }
    device = [(id<MTLDevice>)(void *)metal_device retain];
    qemu_egl_angle_native_device = (void *)device;
    qemu_egl_rn_ctx = root_context;
    display_opengl = 1;
    /* Darwin qemu_init runs on the original thread, then system/main.c moves
     * the BQL/main loop to qemu_main while the original runs CFRunLoopRun.
     * Leaving this surface/context current would cause EGL_BAD_ACCESS there. */
    if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
        error_report("perp-metal: failed to release initialization thread context"); exit(1);
    }
    qemu_add_exit_notifier(&exit_notifier);
}

static void init_display(DisplayState *ds, DisplayOptions *opts)
{
    unsigned count = 0;
    for (unsigned index = 0; ; index++) {
        QemuConsole *con = qemu_console_lookup_by_index(index);
        if (!con) { break; }
        if (!qemu_console_is_graphic(con)) { continue; }
        if (++count > 16) { error_report("perp-metal: at most 16 consoles"); exit(1); }
        PerpDisplay *d = g_new0(PerpDisplay, 1);
        d->listener.con = con; d->listener.ops = &listener_ops;
        d->gl.ops = &context_ops;
        qemu_console_set_display_gl_ctx(con, &d->gl);
        displays = g_list_append(displays, d);
        register_displaychangelistener(&d->listener);
    }
}

static QemuDisplay backend = { .type = DISPLAY_TYPE_EGL_HEADLESS,
    .early_init = early_init, .init = init_display };
static void register_backend(void) { qemu_display_register(&backend); }
type_init(register_backend);
