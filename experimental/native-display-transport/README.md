# Native display FD lease transport (experimental)

Original macOS C17 transport for a producer process and a Swift/native consumer.
It transfers immutable frame leases backed by shared memory over a private
Unix stream socket. It does not contain a renderer, GPU synchronization
implementation, VM control, network listener, pool allocator or private SDK ABI.
The C code has no heap allocations or external dependencies. License: [MIT](LICENSE).

## API and ownership

Import `ndt.h` through a Swift bridging header, and compile `ndt.c` as C17.
`BindingCheck.swift` type-checks the imported API. All calls for a connection must
run on one serial worker, away from the main thread. Never copy live connection
storage. Call `ndt_client_start` or `ndt_server_accept` before using or closing
connection storage; a zero-initialized Swift struct alone is not initialized.

The producer calls `ndt_listen` in an existing, owned, non-symlink directory with
mode exactly 0700. It creates a socket with mode 0600 and refuses to replace an
existing path. Cleanup unlinks only the socket inode it created. The consumer
checks socket owner/mode, then verifies `getpeereid` and `LOCAL_PEERPID` against
the exact independently supplied producer PID. The accepted side verifies UID.
Both sides require independently supplied nonzero session (128 bits) and epoch; there is
no session learned from the first frame. This protects the endpoint identity;
it is not isolation from an otherwise malicious process running as the user.

`ndt_status` returns `NDT_OK` when connected, `NDT_AGAIN` while connecting,
`NDT_CLOSED` after clean closure, or a negative terminal error. `ndt_socket_fd`
is borrowed and must not be closed. `ndt_poll_events` supplies its poll mask.
`ndt_pump` never waits: it attempts at most one nonblocking transmit and one
nonblocking receive, retaining partial records. Its `NDT_AGAIN` means idle or
connecting, not failure. The caller supplies connection/readiness deadlines.

The producer calls `ndt_queue_frame` with memory/readiness FDs. It retains its
originals; the transport duplicates both with CLOEXEC and closes those internal
duplicates after the first successful send. Keep the leased backing immutable
and its readiness writer alive until the exact ACK. Two outstanding identities
and one queued transmit record are allowed. Two slots let a presenter retain
its current frame until a replacement arrives. Backpressure returns AGAIN;
it never overwrites a live slot. Sizes can change within an epoch. Frame IDs
must strictly increase on the connection; use launch-global monotonic IDs if
reconnecting with the same session/epoch.

The consumer calls `ndt_take_frame`, which transfers both received FDs and the
actual page-padded fstat extent to caller ownership. Before mapping or reading
pixels, require `ndt_ready == NDT_OK`. That check polls the real readiness FIFO
or Unix socket for POLLIN, rejects HUP/error even when readable, and never
consumes the token. A regular file or write-only pipe cannot fake readiness.
The token is evidence that the producer signalled; the C library cannot prove
that a GPU command completed. The producer must signal only after its actual
copy completion. There is no trusted ready bit in metadata.

Retire a frame and drain **all** GPU reads before `ndt_queue_ack` and
`ndt_frame_close`. ACK identifies the exact session/epoch/frame; the producer
obtains it through `ndt_next_event`. An ACK for an unknown identity closes the
connection. `ndt_frame_close` is idempotent, but is safe only after the caller's
reads drain. Handle AGAIN from queueing an ACK by retrying on the worker; do
not silently discard a pending retirement.

`ndt_close` closes only internally owned FDs and preserves ACK/CANCEL events.
Drain those before reinitializing connection storage. Already taken frames
survive transport closure and still require caller GPU drain and frame_close.
Disconnect/cancellation never grants permission to reuse mutable backing.
A producer may pool backing only after its exact ACK; unacknowledged storage
must remain immutable even after disconnect. A receiver's own FD/mapping keeps
that allocation alive when the producer drops its handles. The Cocoa publisher
also keeps its idle cache within one connection generation and gives every
reuse a fresh readiness pipe; pooling itself is outside this C transport.
No Darwin sealing primitive enforces immutability; it is a producer contract,
and admission-time fstat does not prevent a malicious producer truncation.

## Wire v1

Every record is exactly 128 bytes, encoded explicitly little endian; no C struct
layout is serialized. One FRAME carries exactly two SCM_RIGHTS FDs in order
`memory, readiness`, associated with the first payload byte. An ACK carries no
FDs. Additional or late ancillary rights, truncated records/ancillary, nonzero
reserved bytes, unknown versions/types and malformed metadata fail closed.

