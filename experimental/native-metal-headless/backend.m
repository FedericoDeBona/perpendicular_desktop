/* SPDX-License-Identifier: MIT
 * Windowless ANGLE/Metal initialization for the checked native Wire1 broker.
 * Shares the proven pbuffer/thread-handoff approach of metal-headless/adapter.m.
 * This backend does not capture, read back or convert any guest image.
 */
#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "qemu/notify.h"
#include "system/system.h"
#include "ui/console.h"
#include "ui/egl-helpers.h"
#include "backend.h"
#include "live.h"
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#include <pthread.h>

_Static_assert(PERP_BROKER_VERSION==3,"native headless requires immutable host-v3 leases");

typedef struct NativeDisplay {
    DisplayChangeListener listener;
    DisplayGLCtx gl;
} NativeDisplay;
static GList *displays,*contexts;
static EGLContext root_context;
static EGLSurface pbuffer;
static id<MTLDevice> device;
static bool initialized,closed,init_released,handoff_checked;
static uint32_t init_thread;
static unsigned context_creates,context_destroys,unproven_scanouts,unproven_updates;
static EGLint pbuffer_width,pbuffer_height,client_version;

static void fatal_egl(const char *operation)
{
    error_report("perp-native-headless: %s failed (0x%04x)",operation,eglGetError());
    exit(1);
}
static void verify_handoff(void)
{
    if(handoff_checked || pthread_mach_thread_np(pthread_self())==init_thread)return;
    EGLContext previous=eglGetCurrentContext();
    EGLSurface draw=eglGetCurrentSurface(EGL_DRAW),read=eglGetCurrentSurface(EGL_READ);
    if(!eglBindAPI(EGL_OPENGL_ES_API) || !eglMakeCurrent(qemu_egl_display,pbuffer,pbuffer,root_context))
        fatal_egl("thread handoff");
    if(!eglMakeCurrent(qemu_egl_display,draw,read,previous))fatal_egl("thread handoff restore");
    handoff_checked=true;
}
static void refresh(DisplayChangeListener *listener)
{
    if(closed)return;
    verify_handoff();
    graphic_hw_update(listener->con);
}
static void switch_surface(DisplayChangeListener *listener,DisplaySurface *surface)
{
    /* Ordinary RAMFB/2D surfaces remain owned by QEMU and its 2D listeners.
     * Accelerated images travel exclusively through the checked broker/FD path. */
    (void)listener;(void)surface;
}
static void disable(DisplayChangeListener *listener) {(void)listener;}
static void unproven_scanout(DisplayChangeListener *listener,uint32_t backing_id,bool top,
    uint32_t backing_width,uint32_t backing_height,uint32_t x,uint32_t y,uint32_t width,uint32_t height,
    ScanoutTextureNative native)
{
    /* Handle-only scanouts have no immutable lease or producer-ready proof.
     * Never turn this callback into an unfenced capture/readback fallback. */
    (void)listener;(void)backing_id;(void)top;(void)backing_width;(void)backing_height;
    (void)x;(void)y;(void)width;(void)height;(void)native;
    unproven_scanouts++;
}
static void unproven_update(DisplayChangeListener *listener,uint32_t x,uint32_t y,uint32_t width,uint32_t height)
{
    (void)listener;(void)x;(void)y;(void)width;(void)height;unproven_updates++;
}
static const DisplayChangeListenerOps listener_ops={
    .dpy_name="perpendicular-native-metal-headless",
    .dpy_refresh=refresh,.dpy_gfx_switch=switch_surface,
    .dpy_gl_scanout_disable=disable,.dpy_gl_scanout_texture=unproven_scanout,.dpy_gl_update=unproven_update,
};
static bool compatible(DisplayGLCtx *ctx,DisplayChangeListener *listener)
{
    (void)ctx;
    /* Boot/2D listeners can coexist; this does not supply accelerated pixels
     * to VNC. The app receives those independently over native transport. */
    return !listener->ops->dpy_gl_update || listener->ops==&listener_ops;
}
static QEMUGLContext create_context(DisplayGLCtx *ctx,QEMUGLParams *params)
{
    (void)ctx;
    if(closed || params->major_ver>3 || params->major_ver<2)return NULL;
    verify_handoff();
    if(!eglBindAPI(EGL_OPENGL_ES_API))return NULL;
    const EGLint attributes[]={EGL_CONTEXT_CLIENT_VERSION,params->major_ver,
        EGL_CONTEXT_MINOR_VERSION_KHR,params->minor_ver,EGL_NONE};
    EGLContext value=eglCreateContext(qemu_egl_display,qemu_egl_config,root_context,attributes);
    if(value!=EGL_NO_CONTEXT) {contexts=g_list_prepend(contexts,value);context_creates++;}
    return value;
}
static void destroy_context(DisplayGLCtx *ctx,QEMUGLContext value)
{
    (void)ctx;
    if(!closed && g_list_find(contexts,value)) {
        if(!eglDestroyContext(qemu_egl_display,value))fatal_egl("destroy client context");
        contexts=g_list_remove(contexts,value);context_destroys++;
    }
}
static int make_current(DisplayGLCtx *ctx,QEMUGLContext value)
{
    (void)ctx;
    if(closed || (value && !g_list_find(contexts,value)))return -1;
    verify_handoff();
    return eglBindAPI(EGL_OPENGL_ES_API) && eglMakeCurrent(qemu_egl_display,
        value?pbuffer:EGL_NO_SURFACE,value?pbuffer:EGL_NO_SURFACE,value)?0:-1;
}
static const DisplayGLCtxOps context_ops={
    .dpy_gl_ctx_is_compatible_dcl=compatible,.dpy_gl_ctx_create=create_context,
    .dpy_gl_ctx_destroy=destroy_context,.dpy_gl_ctx_make_current=make_current,
};

