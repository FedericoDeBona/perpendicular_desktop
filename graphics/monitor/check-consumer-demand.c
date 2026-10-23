/* SPDX-License-Identifier: MIT
 * Includes the actual patched QEMU tick/flush, with inert boundary functions.
 * Checks coalescing through a closed/full consumer and its final static update.
 * No VM, GPU, transport completion or rendering is claimed by this check.
 */
#ifdef NDEBUG
#error "Active assertions are required."
#endif
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
typedef struct NativeRead NativeRead;
typedef int QemuConsole;
typedef struct {int memory_fd;} PerpLiveLease;
static bool capacity,refresh,last_if_empty,hold_read;
static unsigned requests,pumps,retirements;
static uint64_t blocked_flushes;
static int timer_storage,*timer=&timer_storage;
#define QEMU_CLOCK_REALTIME 0
static bool perp_native_display_needs_refresh(void){return refresh;}
static bool perp_native_display_can_capture(void){return capacity;}
static bool perp_live_scanout_needs_pump(void){return true;}
static void perp_live_scanout_pump(void){pumps++;}
static bool perp_live_scanout_take(uint32_t id,PerpLiveLease *lease){(void)id;(void)lease;return false;}
static void perp_live_scanout_done(PerpLiveLease *lease,bool success){(void)lease;(void)success;retirements++;}
static bool publish(PerpLiveLease *lease){(void)lease;return false;}
static uint64_t qemu_clock_get_ms(int clock){(void)clock;return 0;}
static void timer_mod(int *value,uint64_t time){(void)value;(void)time;}
static void perp_live_scanout_refresh(uint32_t id,bool if_empty);
#include "qemu-consumer-demand.inc"
static void perp_live_scanout_refresh(uint32_t id,bool if_empty)
{
    assert(id==display.resource);requests++;last_if_empty=if_empty;
}
int main(void)
{
    setenv("PERP_NEPTUNE_SCANOUT_BROKER","1",1);
    int owner;display.owner=&owner;display.resource=7;
    NativeRead *held=(NativeRead *)(uintptr_t)1;display.current=held;
    assert(perp_live_qemu_flush(&owner,0,7));
    assert(!requests && pumps==1 && display.current==held && !retirements);
    tick(NULL);tick(NULL);assert(!requests && pumps==3);
    // Capacity may mean no client or both slots held. In either case the
    // final static update must survive until a slot becomes available.
    capacity=true;display.current=NULL;tick(NULL);
    assert(requests==1 && !last_if_empty);tick(NULL);assert(requests==1);
    capacity=false;
    assert(perp_live_qemu_flush(&owner,0,7));
    assert(perp_live_qemu_flush(&owner,0,7));assert(requests==1);
    capacity=true;tick(NULL);assert(requests==2 && !last_if_empty);
    tick(NULL);assert(requests==2);
    // A replacement consumer also gets one frame with an idle source.
    refresh=true;tick(NULL);assert(requests==3 && last_if_empty);
    tick(NULL);assert(requests==3);
    capacity=false;refresh=false;tick(NULL);
    display.resource=8;assert(perp_live_qemu_flush(&owner,0,8));assert(requests==3);
    capacity=true;refresh=true;tick(NULL);assert(requests==4 && !last_if_empty);
    tick(NULL);assert(requests==4 && !display.failed && !retirements);
    puts("No scanout requests while closed/full; final updates coalesce and resume once; pump and held leases survive.");
}
