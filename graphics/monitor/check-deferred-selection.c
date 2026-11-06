/* Executes the actual patched QEMU functions, without a GPU or VM. */
#ifdef NDEBUG
#error Active assertions required
#endif
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct NativeRead {int unused;} NativeRead;
typedef int QemuConsole;
typedef struct {int memory_fd;} PerpLiveLease;
typedef int QEMUTimer;
static int timer_value, *timer;
static bool known,capacity,refresh,hold_read,allow_publish;
static uint32_t known_id,selected;
static uint64_t clock_ms,generations,selection_waits,selection_resumed,selection_timeouts,blocked_flushes;
static unsigned takes,pumps,resets,refreshes;
#define QEMU_CLOCK_REALTIME 0
static uint64_t qemu_clock_get_ms(int clock){(void)clock;return clock_ms;}
static void timer_mod(int *value,uint64_t time){(void)value;(void)time;}
static void timer_del(int *value){(void)value;}
static QEMUTimer *timer_new_ms(int clock,void(*callback)(void*),void *arg){(void)clock;(void)callback;(void)arg;return &timer_value;}
static void qemu_console_resize(QemuConsole *c,uint32_t w,uint32_t h){(void)c;(void)w;(void)h;}
static bool perp_native_display_needs_refresh(void){return refresh;}
static bool perp_native_display_can_capture(void){return capacity;}
static bool perp_live_scanout_needs_pump(void){return false;}
static void perp_live_scanout_pump(void){pumps++;}
static bool perp_live_scanout_select(uint32_t id){if(!id){selected=0;return true;}if(!known || id!=known_id)return false;selected=id;return true;}
static bool perp_live_scanout_take(uint32_t id,PerpLiveLease *lease){(void)lease;assert(known && selected==id && id==known_id);takes++;return false;}
static void perp_live_scanout_done(PerpLiveLease *lease,bool success){(void)lease;(void)success;abort();}
static void perp_live_scanout_refresh(uint32_t id,bool if_empty){(void)if_empty;assert(known && selected==id && id==known_id);refreshes++;}
static void perp_native_display_reset(void){resets++;}
static bool publish(PerpLiveLease *lease){(void)lease;return allow_publish;}
#include "qemu-deferred-selection.inc"
int main(void){
    setenv("PERP_NEPTUNE_SCANOUT_BROKER","1",1);
    int owner,other;QemuConsole console;
    assert(perp_live_qemu_select(&owner,&console,0,7,1920,1280,0,0,1920,1280));
    assert(display.selection_pending && !display.failed && selected==0 && selection_waits==1);
    capacity=true;refresh=true;tick(NULL);
    assert(!takes && !refreshes && display.selection_pending);
    assert(perp_live_qemu_flush(&owner,0,7));assert(!display.failed && !takes);
    /* Creation becomes visible on a later pump: only normal broker admission
     * may resume this exact selection, then refresh the final static image. */
    known=true;known_id=7;clock_ms=24;tick(NULL);
    assert(!display.selection_pending && !display.failed && selection_resumed==1 && takes==1 && refreshes==1);
    known=false;clock_ms=30;
    assert(perp_live_qemu_select(&owner,&console,0,8,1440,1676,0,0,1440,1676));
    assert(display.selection_pending && selected==0);
    /* A newer intent supersedes the pending ID; registration of its old ID
     * cannot satisfy the replacement. No old lease is released by selection. */
    clock_ms=40;assert(perp_live_qemu_select(&owner,&console,0,9,2880,1800,0,0,2880,1800));
    known=true;known_id=8;tick(NULL);assert(display.selection_pending && selected==0 && takes==1);
    clock_ms=3040;tick(NULL);assert(display.failed && !display.selection_pending && selection_timeouts==1 && takes==1);
    known_id=9;tick(NULL);assert(display.failed && takes==1);
    perp_live_qemu_reset(&owner);assert(!display.failed && !display.selection_pending && !display.resource && selected==0 && resets==1);
    /* A different owner/output remains an immediate hard rejection. */
    assert(perp_live_qemu_select(&owner,&console,0,9,2880,1800,0,0,2880,1800));
    assert(perp_live_qemu_select(&other,&console,0,9,2880,1800,0,0,2880,1800));assert(display.failed);
    perp_live_qemu_reset(&owner);
    assert(perp_live_qemu_select(&owner,&console,1,9,2880,1800,0,0,2880,1800));assert(display.failed);
    assert(pumps>0);
    puts("Actual scanout functions: late registration resumes; unknown/replaced resources never captured; timeout and owner/output rejection preserved.");
}
