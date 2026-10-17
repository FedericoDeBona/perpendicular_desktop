/* SPDX-License-Identifier: MIT
 * Included into a separate, derived snapshot translation unit. */
#include "live.h"
#include <time.h>
static uint64_t live_now(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000ull+t.tv_nsec;}
static struct npt_context *live_context;
static int live_broker=-1,live_acks[2]={-1,-1};
static uint64_t live_session,live_epoch,live_snapshot_bytes;
static bool live_enabled,live_faulted;
/* One observed monotonic fence is part of this prototype's producer scope.
 * A second/aliased/foreign fence is not inferred to be another present fence. */
static ID3D11Fence *live_fence;
static uint64_t live_last_fence_value;
static uint32_t live_capture_batch;
typedef struct LiveClaim {
    uint32_t resource;
    uint64_t blob,epoch,object;
    bool granted,denied,import_safe;
} LiveClaim;
static LiveClaim live_claims[LIVE_MAX_SOURCES];
/* Canonical COM references prevent pointer reuse from laundering an import. */
static void *live_imported[LIVE_MAX_SOURCES];
static bool live_emit(PerpBrokerHeader *h,const void *body,size_t bytes,const int *fds,unsigned count);
static void live_fault_at_locked(const char *function,unsigned line);
#define live_fault_locked() live_fault_at_locked(__func__,__LINE__)
static LiveClaim *live_claim_blob(uint64_t blob);
