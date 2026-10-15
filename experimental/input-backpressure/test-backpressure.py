#!/usr/bin/env python3
"""Compile actual QEMU function bodies with deterministic timers/private sockets.

No VM, hypervisor, window, guest, production binary or active source is touched.
The hardware key FIFO/conversion/poll and VNC admission/parser/ownership functions
are extracted verbatim, not reimplemented in Python. Surrounding QEMU services
are narrowly stubbed; full object compilation is a separate check.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]


def function(source, name):
    match = re.search(r"^(?:static\s+)?[\w *]+\b" + re.escape(name) + r"\([^;]*?\)\n\{", source, re.M)
    if not match:
        raise ValueError("Function not found: " + name)
    start = source.index("{", match.start())
    # Mask comments/strings while preserving offsets for brace matching.
    tail = source[start:]
    masked = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                    lambda m: " " * len(m[0]), tail, flags=re.S)
    depth = 0
    for index, character in enumerate(masked):
        depth += (character == "{") - (character == "}")
        if depth == 0:
            return source[match.start():start + index + 1]
    raise ValueError("Unterminated function: " + name)


PRELUDE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/queue.h>
#include <sys/socket.h>
#include <unistd.h>
#define MIN(a,b) ((a)<(b)?(a):(b))
#define QTAILQ_HEAD TAILQ_HEAD
#define QTAILQ_ENTRY TAILQ_ENTRY
#define QTAILQ_FOREACH TAILQ_FOREACH
#define QTAILQ_EMPTY TAILQ_EMPTY
#define DECLARE_BITMAP(name,n) uint64_t name[((n)+63)/64]
static bool test_bit(int n, const uint64_t *p) { return (p[n/64]>>(n%64))&1; }
static void set_bit(int n, uint64_t *p) { p[n/64]|=UINT64_C(1)<<(n%64); }
static void clear_bit(int n, uint64_t *p) { p[n/64]&=~(UINT64_C(1)<<(n%64)); }
static void bitmap_zero(uint64_t *p,int n) { memset(p,0,((n+63)/64)*8); }
static bool bitmap_empty(const uint64_t *p,int n) { for(int i=0;i<n;i++) if(test_bit(i,p))return false;return true; }
typedef int QKeyCode;
enum { Q_KEY_CODE_PAUSE=200,Q_KEY_CODE__MAX=256,KEY_VALUE_KIND_NUMBER,KEY_VALUE_KIND_QCODE };
enum { SCANCODE_GREY=0x80,SCANCODE_EMUL0=0xe0,SCANCODE_UP=0x80 };
enum { HID_USAGE_ERROR_ROLLOVER=1 };
typedef struct { int type; union { struct {int data;} number,qcode; } u; } KeyValue;
static const int qemu_input_map_qcode_to_qnum_len=256;
static const int qemu_input_map_qcode_to_qnum[256]={[Q_KEY_CODE_PAUSE]=0x45};
typedef struct {KeyValue *key;bool down;} InputKeyEvent;
typedef struct {union {struct {InputKeyEvent *data;} key;} u;} InputEvent;
typedef struct QemuInputHandlerState QemuInputHandlerState;
typedef struct VMStateDescription VMStateDescription;
typedef struct HIDState HIDState;
typedef HIDState DeviceState;
typedef struct QEMUTimer {void (*cb)(void*);void *opaque;bool active;int64_t deadline;} QEMUTimer;
static QEMUTimer *timers[128];static int64_t clock_ms;static int timer_count,trace_full;
static QEMUTimer *timer_new_ms(int clock,void (*cb)(void*),void *opaque) {
    (void)clock;QEMUTimer*t=calloc(1,sizeof(*t));assert(t);t->cb=cb;t->opaque=opaque;
    for(int i=0;i<128;i++)if(!timers[i]){timers[i]=t;timer_count++;return t;}abort();
}
static void timer_mod(QEMUTimer*t,int64_t deadline){assert(t);t->active=true;t->deadline=deadline;}
static void timer_free(QEMUTimer*t){if(!t)return;for(int i=0;i<128;i++)if(timers[i]==t){timers[i]=NULL;timer_count--;free(t);return;}abort();}
static int64_t qemu_clock_get_ms(int clock){(void)clock;return clock_ms;}
static void tick(void){clock_ms+=10;for(int i=0;i<128;i++){QEMUTimer*t=timers[i];if(t&&t->active&&t->deadline<=clock_ms){t->active=false;void(*cb)(void*)=t->cb;void*o=t->opaque;cb(o);}}}
static bool active_timers(void){for(int i=0;i<128;i++)if(timers[i]&&timers[i]->active)return true;return false;}
#define QEMU_CLOCK_REALTIME 0
static void trace_hid_kbd_queue_full(void){trace_full++;}
static void trace_hid_kbd_queue_empty(void){}
'''

SERVICES = r'''
typedef struct QemuConsole {HIDState *hid;} QemuConsole;
typedef bool (*QemuInputKeyboardReady)(DeviceState*);
struct QemuInputHandlerState {DeviceState *dev;QemuInputKeyboardReady keyboard_ready;};
struct QueueItem {TAILQ_ENTRY(QueueItem) next;};
static TAILQ_HEAD(,QueueItem) kbd_queue=TAILQ_HEAD_INITIALIZER(kbd_queue);
static QemuInputHandlerState selected_handler;
#define INPUT_EVENT_MASK_KEY 1
static QemuInputHandlerState *qemu_input_find_handler(int mask,QemuConsole *con){(void)mask;selected_handler.dev=con->hid;return &selected_handler;}
typedef struct QKbdState {QemuConsole *con;bool held[256];} QKbdState;
static int delivery_count;
static void qkbd_state_key_event(QKbdState*k,int code,bool down){
    if(!down&&!k->held[code])return;k->held[code]=down;delivery_count++;
    KeyValue key={.type=code==Q_KEY_CODE_PAUSE?KEY_VALUE_KIND_QCODE:KEY_VALUE_KIND_NUMBER};
    key.u.number.data=code;InputKeyEvent ik={&key,down};InputEvent event={.u.key.data=&ik};
    hid_keyboard_event((DeviceState*)k->con->hid,k->con,&event);
}
typedef int GIOCondition;typedef int gboolean;typedef unsigned guint;
enum{G_IO_IN=1,G_IO_OUT=2,G_IO_HUP=4,G_IO_ERR=8,TRUE=1,VNC_SHARE_MODE_DISCONNECTED=4};
#define G_GNUC_UNUSED __attribute__((unused))
#define VNC_MAGIC UINT64_C(0x05b3f069b3d204bb)
typedef struct QIOChannel {int fd;} QIOChannel;
typedef struct Buffer {uint8_t *buffer;size_t offset;} Buffer;
typedef struct VncState VncState;typedef struct VncDisplay VncDisplay;
struct VncDisplay {TAILQ_HEAD(,VncState) clients;struct{QemuConsole *con;}dcl;QKbdState*kbd;DECLARE_BITMAP(input_releases,256);QEMUTimer*input_release_timer;};
struct VncState {uint64_t magic;VncDisplay*vd;QIOChannel*ioc;guint ioc_tag;bool disconnecting,input_blocked,input_switch_pending;unsigned input_switch_index;QEMUTimer*input_retry_timer;DECLARE_BITMAP(input_keys,256);Buffer input,output;int(*read_handler)(VncState*,uint8_t*,size_t);size_t read_handler_expect;TAILQ_ENTRY(VncState)next;int watch_flags;};
static QemuConsole*consoles[4];static int switches;
static QemuConsole*qemu_console_lookup_by_index(unsigned index){return index<4?consoles[index]:NULL;}
static void unregister_displaychangelistener(void*p){(void)p;}
static void register_displaychangelistener(void*p){(void)p;}
static void qkbd_state_switch_console(QKbdState*k,QemuConsole*c){for(int i=0;i<256;i++)assert(!k->held[i]);k->con=c;switches++;}
static void vnc_input_retry(void*);
static void vnc_lock_output(VncState*v){(void)v;}
static void vnc_unlock_output(VncState*v){(void)v;}
static void g_source_remove(guint tag){(void)tag;}
static void qio_channel_close(QIOChannel*c,void*e){(void)e;if(c->fd>=0){shutdown(c->fd,SHUT_RDWR);close(c->fd);c->fd=-1;}}
static void vnc_set_share_mode(VncState*v,int mode){(void)v;(void)mode;}
static void trace_vnc_client_disconnect_start(VncState*v,QIOChannel*c){(void)v;(void)c;}
static gboolean vnc_client_io(QIOChannel*,GIOCondition,void*);
static guint qio_channel_add_watch(QIOChannel*c,int flags,gboolean(*cb)(QIOChannel*,int,void*),VncState*v,void*d){(void)c;(void)cb;(void)d;v->watch_flags=flags;return 1;}
static bool qemu_console_is_graphic(QemuConsole*c){(void)c;return true;}
static void buffer_advance(Buffer*b,size_t n){assert(n<=b->offset);memmove(b->buffer,b->buffer+n,b->offset-n);b->offset-=n;}
static void vnc_disconnect_finish(VncState*v){(void)v;abort();}
static void vnc_client_error(VncState*v);
static void error_report(const char*format,...){(void)format;}
static int vnc_client_read(VncState*v){(void)v;abort();}
static void vnc_client_write(VncState*v){assert(v->ioc->fd>=0);ssize_t n=write(v->ioc->fd,v->output.buffer,v->output.offset);assert(n==(ssize_t)v->output.offset);v->output.offset=0;}
'''

TESTS = r'''
static void vnc_client_error(VncState*v){vnc_disconnect_start(v);}
static int blocked_advance;static bool bypass_gate;
static int packet_handler(VncState*v,uint8_t*p,size_t n){
    assert(n==8&&p[0]==4);
    if(!bypass_gate&&!vnc_input_admit(v)){blocked_advance++;return -2;}
    int code=p[7];bool down=p[1]!=0;
    if(vnc_input_track_key(v,code,down))qkbd_state_key_event(v->vd->kbd,code,down);
    return 0;
}
static void wake(HIDState*h){(void)h;}
static void init_hid(HIDState*h){memset(h,0,sizeof(*h));h->kind=HID_KEYBOARD;h->event=wake;}
static void init_display(VncDisplay*d,QemuConsole*c,QKbdState*k){memset(d,0,sizeof(*d));TAILQ_INIT(&d->clients);d->dcl.con=c;d->kbd=k;}
static int init_client(VncState*v,VncDisplay*d){
    memset(v,0,sizeof(*v));v->magic=VNC_MAGIC;v->vd=d;v->read_handler=packet_handler;v->read_handler_expect=8;
    v->input.buffer=calloc(1,4096+12);v->ioc=calloc(1,sizeof(*v->ioc));int fds[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,fds)==0);v->ioc->fd=fds[0];TAILQ_INSERT_TAIL(&d->clients,v,next);return fds[1];
}
static void enqueue_packet(VncState*v,int code,bool down){assert(v->input.offset+8<=4096+12);uint8_t p[8]={4,down,0,0,0,0,0,code};memcpy(v->input.buffer+v->input.offset,p,8);v->input.offset+=8;}
static void send_real_client(VncState*v,int peer,int code,bool down){
    uint8_t p[8]={4,down,0,0,0,0,0,code};assert(write(peer,p,8)==8);uint8_t received[8];assert(read(v->ioc->fd,received,8)==8);assert(memcmp(p,received,8)==0);enqueue_packet(v,code,down);vnc_client_process_input(v);
}
static void destroy_client(VncState*v,int peer){
    if(!v->disconnecting)vnc_disconnect_start(v);TAILQ_REMOVE(&v->vd->clients,v,next);free(v->input.buffer);free(v->ioc);close(peer);memset(v,0xa5,sizeof(*v));
}
static void poll_hid(HIDState*h){uint8_t report[8];assert(hid_keyboard_poll(h,report,8)==8);}
static void drain(HIDState*h,VncState*v){
    for(int i=0;i<10000;i++){if(h->n)poll_hid(h);tick();if(!h->n&&(!v||!v->input.offset)&&!active_timers())return;}
    assert(!"Input/timer did not drain");
}
static void clear_host_stall(void){
    HIDState h;init_hid(&h);QemuConsole con={&h};QKbdState k={.con=&con};VncDisplay d;init_display(&d,&con,&k);VncState v;int peer=init_client(&v,&d);
    int keys[]={0x2a,0x2e,0x2e,0x2a,0x26,0x26,0x12,0x12,0x1e,0x1e,0x13,0x13,0x35,0x35,0x2a,0x23,0x23,0x2a,0x18,0x18,0x1f,0x1f,0x14,0x14,0x39,0x39};
    bool down[]={1,1,0,0,1,0,1,0,1,0,1,0,1,0,1,1,0,0,1,0,1,0,1,0,1,0};
    for(size_t i=0;i<sizeof(keys)/sizeof(*keys);i++)enqueue_packet(&v,keys[i],down[i]);
    vnc_client_process_input(&v);
    fprintf(stderr,"suspended_poll drops=%d admitted=%d retained_bytes=%zu\n",trace_full,delivery_count,v.input.offset);
    assert(trace_full==0);assert(delivery_count==1&&h.n==1&&v.input.offset==25*8);
    for(int i=0;i<100;i++)tick();assert(delivery_count==1&&v.input.offset==25*8);
    assert((v.watch_flags&G_IO_IN)==0&&(v.watch_flags&G_IO_HUP)&&(v.watch_flags&G_IO_ERR));
    // Frame output continues while ingress is suspended.
    v.output.buffer=(uint8_t*)"frame";v.output.offset=5;
    assert(vnc_client_io_flags(&v,true)&G_IO_OUT);vnc_client_io(v.ioc,G_IO_OUT,&v);char output[5];assert(read(peer,output,5)==5&&memcmp(output,"frame",5)==0);
    drain(&h,&v);assert(delivery_count==26&&trace_full==0&&h.kbd.keys==0&&h.kbd.modifiers==0);
    assert(v.input.offset==0&&!v.input_blocked&&(v.watch_flags&G_IO_IN));
    destroy_client(&v,peer);assert(timer_count==0);puts("real HID FIFO + VNC parser: suspended/resumed guest poll, exact 26 transitions, output preserved PASS");
}
static void prefixes_and_global_delay(void){
    HIDState h;init_hid(&h);QemuConsole con={&h};QKbdState k={.con=&con};VncDisplay d;init_display(&d,&con,&k);VncState v;int peer=init_client(&v,&d);
    // Another console's global delayed input blocks admission without mutation.
    struct QueueItem other;TAILQ_INSERT_HEAD(&kbd_queue,&other,next);enqueue_packet(&v,0xb8,true);vnc_client_process_input(&v);assert(h.n==0&&v.input.offset==8);
    TAILQ_REMOVE(&kbd_queue,&other,next);tick();assert(h.n==2&&v.input.offset==0);
    enqueue_packet(&v,0xb8,false);vnc_client_process_input(&v);poll_hid(&h);tick();assert(h.n==1&&v.input.offset==8);poll_hid(&h);assert(h.kbd.modifiers==(1<<6));tick();assert(h.n==2&&v.input.offset==0);drain(&h,&v);assert(h.kbd.modifiers==0);
    enqueue_packet(&v,Q_KEY_CODE_PAUSE,true);enqueue_packet(&v,Q_KEY_CODE_PAUSE,false);vnc_client_process_input(&v);assert(h.n==3&&v.input.offset==8);
    poll_hid(&h);tick();assert(h.n==2&&v.input.offset==8);poll_hid(&h);tick();assert(h.n==1&&v.input.offset==8);poll_hid(&h);tick();assert(h.n==3&&v.input.offset==0);drain(&h,&v);assert(h.kbd.keys==0&&h.kbd.modifiers==0&&trace_full==0);
    destroy_client(&v,peer);assert(timer_count==0);puts("real E0/E1 conversion: full prefixes retained, modifier release ordered, independent delayed queue preserved PASS");
}
static void explicit_bound(void){
    HIDState h;init_hid(&h);QemuConsole con={&h};QKbdState k={.con=&con};VncDisplay d;init_display(&d,&con,&k);VncState v;int peer=init_client(&v,&d);
    v.input.offset=4096+13;assert(!vnc_input_admit(&v));assert(v.disconnecting&&!v.input_retry_timer);destroy_client(&v,peer);assert(timer_count==0);puts("explicit retained-input bound closes only the offending connection PASS");
}
static void two_clients_disconnect(void){
    HIDState h,unrelated;init_hid(&h);init_hid(&unrelated);QemuConsole con={&h},othercon={&unrelated};QKbdState k={.con=&con},otherk={.con=&othercon};VncDisplay d;init_display(&d,&con,&k);VncState a,b;int ap=init_client(&a,&d),bp=init_client(&b,&d);
    send_real_client(&a,ap,0x1e,true);poll_hid(&h);send_real_client(&b,bp,0x30,true);poll_hid(&h);assert(h.kbd.keys==2);
    // A retained release must be replaced by A's owned cleanup, not B's key.
    send_real_client(&a,ap,0x23,true);send_real_client(&a,ap,0x1e,false);assert(a.input_blocked&&a.input.offset==8);
    qkbd_state_key_event(&otherk,0x2e,true);assert(unrelated.n==1);
    close(ap);ap=-1;vnc_client_io(a.ioc,G_IO_HUP,&a);assert(a.disconnecting&&!a.input_retry_timer);
    TAILQ_REMOVE(&d.clients,&a,next);free(a.input.buffer);free(a.ioc);memset(&a,0xa5,sizeof(a));
    poll_hid(&h);send_real_client(&b,bp,0x30,true);assert(b.input_blocked&&b.input.offset==8); // Owned cleanup has priority over surviving input.
    drain(&h,NULL);assert(h.kbd.keys==1&&h.kbd.key[0]==0x05);assert(test_bit(0x30,b.input_keys));assert(unrelated.n==1&&otherk.held[0x2e]);
    // Reuse the connection storage: no stale retry callback can target it.
    ap=init_client(&a,&d);send_real_client(&a,ap,0x30,true);poll_hid(&h);send_real_client(&a,ap,0x30,false);assert(h.n==0&&k.held[0x30]);destroy_client(&a,ap);
    destroy_client(&b,bp);drain(&h,NULL);assert(h.kbd.keys==0&&h.kbd.modifiers==0&&timer_count==0&&trace_full==0);assert(unrelated.n==1);puts("two real Unix clients: retained-release HUP cleanup, shared ownership, storage reuse and unrelated device isolation PASS");
}
static void deferred_console_switch(void){
    HIDState h,other;init_hid(&h);init_hid(&other);QemuConsole con={&h},target={&other};consoles[1]=&target;QKbdState k={.con=&con};VncDisplay d;init_display(&d,&con,&k);VncState a,b;int ap=init_client(&a,&d),bp=init_client(&b,&d);
    send_real_client(&a,ap,0x1d,true);poll_hid(&h);vnc_input_queue_switch(&a,1);for(int i=0;i<20;i++)tick();assert(switches==0&&a.input_switch_pending&&d.dcl.con==&con);
    send_real_client(&b,bp,0x30,true);poll_hid(&h);send_real_client(&a,ap,0x1d,false);poll_hid(&h);
    for(int i=0;i<20;i++)tick();assert(switches==0&&!vnc_input_display_idle(&d)); // B still owns its key.
    send_real_client(&b,bp,0x30,false);assert(!vnc_input_display_idle(&d));poll_hid(&h);tick();assert(switches==1&&!a.input_switch_pending&&d.dcl.con==&target&&k.con==&target);
    vnc_input_queue_switch(&a,2);consoles[2]=NULL;tick();assert(switches==1&&!a.input_switch_pending); // Removed target cannot be dereferenced.
    vnc_input_queue_switch(&a,0);destroy_client(&a,ap);tick();assert(switches==1&&d.dcl.con==&target);destroy_client(&b,bp);assert(timer_count==0);
    puts("console switch deferred until every owner/FIFO drains; removed target and disconnect cancel safely PASS");
}
int main(int argc,char**argv){
    bypass_gate=argc>1&&strcmp(argv[1],"--disable-admission")==0;selected_handler.keyboard_ready=hid_keyboard_ready;
    clear_host_stall();prefixes_and_global_delay();explicit_bound();two_clients_disconnect();deferred_console_switch();assert(timer_count==0);return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--overlay", type=Path, default=REPO / ".tools/input-backpressure/source")
    parser.add_argument("--original", type=Path, default=REPO / ".tools/graphics-experiment/src/qemu")
    options = parser.parse_args()
    hid = (options.overlay / "hw/input/hid.c").read_text()
    vnc = (options.overlay / "ui/vnc.c").read_text()
    input_source = (options.overlay / "ui/input.c").read_text()
    keymap = (options.original / "ui/input-keymap.c").read_text()
    header = (options.original / "include/hw/input/hid.h").read_text().replace('#include "ui/input.h"', "")
    array = re.search(r"static const uint8_t hid_usage_keys\[0x100\] = \{.*?\n\};", hid, re.S)[0]
    production = [function(keymap, name) for name in ("qemu_input_key_value_to_number", "qemu_input_key_value_to_scancode")]
    production += [array, "typedef struct QemuConsole QemuConsole;"]
    production += [function(hid, name) for name in ("hid_keyboard_event", "hid_keyboard_process_keycode", "hid_keyboard_poll", "hid_keyboard_ready")]
    helpers = [function(input_source, "qemu_input_keyboard_ready")]
    helpers += [function(vnc, name) for name in ("vnc_input_display_idle", "vnc_input_schedule_retry", "vnc_input_queue_switch", "vnc_input_try_switch", "vnc_input_key_owned", "vnc_input_track_key", "vnc_input_release_pending", "vnc_input_disconnect", "vnc_client_io_flags", "vnc_disconnect_start", "vnc_client_process_input", "vnc_input_update_watch", "vnc_input_retry", "vnc_input_admit")]
    # Public function declaration differs from the test's private declaration.
    io = function(vnc, "vnc_client_io").replace("gboolean vnc_client_io", "static gboolean vnc_client_io", 1)
    source = PRELUDE + "\n" + header + "\n" + "\n".join(production) + "\n" + SERVICES + "\n" + "\n".join(helpers) + "\n" + io + "\n" + TESTS
    with tempfile.TemporaryDirectory(prefix="prp-input-source-", dir="/tmp") as directory:
        path = Path(directory)
        (path / "check.c").write_text(source)
        command = ["clang", "-std=gnu11", "-g", "-O1", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-Wno-unused-parameter", "-Wno-sign-compare", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", str(path / "check.c"), "-o", str(path / "check")]
        subprocess.run(command, check=True)
        subprocess.run([str(path / "check")], check=True, timeout=15)
        baseline = subprocess.run([str(path / "check"), "--disable-admission"], capture_output=True, text=True, timeout=15)
        assert baseline.returncode != 0 and "suspended_poll drops=10" in baseline.stderr, baseline.stderr
        print("Causal negative: bypassing only VNC admission drops exactly 10 of the 26 actual HID transitions PASS")


if __name__ == "__main__":
    main()
