/* SPDX-License-Identifier: MIT */
#ifndef PERPENDICULAR_NDT_H
#define PERPENDICULAR_NDT_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NDT_WIRE_BYTES 128
#define NDT_SLOTS 2
#define NDT_MAX_DIMENSION 4096u
#define NDT_MAX_PIXELS (8u * 1024u * 1024u)
#define NDT_MAX_EXTENT (64u * 1024u * 1024u)
#define NDT_BGRA8 87u
#define NDT_PATH_BYTES 104

enum { NDT_OK = 0, NDT_AGAIN = 1, NDT_CLOSED = 2,
       NDT_ERR_ARGUMENT = -1, NDT_ERR_SYSTEM = -2, NDT_ERR_PEER = -3,
       NDT_ERR_PROTOCOL = -4, NDT_ERR_BOUNDS = -5, NDT_ERR_IDENTITY = -6,
       NDT_ERR_TOKEN = -7 };
enum { NDT_EVENT_ACK = 1, NDT_EVENT_CANCEL = 2 };

typedef struct {
    uint64_t session_hi, session_lo, epoch, frame;
} ndt_identity;
typedef struct {
    ndt_identity id;
    uint32_t width, height, pitch, format;
    uint64_t offset, size;
} ndt_metadata;
typedef struct {
    ndt_metadata metadata;
    int memory_fd, ready_fd;
    uint64_t memory_extent; /* actual fstat length, page padded */
} ndt_frame;
typedef struct {
    int kind;
    ndt_identity id;
} ndt_event;

/* Caller-owned fixed storage; fields below are implementation-private.
 * One owner queue/thread per connection. Do not copy a live connection. */
typedef struct {
    ndt_metadata metadata;
    uint64_t extent;
    int state, memory_fd, ready_fd;
} ndt_slot;
typedef struct {
    int fd, role, state, error, system_error;
    uid_t expected_uid;
    pid_t expected_pid;
    uint64_t session_hi, session_lo, epoch, last_frame;
    uint8_t rx[NDT_WIRE_BYTES], tx[NDT_WIRE_BYTES];
    size_t rx_used, tx_used;
    int rx_fds[2], rx_fd_count, tx_fds[2], tx_fd_count;
    int tx_kind, tx_slot;
    ndt_slot slots[NDT_SLOTS];
} ndt_connection;
typedef struct {
    int fd;
    char path[NDT_PATH_BYTES];
    dev_t device;
    ino_t inode;
} ndt_listener;

/* runtime must already exist, owned by effective UID, mode exactly 0700.
 * Never replaces/unlinks an existing socket. Socket mode is 0600. */
int ndt_listen(ndt_listener *listener, const char *runtime, const char *name);
void ndt_listener_close(ndt_listener *listener);
/* Producer is server; consumer verifies UID and exact server PID on connect.
 * Session/epoch are supplied independently by the launch contract, never TOFU.
 * Client start may return AGAIN; finish with pump. All sockets nonblocking. */
int ndt_client_start(ndt_connection *connection, const char *path, uid_t uid,
                     pid_t server_pid, uint64_t session_hi, uint64_t session_lo,
                     uint64_t epoch);
int ndt_server_accept(ndt_listener *listener, ndt_connection *connection,
                      uid_t uid, uint64_t session_hi, uint64_t session_lo,
                      uint64_t epoch);
/* poll mask for the connection fd; pump never waits and does bounded work.
 * Drive off the main thread. Inspect error/system_error after failure. */
short ndt_poll_events(const ndt_connection *connection);
int ndt_socket_fd(const ndt_connection *connection); /* borrowed, never close */
int ndt_status(const ndt_connection *connection); /* OK/AGAIN/CLOSED/error */
int ndt_pump(ndt_connection *connection);
/* Caller retains originals. Queue duplicates both with CLOEXEC. Two outstanding
 * identities allowed, one queued TX record. Frame IDs strictly increase;
 * dimensions may change per frame without changing the expected epoch. */
int ndt_queue_frame(ndt_connection *connection, const ndt_metadata *metadata,
                    int memory_fd, int producer_ready_fd);
/* Transfers ownership of both received FDs to caller. They survive close().
 * Never map/use pixels until ready()==OK. Do not consume the readiness byte. */
int ndt_take_frame(ndt_connection *connection, ndt_frame *frame);
int ndt_ready(int ready_fd);
int ndt_memory_extent(int memory_fd, uint64_t *extent);
/* Caller queues ACK only after retiring the frame and draining every GPU read.
 * This C library cannot establish GPU completion. Then frame_close is safe. */
int ndt_queue_ack(ndt_connection *connection, const ndt_identity *identity);
int ndt_next_event(ndt_connection *connection, ndt_event *event);
void ndt_frame_close(ndt_frame *frame);
/* Idempotent. Closes internal descriptors, preserves pending ACK/CANCEL events.
 * Caller-owned frames still require GPU drain and frame_close. No backing reuse
 * is authorized by disconnect/cancellation: initial frames must be immutable,
 * unique allocations. Drain events before reinitializing the connection. */
void ndt_close(ndt_connection *connection);

#ifdef __cplusplus
}
#endif
#endif