char *perp_native_headless_stats(void)
{
    bool cocoa=NSApp!=nil;
    return g_strdup_printf("{\"initialized\":%s,\"closed\":%s,\"cocoa_application\":%s,\"cocoa_windows\":%lu,"
        "\"init_context_released\":%s,\"thread_handoff_checked\":%s,\"pbuffer_width\":%d,\"pbuffer_height\":%d,"
        "\"root_ES_version\":%d,\"consoles\":%u,\"client_contexts\":%u,\"context_creates\":%u,\"context_destroys\":%u,"
        "\"unproven_scanouts\":%u,\"unproven_updates\":%u,\"CPU_readback_supported\":false}",
        initialized?"true":"false",closed?"true":"false",cocoa?"true":"false",cocoa?(unsigned long)NSApp.windows.count:0ul,
        init_released?"true":"false",handoff_checked?"true":"false",pbuffer_width,pbuffer_height,client_version,
        g_list_length(displays),g_list_length(contexts),context_creates,context_destroys,unproven_scanouts,unproven_updates);
}
static void shutdown_backend(Notifier *notifier,void *opaque)
{
    (void)notifier;(void)opaque;
    if(!initialized || closed)return;
    closed=true;
    for(GList *item=displays;item;item=item->next) {
        NativeDisplay *display=item->data;
        unregister_displaychangelistener(&display->listener);
        /* The QEMU API cannot unset console->gl. At most 16 closed context
         * tombstones remain until process exit; no dangling console pointers. */
    }
    if(!eglMakeCurrent(qemu_egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT))fatal_egl("shutdown unbind");
    for(GList *item=contexts;item;item=item->next) {
        if(!eglDestroyContext(qemu_egl_display,item->data))fatal_egl("shutdown client context");
        context_destroys++;
    }
    g_list_free(contexts);contexts=NULL;
    if(!eglDestroyContext(qemu_egl_display,root_context) || !eglDestroySurface(qemu_egl_display,pbuffer) ||
       !eglTerminate(qemu_egl_display))fatal_egl("shutdown EGL");
    root_context=EGL_NO_CONTEXT;pbuffer=EGL_NO_SURFACE;
    qemu_egl_display=EGL_NO_DISPLAY;qemu_egl_rn_ctx=EGL_NO_CONTEXT;qemu_egl_angle_native_device=NULL;
    [device release];device=nil;
    char *stats=perp_native_headless_stats();fprintf(stderr,"perp-native-headless: shutdown %s\n",stats);g_free(stats);
}
static Notifier exit_notifier={.notify=shutdown_backend};
static void early_init(DisplayOptions *opts)
{
    const char *broker=getenv("PERP_NEPTUNE_SCANOUT_BROKER"),*direct=getenv("PERP_NATIVE_DISPLAY_DIRECT");
    if((opts->has_gl && opts->gl!=DISPLAY_GL_MODE_ES) || !broker || strcmp(broker,"1") || !direct || strcmp(direct,"1")) {
        error_report("perp-native-headless: requires ES and the checked direct native broker");exit(1);
    }
    init_thread=pthread_mach_thread_np(pthread_self());
    PFNEGLGETPLATFORMDISPLAYEXTPROC platform=(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    const EGLint attributes[]={EGL_PLATFORM_ANGLE_TYPE_ANGLE,EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,EGL_NONE};
    EGLDisplay display=platform?platform(EGL_PLATFORM_ANGLE_ANGLE,NULL,attributes):EGL_NO_DISPLAY;
    const EGLint config[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,
        EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    const EGLint context[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    const EGLint surface[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE};
    EGLint major,minor,count;EGLAttrib egl_device=0,metal_device=0;
    if(display==EGL_NO_DISPLAY || !eglInitialize(display,&major,&minor) || !eglBindAPI(EGL_OPENGL_ES_API) ||
       !eglChooseConfig(display,config,&qemu_egl_config,1,&count) || count!=1)fatal_egl("initialize ANGLE Metal");
    qemu_egl_display=display;qemu_egl_mode=DISPLAY_GL_MODE_ES;
    root_context=eglCreateContext(display,qemu_egl_config,EGL_NO_CONTEXT,context);
    pbuffer=eglCreatePbufferSurface(display,qemu_egl_config,surface);
    if(root_context==EGL_NO_CONTEXT || pbuffer==EGL_NO_SURFACE || !eglMakeCurrent(display,pbuffer,pbuffer,root_context) ||
       !epoxy_has_egl_extension(display,"EGL_EXT_device_query") ||
       !epoxy_has_egl_extension(display,"EGL_ANGLE_metal_texture_client_buffer") ||
       !eglQueryDisplayAttribEXT(display,EGL_DEVICE_EXT,&egl_device) ||
       !eglQueryDeviceAttribEXT((EGLDeviceEXT)egl_device,EGL_METAL_DEVICE_ANGLE,&metal_device) || !metal_device ||
       !eglQuerySurface(display,pbuffer,EGL_WIDTH,&pbuffer_width) || !eglQuerySurface(display,pbuffer,EGL_HEIGHT,&pbuffer_height) ||
       !eglQueryContext(display,root_context,EGL_CONTEXT_CLIENT_VERSION,&client_version))fatal_egl("initialize pbuffer/device");
    device=[(id<MTLDevice>)(void *)metal_device retain];
    qemu_egl_angle_native_device=(void *)device;qemu_egl_rn_ctx=root_context;display_opengl=1;
    /* Darwin transfers the BQL/main loop to another thread after qemu_init. */
    if(!eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT))fatal_egl("release initialization context");
    init_released=eglGetCurrentContext()==EGL_NO_CONTEXT;
    initialized=true;qemu_add_exit_notifier(&exit_notifier);
}
static void init_display(DisplayState *state,DisplayOptions *opts)
{
    (void)state;(void)opts;
    unsigned count=0;
    for(unsigned index=0;;index++) {
        QemuConsole *con=qemu_console_lookup_by_index(index);if(!con)break;
        if(!qemu_console_is_graphic(con))continue;
        if(++count>16) {error_report("perp-native-headless: at most 16 consoles");exit(1);}
        NativeDisplay *display=g_new0(NativeDisplay,1);
        display->listener.con=con;display->listener.ops=&listener_ops;display->gl.ops=&context_ops;
        qemu_console_set_display_gl_ctx(con,&display->gl);displays=g_list_append(displays,display);
        register_displaychangelistener(&display->listener);
    }
}
static QemuDisplay backend={.type=DISPLAY_TYPE_EGL_HEADLESS,.early_init=early_init,.init=init_display};
static void register_backend(void) {qemu_display_register(&backend);}
type_init(register_backend);
