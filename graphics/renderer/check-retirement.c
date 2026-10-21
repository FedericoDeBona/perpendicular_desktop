/* SPDX-License-Identifier: MIT */
#include "context-retirement.h"
#include <assert.h>
#include <signal.h>
#include <stdio.h>
int main(void) {
    pid_t child=fork();assert(child>=0);
    if(!child) {for(;;)pause();}
    bool live_refused=!perp_context_reap(child);
    int killed=kill(child,SIGKILL);
    bool reaped=perp_context_reap(child);
    assert(live_refused && killed==0 && reaped);
    siginfo_t state={0};errno=0;
    assert(waitid(P_PID,(id_t)child,&state,WEXITED|WNOHANG)==-1 && errno==ECHILD);
    puts("Live producer refused; terminated child reaped and confirmed.");
}
