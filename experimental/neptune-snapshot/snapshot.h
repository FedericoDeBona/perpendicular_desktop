/* SPDX-License-Identifier: MIT */
#ifndef PERP_NPT_SNAPSHOT_H
#define PERP_NPT_SNAPSHOT_H
#include "npt_com.h"
#include "neptune-protocol/npt_protocol_host_dispatch_types.h"
#include <directx-native/dxn_shared.h>

struct npt_context;
/* All contexts are counted. No production path asserts exclusive ownership.
 * The closed-world fixture has one decoder, one immediate writer and no
 * shared-resource import ingress. A future worker broker must prove that
 * same contract before replacing this explicitly development-only admission. */
void perp_snapshot_context_created(struct npt_context *ctx);
void perp_snapshot_context_destroying(struct npt_context *ctx);
bool perp_snapshot_fixture_admit(struct npt_context *ctx, int channel);
void perp_snapshot_export(struct npt_context *ctx, uint64_t object_id,
                          uint64_t blob_id, void *texture,
                          const dxn_shared_texture *descriptor);
void perp_snapshot_import(struct npt_context *ctx, uint32_t resource_id);
void perp_snapshot_forget_export(struct npt_context *ctx, uint64_t blob_id);
HRESULT perp_snapshot_signal(struct npt_context *ctx, void *writer,
                              ID3D11Fence *fence, uint64_t value,
                              PFN_ID3D11DeviceContext4_Signal original);
bool perp_snapshot_drain_ack(struct npt_context *ctx, bool wait);
char *perp_snapshot_stats(void);
#endif