| Offset | Bytes | Value |
| --- | --- | --- |
|0|8|ASCII `PERPFD01`|
|8|2|type 1 FRAME or 2 ACK|
|10|2|version 1|
|12|4|record size 128|
|16|8|session high 64 bits|
|24|8|session low 64 bits|
|32|8|epoch|
|40|8|nonzero frame ID|
|48|4|width|
|52|4|height|
|56|4|pitch in bytes|
|60|4|BGRA8 format 87|
|64|8|offset, currently required 0|
|72|8|logical byte size|
|80|48|reserved zero|

ACK bytes 48..127 must all be zero. Dimensions are 1..4096 with at most 8 Mi pixels;
pitch is at least width*4 and divisible by 4. Logical size must equal pitch*height,
and fit 64 MiB. Memory must be readable regular-file/POSIX-shm storage, positive,
page padded, at most 64 MiB, and contain the logical extent. Both received FDs
get CLOEXEC before adoption. Two pending frames imply at most 128 MiB of accepted
storage extent per connection, apart from caller GPU resources. TX/RX buffers,
slots and ancillary scratch space are fixed; no peer-controlled allocation.

### Darwin ancillary envelope

On the tested Darwin 27.2.0 kernel a deliberately too-small control buffer
installed surplus rights without returning all their descriptor numbers. Thus
rejecting MSG_CTRUNC and closing only the visible pair is insufficient. The
production receiver reserves the complete 512-FD Darwin envelope, enumerates and
closes every surplus descriptor, while still accepting only two for a frame.

The source bounds checked at XNU commit
[`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`](https://github.com/apple-oss-distributions/xnu/tree/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea)
are `UIPC_MAX_CMSG_FD`, `unp_internalize`/`unp_externalize` in
[`uipc_usrreq.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/uipc_usrreq.c),
the MCLBYTES control-input limit and LP64 expansion in
[`sockargs`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/uipc_syscalls.c),
and the control/data boundary in
[`soreceive_ctl`/`soreceive`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/uipc_socket.c).
These sources explain the buffer choice; they are not asserted to be the exact
source of the running kernel. Reaudit this envelope on a changed kernel ABI.
MSG_CTRUNC remains a terminal error. No process-wide FD-table scan is used for
production cleanup.

## Verification

Run `sh experimental/native-display-transport/run.sh` on macOS. It builds the
unchanged production C implementation with ASan/UBSan, runs 28 cases using actual
SCM_RIGHTS between two owned processes, then separately runs test-only syscall
shims for forced one-byte sends and a forced MSG_CTRUNC flag. It type-checks
the Swift binding. There are no downloads or VM operations.

The production suite checks exact peer PID, two held frames, resize/padded pitch,
third-frame backpressure, withheld/readable/HUP readiness, bytewise partial RX,
malformed wire fields, missing/late/extra FD sets, actual 20/254-FD surplus sends,
wrong FD types, exact ACKs, EOF with a caller-owned frame, and repeated cleanup.
Both processes compare their open FD counts. Separate local guards check private
socket modes, refusal to replace a path, actual POSIX shm and padded extent.
The CTRUNC shim uses real received rights and then sets that flag; it tests the
error path, not a naturally occurring kernel truncation with the full buffer.
The one-byte TX shim invokes the actual syscall and exercises partial-send FD
ownership. CPU pixel reads occur only after the readiness token.

Result on Darwin 27.2.0, Apple clang 21.0.0 and Swift 6.4: complete production
suite passed 10 consecutive ASan/UBSan runs; both shim cases and Swift import
passed. This directory's fixture uses CPU pixels and proves no GPU/Windows/3D
claim. The separate Cocoa publisher/Metal presenter fixtures must establish
their actual producer and consumer GPU ordering.

A reusable CPU producer can be built with
`xcrun clang -std=c17 ndt.c fixture.c -o /tmp/ndt-producer` from this directory.
Create an owned 0700 directory and run `/tmp/ndt-producer --serve /absolute/path`.
It prints LISTENING, accepts one client at `display.sock` using session 11/22,
epoch 1, sends 64x32 then 80x40 top-red/bottom-blue frames (pitches 256/512), and
waits for two exact ACKs before printing ACKED 2. Its 25-second process deadline
is a fixture bound, not a production transport policy.
