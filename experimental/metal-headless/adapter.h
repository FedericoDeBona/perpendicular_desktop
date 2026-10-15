/* SPDX-License-Identifier: MIT */
#ifndef PERP_METAL_HEADLESS_ADAPTER_H
#define PERP_METAL_HEADLESS_ADAPTER_H
#include "ui/console.h"

typedef enum PerpMetalCompletion {
    PERP_METAL_READ_COMPLETE,
    PERP_METAL_SUPERSEDED,
    PERP_METAL_INVALID,
    PERP_METAL_TIMEOUT,
    PERP_METAL_SHUTDOWN,
} PerpMetalCompletion;

/* Main/BQL thread only. The producer grants an immutable read lease on texture
 * until done() runs exactly once. ready_event is an MTLSharedEvent signaled by
 * the producer after all writes. Retention alone does NOT grant that lease.
 * Each refresh needs a fresh lease; upstream handle-only scanouts fail closed.
 * done() runs only after GPU read completion, or with a cancellation status
 * when no consumer GPU read was issued. It must not re-enter display callbacks.
 */
bool perp_metal_headless_publish(QemuConsole *con, void *texture,
                                  void *ready_event, uint64_t ready_value,
                                  void (*done)(void *, PerpMetalCompletion),
                                  void *opaque);
void perp_metal_headless_shutdown(void);
char *perp_metal_headless_stats(void);
#endif
