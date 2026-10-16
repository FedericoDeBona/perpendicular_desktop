#!/usr/bin/env python3
"""ASan/UBSan regression for QEMU11's bounded, display-independent release pool."""
import argparse
import importlib.util
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import subprocess
import tempfile

REPO=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('frozen_input',REPO/'experimental/input-backpressure/test-backpressure.py')
frozen=importlib.util.module_from_spec(spec);spec.loader.exec_module(frozen)
SERVICES=r'''
#define KEY_CNT 768
#define OBJECT(p) (p)
typedef struct QemuConsole {int refs,pending,releases;uint64_t identity;bool handler;} QemuConsole;
typedef struct VncState {bool disconnecting,input_blocked;DECLARE_BITMAP(input_keys,KEY_CNT);TAILQ_ENTRY(VncState)next;}VncState;
typedef struct VncDisplay {TAILQ_HEAD(,VncState)clients;struct{QemuConsole*con;}dcl;DECLARE_BITMAP(input_releases,KEY_CNT);QEMUTimer*input_release_timer;struct VncInputCleanup*input_cleanup;}VncDisplay;
static int alive;
static void object_ref(QemuConsole*c){assert(c&&c->refs>0);c->refs++;}
static void object_unref(QemuConsole*c){assert(c&&c->refs>0);if(--c->refs==0){alive--;memset(c,0xa5,sizeof(*c));free(c);}}
static void bitmap_or(uint64_t*d,const uint64_t*a,const uint64_t*b,int n){for(int i=0;i<(n+63)/64;i++)d[i]=a[i]|b[i];}
static uint64_t qemu_input_keyboard_id(QemuConsole*c){return c->handler?c->identity:0;}
static bool qemu_input_keyboard_ready(QemuConsole*c){assert(c&&c->refs>0);return !c->handler||c->pending==0;}
static void qemu_input_event_send_key_linux(QemuConsole*c,unsigned key,bool down){assert(!down&&key<KEY_CNT&&qemu_input_keyboard_ready(c));if(c->handler){c->pending=1;c->releases++;}}
static QemuConsole*console(void){QemuConsole*c=calloc(1,sizeof(*c));c->refs=1;c->identity=1;c->handler=true;c->pending=1;alive++;return c;}
'''
TESTS=r'''
static int slots(void){int n=0;for(int i=0;i<VNC_INPUT_CLEANUP_SLOTS;i++)n+=vnc_input_cleanups[i].con!=NULL;return n;}
int main(void){
    QemuConsole*c=console();
    for(int i=0;i<2000;i++){
        VncDisplay*d=calloc(1,sizeof(*d));d->dcl.con=c;
        assert(vnc_input_reserve_cleanup(d));set_bit(30+i%8,d->input_releases);
        vnc_input_detach_cleanup(d);memset(d,0xa5,sizeof(*d));free(d);tick();
        assert(slots()==1&&timer_count==1&&c->refs==2&&c->pending==1);
    }
    for(int i=0;i<100&&slots();i++){c->pending=0;tick();}
    assert(slots()==0&&timer_count==0&&c->refs==1&&c->releases==8);
    object_unref(c);assert(alive==0);
    puts("2000 repeated display teardowns with suspended polling: one bounded slot/timer, exact merged releases, no display pointer retained PASS");
    QemuConsole*consoles[VNC_INPUT_CLEANUP_SLOTS];
    for(int i=0;i<VNC_INPUT_CLEANUP_SLOTS;i++){
        consoles[i]=console();VncDisplay d={.dcl.con=consoles[i]};
        assert(vnc_input_reserve_cleanup(&d));set_bit(30,d.input_releases);vnc_input_detach_cleanup(&d);
    }
    assert(slots()==VNC_INPUT_CLEANUP_SLOTS&&timer_count==VNC_INPUT_CLEANUP_SLOTS);
    QemuConsole*extra=console();VncDisplay rejected={.dcl.con=extra};
    assert(!vnc_input_reserve_cleanup(&rejected)&&extra->refs==1&&!rejected.input_cleanup);
    object_unref(extra);
    for(int i=0;i<VNC_INPUT_CLEANUP_SLOTS;i++){
        // The device goes away and its external console owner is dropped.
        // The pending callback retains the only valid reference until drain.
        consoles[i]->handler=false;object_unref(consoles[i]);
    }
    for(int i=0;i<10&&slots();i++)tick();
    assert(slots()==0&&timer_count==0&&alive==0);
    puts("32-slot bound rejects new ownership; device removal + final console refs + repeated timer teardown free safely PASS");
    c=console();VncDisplay old={.dcl.con=c};assert(vnc_input_reserve_cleanup(&old));set_bit(30,old.input_releases);vnc_input_detach_cleanup(&old);
    c->identity=2;tick();
    fprintf(stderr,"replacement_cleanup_slots=%d replacement_pending=%d emitted_releases=%d\n",slots(),c->pending,c->releases);
    assert(slots()==0&&c->pending==1&&c->releases==0&&c->refs==1);object_unref(c);assert(alive==0&&timer_count==0);
    puts("Removed handler identity does not deliver old releases to replacement keyboard PASS");
    c=console();c->pending=0;VncDisplay active={.dcl.con=c};assert(vnc_input_reserve_cleanup(&active));
    assert(vnc_input_display_idle(&active));c->identity=2;
    assert(!vnc_input_display_idle(&active));vnc_input_detach_cleanup(&active);
    assert(slots()==0&&timer_count==0&&c->releases==0);object_unref(c);assert(alive==0);
    puts("Changed handler identity prevents console rebind from lifting old logical keys into replacement backend PASS");
}
'''


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,default=REPO/'.tools/runtime-display/source');args=p.parse_args()
    vnc=(args.source/'ui/vnc.c').read_text()
    start=vnc.index('#define VNC_INPUT_CLEANUP_SLOTS');end=vnc.index('static void vnc_input_cleanup_drain',start)
    bodies=[frozen.function(vnc,name) for name in ('vnc_input_cleanup_drain','vnc_input_reserve_cleanup','vnc_input_detach_cleanup','vnc_input_display_idle')]
    source=frozen.PRELUDE+SERVICES+vnc[start:end]+'\n'.join(bodies)+TESTS
    with tempfile.TemporaryDirectory(prefix='cleanup-',dir=REPO/'.tools/runtime-display') as directory:
        work=Path(directory);(work/'check.c').write_text(source)
        subprocess.run(['clang','-std=gnu11','-O1','-g','-Wall','-Wextra','-Werror','-Wno-unused-function','-Wno-unused-parameter','-Wno-unused-variable','-Wno-sign-compare','-fsanitize=address,undefined','-fno-omit-frame-pointer',str(work/'check.c'),'-o',str(work/'check')],check=True)
        subprocess.run([str(work/'check')],check=True,timeout=20)
        guard = """    if (cleanup->keyboard_id != qemu_input_keyboard_id(cleanup->con)) {
        bitmap_zero(cleanup->keys, KEY_CNT);
    }
"""
        assert guard in source
        (work/'negative.c').write_text(source.replace(guard, "", 1))
        subprocess.run(['clang','-std=gnu11','-O1','-g','-Wno-unused-variable','-fsanitize=address,undefined',str(work/'negative.c'),'-o',str(work/'negative')],check=True)
        control=subprocess.run([str(work/'negative')],capture_output=True,text=True,timeout=20)
        assert control.returncode != 0 and 'replacement_cleanup_slots=1' in control.stderr, control.stderr
        print('Causal negative: omitting only handler identity leaves old cleanup aimed at replacement device FAIL as expected')


if __name__=='__main__':main()
