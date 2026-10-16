/* SPDX-License-Identifier: MIT */
#ifndef PERP_COCOA_NATIVE_PUBLISHER_H
#define PERP_COCOA_NATIVE_PUBLISHER_H
#import <Metal/Metal.h>
#include <stdbool.h>
/* Enables ordinary 2D listeners for firmware/input alongside the native
 * Metal stream only when the private, validated publisher is available. */
bool perp_native_display_enabled(void);
/* Polled by Cocoa's existing main-loop refresh, never by the publisher queue.
 * A new consumer needs one snapshot even when the guest is idle. The request
 * persists through no-drawable/full-budget/GPU failures until publication, and
 * is false while both immutable snapshot slots are reserved. */
bool perp_native_display_needs_refresh(void);
/* Called after the existing console copy has ended encoding, on its SAME
 * command buffer. Does not wait for a consumer or for GPU completion. */
void perp_native_display_capture(id<MTLCommandBuffer> command,
                                 id<MTLTexture> console_output);
/* Invalidates pending publications and disconnects the consumer on disable. */
void perp_native_display_reset(void);
/* Test/process teardown only; producer command buffers must already be drained. */
void perp_native_display_shutdown(void);
/* Caller frees the returned bounded diagnostics, which contain no pixels. */
char *perp_native_display_stats(void);
#endif
