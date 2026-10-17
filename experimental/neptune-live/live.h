/* SPDX-License-Identifier: MIT
 * Private host extension: immutable scanout leases, never a guest ABI. */
#ifndef PERP_NEPTUNE_LIVE_H
#define PERP_NEPTUNE_LIVE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <directx-native/dxn_shared.h>
#include "broker.h"
enum { LIVE_ATTACH=200,LIVE_GRANT,LIVE_ENABLE,LIVE_REVOKE,LIVE_REVOKED,LIVE_DENY,LIVE_DENIED,LIVE_FAULT };
#define LIVE_MAX_CANDIDATES 4u
/* Source identities are metadata; immutable GPU copies have a separate bound. */
#define LIVE_MAX_SOURCES 256u
#define LIVE_MAX_BYTES (64u*1024u*1024u)
#define LIVE_PUBLIC __attribute__((visibility("default")))
struct proxy_socket;
struct npt_context;
/* Actual proxy/renderer lifecycle ingress. All calls occur on its caller
 * thread; GPU ring callbacks use the separately synchronized worker module. */
void perp_live_context_start(uint32_t id,uint32_t capset,struct proxy_socket *socket);
void perp_live_context_stop(uint32_t id);
void perp_live_resource_created(uint32_t id,uint32_t context,uint64_t blob,uint64_t bytes);
void perp_live_resource_destroy(uint32_t id);
bool perp_live_before_import(uint32_t context,uint32_t resource);
void perp_live_renderer_reset(void);
/* These three entry points are consumed by actual QEMU scanout callbacks. */
typedef struct PerpLiveLease {
    uint32_t version,resource_id,context_id,generation;
    uint64_t worker_epoch,resource_epoch,blob_id;
    dxn_shared_texture texture;
    int memory_fd;
} PerpLiveLease;
LIVE_PUBLIC bool perp_live_scanout_select(uint32_t resource);
LIVE_PUBLIC void perp_live_scanout_pump(void);
LIVE_PUBLIC bool perp_live_scanout_needs_pump(void);
LIVE_PUBLIC bool perp_live_scanout_take(uint32_t resource,PerpLiveLease *lease);
LIVE_PUBLIC void perp_live_scanout_done(const PerpLiveLease *lease,bool read);
LIVE_PUBLIC char *perp_live_scanout_stats(void);
/* Actual server dispatch extension, installed only in the private overlay. */
bool perp_live_worker_command(uint32_t context,const void *bytes,size_t count,const int *fds,unsigned fd_count);
void perp_live_worker_claim(uint32_t context,uint32_t resource,uint64_t blob);
void perp_live_worker_resource_destroy(uint32_t context,uint32_t resource);
void perp_live_worker_created(struct npt_context *ctx);
bool perp_live_worker_export(struct npt_context *ctx,uint64_t object,uint64_t blob);
void perp_live_worker_stopped(struct npt_context *ctx);
#endif
