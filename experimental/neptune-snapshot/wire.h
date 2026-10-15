/* SPDX-License-Identifier: MIT */
#ifndef PERP_NPT_WIRE_H
#define PERP_NPT_WIRE_H
#include <stdint.h>
#include <directx-native/dxn_shared.h>
#define PERP_SNAPSHOT_MAGIC 0x50534e50u
typedef struct PerpSnapshotPacket {
    uint32_t magic, version, generation, context_id;
    uint64_t blob_id;
    dxn_shared_texture texture;
} PerpSnapshotPacket;
typedef struct PerpSnapshotAck {
    uint32_t magic, generation, status, reserved;
} PerpSnapshotAck;
_Static_assert(sizeof(PerpSnapshotPacket)==176,"snapshot packet ABI");
_Static_assert(sizeof(PerpSnapshotAck)==16,"snapshot ACK ABI");
/* Transport requires one entire bounded packet and exactly 2 SCM_RIGHTS fds.
 * Only the owned fixture channel is accepted. No TCP or socket listener. */
int perp_snapshot_send(int channel,const PerpSnapshotPacket *packet,int memory_fd,int ready_fd);
int perp_snapshot_receive(int channel,PerpSnapshotPacket *packet,int fds[2]);
#endif
