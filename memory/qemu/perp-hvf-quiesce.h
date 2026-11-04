/* SPDX-License-Identifier: GPL-2.0-only
 * Main-loop RAM callbacks must not block in pause_all_vcpus(): a vCPU can
 * be waiting for a GPU reset BH on that same main loop. Request the stop,
 * yield, and touch mappings only after every CPU acknowledged it.
 */
#ifndef PERP_HVF_QUIESCE_H
#define PERP_HVF_QUIESCE_H

#include "hw/core/cpu.h"
#include "qemu/timer.h"
#include "system/cpus.h"

static bool perp_hvf_quiesce(QEMUTimer *retry, bool *requested,
                             uint64_t *waits)
{
    CPUState *cpu;
    bool ready = true;

    assert(!qemu_in_vcpu_thread());
    timer_del(retry);
    qemu_clock_enable(QEMU_CLOCK_VIRTUAL, false);
    *requested = true;
    CPU_FOREACH(cpu) {
        if (!cpu->stopped) {
            ready = false;
            cpu_pause(cpu);
        }
    }
    if (!ready) {
        ++*waits;
        timer_mod(retry, qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + 2);
    }
    return ready;
}

static void perp_hvf_quiesce_cancel(QEMUTimer *retry, bool *requested)
{
    if (retry) {
        timer_del(retry);
    }
    if (*requested) {
        *requested = false;
        /* Does not resume a VM whose runstate changed to stopped. Other RAM
         * callbacks always recheck all CPU ACKs before touching mappings.
         */
        resume_all_vcpus();
    }
}

#endif
