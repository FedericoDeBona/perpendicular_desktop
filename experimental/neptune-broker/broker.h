/* SPDX-License-Identifier: MIT */
#ifndef PERP_WORKER_BROKER_H
#define PERP_WORKER_BROKER_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "This pinned private descriptor protocol requires little-endian hosts"
#endif
#define PERP_BROKER_MAGIC 0x5042524bu
#define PERP_BROKER_VERSION 1u
enum {
    PERP_HELLO=1, PERP_EXPORT, PERP_CLAIM, PERP_DESTROY, PERP_IMPORT,
    PERP_FRAME, PERP_BOUND, PERP_ACKED, PERP_VERIFIED, PERP_STATS,
    PERP_ERROR, PERP_CLAIM_BEGIN, PERP_IMPORT_RESULT,
    PERP_BIND=100, PERP_ACK, PERP_VERIFY, PERP_STATUS, PERP_UNBIND
};
typedef struct PerpBrokerHeader {
    uint32_t magic;
    uint16_t version,kind;
    uint32_t bytes,fd_count;
    uint64_t session,worker_epoch;
    uint32_t context_id,resource_id;
    uint64_t resource_epoch,blob_id,object_id;
    uint32_t snapshot_generation,status;
} PerpBrokerHeader;
_Static_assert(sizeof(PerpBrokerHeader)==72,"private broker ABI v1");
struct npt_context;
void perp_worker_created(struct npt_context *ctx);
void perp_worker_destroying(struct npt_context *ctx);
void perp_worker_export(struct npt_context *ctx,uint64_t object_id,uint64_t blob_id);
void perp_worker_claim(uint32_t context,uint32_t resource,uint64_t blob,bool success,bool begin);
void perp_worker_resource(uint32_t context,uint32_t resource,bool destroy);
void perp_worker_import_result(uint32_t context,uint32_t resource,bool success);
bool perp_worker_command(uint32_t context,const void *data,size_t bytes);
bool perp_worker_capture_allowed(struct npt_context *ctx,uint64_t blob,uint64_t object);
#endif
