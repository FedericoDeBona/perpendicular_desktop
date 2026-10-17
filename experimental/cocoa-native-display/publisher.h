/* SPDX-License-Identifier: MIT */
#ifndef PERP_COCOA_NATIVE_PUBLISHER_H
#define PERP_COCOA_NATIVE_PUBLISHER_H
#import <Metal/Metal.h>
#include <stdbool.h>
#include "ndt.h"
/* Enables ordinary 2D listeners for firmware/input alongside the native
 * Metal stream only when the private, validated publisher is available. */
bool perp_native_display_enabled(void);
/* Polled by Cocoa's existing main-loop refresh, never by the publisher queue.
 * A new consumer needs one snapshot even when the guest is idle. The request
 * persists through no-drawable/full-budget/GPU failures until publication, and
 * is false while both immutable snapshot leases are reserved. */
bool perp_native_display_needs_refresh(void);
/* Explicit process opt-in, independent of whether a consumer is connected.
 * Direct mode never silently falls back to a Cocoa drawable. */
bool perp_native_display_direct(void);
/* Atomic admission hint, not a reservation. Capture/publish reserve a slot. */
bool perp_native_display_can_capture(void);
typedef enum {
    PND_CAPTURE_ENCODED,
    PND_CAPTURE_UNAVAILABLE,
    PND_CAPTURE_BACKPRESSURE,
    PND_CAPTURE_INVALID,
    PND_CAPTURE_FAILED,
} PNDCaptureResult;
/* Encode an immutable BGRA8 snapshot of this exact 2D source region onto the
 * caller's command buffer. The caller commits and keeps source/read ownership
 * until GPU completion. No drawable, CPU readback, scaling or guest fence is
 * inferred here. An encoded snapshot is published only after GPU completion.
 * Shared-memory/Metal backing may be reused only after its exact consumer ACK,
 * for the same device, dimensions and connection generation. Each new frame
 * receives a fresh readiness pipe. Two idle backings may be cached in addition
 * to the two active leases; reset/shutdown discard the cache. */
PNDCaptureResult perp_native_display_capture_region(id<MTLCommandBuffer> command,
    id<MTLTexture> source, MTLOrigin origin, MTLSize size);
/* Publish an already immutable, GPU-completed shared backing without another
 * GPU/CPU copy or mapping. The ready FD must prove completion now. On true,
 * publisher owns a duplicated memory FD and calls retirement exactly once:
 * true only after exact consumer ACK; false on disconnect/reset/cancellation.
 * False retirement NEVER permits rewriting the old backing: provider must
 * abandon that allocation or otherwise keep it immutable for the old reader.
 * Rejected calls return false without calling retirement. Callback may run on
 * any thread, even before an accepted call returns; marshal provider state
 * back to its owner queue. */
typedef void (^PNDReadyRetirement)(bool acknowledged);
bool perp_native_display_publish_ready(int memory_fd, int producer_ready_fd,
    const ndt_metadata *metadata, PNDReadyRetirement retirement);
/* Compatible full-texture wrapper. Called after the existing console copy has
 * ended encoding, on its SAME command buffer. Does not wait for a consumer or
 * for GPU completion; ignores capture_region's admission result. */
void perp_native_display_capture(id<MTLCommandBuffer> command,
                                 id<MTLTexture> console_output);
/* Invalidates pending publications and disconnects the consumer on disable. */
void perp_native_display_reset(void);
/* Test/process teardown only; producer command buffers must already be drained. */
void perp_native_display_shutdown(void);
/* Caller frees the returned bounded diagnostics, which contain no pixels. */
char *perp_native_display_stats(void);
#endif
