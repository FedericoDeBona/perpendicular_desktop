# Versioned broker with real Neptune workers and rings

This separate development checkpoint runs the actual pinned
`render_context_main`, `render_state`, asynchronous Neptune command-ring
threads, generated D3D11 decoder and DXMT. An original host supervisor associates
ring exports with successful control-side blob/resource claims before enabling
a snapshot. The frozen [decoder/snapshot](../neptune-snapshot/README.md) and
[headless adapter](../metal-headless/README.md) sources remain unchanged.

```sh
.tools/build-venv/bin/python scripts/graphics-broker.py --causality
```

The previously built private pinned stack and frozen Neptune QEMU consumer must
exist. `--test` runs the passing fixtures without deliberate broken variants;
no option only builds. No dependencies are downloaded. Builds use one compiler
job, optimization 0, warnings as errors, with only the same generated-helper
unused-parameter exception as the earlier checkpoint. All new outputs are under
`.tools/graphics-experiment/build/neptune-broker`; no installed or stable
binary, source pin, bootstrap, VM or driver is changed.

## What is real and what is fixture-specific

`worker.c` invokes the existing render-server **worker main loop**, not a mock
dispatcher. Its normal INIT/CREATE_RESOURCE/IMPORT_RESOURCE/DESTROY_RESOURCE and
SUBMIT_CMD requests use the pinned Darwin framed Unix control protocol. Shared
ring memory is a real renderer-created resource, mapped by the host fixture;
its head/tail use C11 acquire/release accesses from `ring-atomic.c`. Ring CREATE,
NOTIFY, shared-texture EXPORT_BLOB, ClearView and Context4::Signal are actual
Neptune commands. The capture still occurs inside the actual Signal override,
before a subsequent real ring command overwrites the source magenta.

The development executable **explicitly bootstraps** native COM objects and
owns their original references. Those references are registered in the real
object table and released after ring/snapshot teardown, before backend-library
unload. No new guest opcode creates arbitrary host objects or executes code.
The supervisor directly spawns each real worker main loop: it does **not** run
`render_worker_create`, the full server/client/proxy process topology or a
Windows guest. Its private broker-control extension and bootstrap token are
only built into this development executable; production capture stays closed.

The applicator derives private copies of the three frozen pinned Neptune edits
and adds broker observations at actual successful export and resource-control
dispatch points. It makes a separate copy of the frozen snapshot module to add
the broker admission guard. Copies of `render_context.c` and `render_socket.c`
also receive the private control extension, safe pre-INIT EOF teardown and an
explicit Darwin frame-length check before assigning a caller's receive buffer.
The upstream Darwin reader previously assigned an unchecked length; no stable
runtime is patched here. The original static archive and every frozen input,
including the QEMU consumer executable, are hashed before and after the build.

## Identity, ownership, lifetime and readiness

`broker.h` defines a version-1, 72-byte little-endian envelope containing:
session, monotonically increasing worker epoch, guest context ID, resource ID,
resource epoch, blob ID, COM object ID, snapshot generation, message kind, total
length and fd count. A frame adds the pinned 176-byte native texture descriptor
packet and exactly two SCM_RIGHTS rights: immutable snapshot memory and actual
producer completion fd. Maximum record size is **248 bytes**. The descriptor
ABI is specific to these same-host pinned components; this is not a portable
public protocol. No pointers or sender fd numbers identify resources remotely.

macOS does not support this Unix SOCK_SEQPACKET use; the existing worker uses
SOCK_STREAM. `broker.py` receives exact bounded header/body portions, tolerates
fragmentation, admits rights only on the first fragment, and closes all received
rights on truncation, wrong identity/version, excess descriptors or invalid
length. Worker sends are serialized, bounded and nonblocking; a short/blocked
send fails capture closed instead of retrying possibly duplicated rights. A
production bridge still needs a bounded asynchronous send queue and backpressure
policy, rather than this fixture's send-or-close behavior.

Both ring EXPORT and a **successful** CREATE_RESOURCE claim must agree before
BIND. A failed control claim before export does not create ownership. BIND is
acknowledged by the worker and checked against its own independently observed
export/blob/object and successful local resource claim. The original snapshot
guard still requires one immediate writer with canonical COM identity, one
export candidate, no D3D shared-open import, no multi-ring and a bounded BGRA8
layout. A process having one context is never treated as global exclusivity.
The supervisor owns all resource ingress in this closed fixture and rejects
an alias imported by another worker. It revokes and waits for the producer's
barrier **before** forwarding that actual cross-worker import.

Each worker has at most one immutable pending snapshot. The broker retains the
shm and actual event rights until the exact consumer ACK. A resource destroyed
while busy is retired for new captures; its source/snapshot references survive
until ACK, then the retained export is disposed. Epoch/resource identity is
checked again by the worker before it accepts an ACK, and its actual D3D fence
must have completed before reuse. The consumer-facing frame generation is
monotonic across worker restarts, while the original producer generation remains
associated with the old worker/resource epoch. A stale ACK cannot release a new
worker's generation 1.

DXMT's pollable event is a pipe mirror (`directx-native`'s
`src/dxn_event_kqueue.c`). Worker exit also produces HUP, which the frozen
consumer correctly rejects. The broker checks actual POLLIN with no
HUP/error **while the producer is live**, then issues its own retained signal
pipe for the consumer; its write end stays open through ACK. That pipe records
an already proven producer completion. EOF or a verified source overwrite alone
never establishes readiness. After this proof, worker death cannot invalidate
the independently retained snapshot memory or notification. Death before proof
drops an unpublished lease; a consumer-owned lease survives until its old ACK
is discarded, with no message delivered to a replacement worker. Teardown also
works when the control socket closes before INIT.

The development broker allows at most four retained worker records, 32 resource
records/claims/imports per scope and eight exports per worker. Dead records with
no consumer lease are removed, while a monotonic high-water epoch prevents
replay without retaining an unbounded restart history. Each renderer snapshot
keeps the frozen 64 MiB descriptor and 8,388,608-pixel caps. The fixture observed
one pending lease at a time; it does not claim a measurement of all Metal/backend
allocations. The separate native verification fence never advances the producer
fence's value, so it cannot accidentally satisfy later captures early.

## Verified results on this Mac

The passing suite starts **10 real worker processes**, initializes nine actual
Neptune contexts/rings, and sends three snapshots through broker → unchanged
QEMU/Metal/ANGLE/PBO → DisplaySurface → Unix VNC. It checks **1,889,021 exact
pixels** at 800×600, 803×607 and 1280×720, with reversed colors and a midtone
cross. For every snapshot, a separately completed D3D staging map verifies the
entire original image has already become magenta before consumer readback.

The first worker is killed **after actual readiness proof but before consumer
read/ACK**. Its snapshot still matches every VNC pixel. New processes reuse
guest context 1, resource 77, blob 100, object 4 and producer generation 1, with
new worker/resource epochs and consumer generations 2/3. Old ACKs are rejected
while the replacement has a live pending lease; the producer stays busy.

The reordered case delays only the development export notification, after the
real pending blob is published. An actual control CREATE_RESOURCE succeeds and
is observed before the delayed ring export message; no BIND/capture is admitted
until both arrive. The suite also sends a Signal before BIND and verifies zero
captures. This proves the association is independent of ring/control arrival
order, rather than inventing FIFO ordering between those channels.

Other checks cover a real second worker importing the actual exported fd,
resource destruction while a snapshot is pending, stale worker epoch, wrong
resource-epoch ACK, oversized control frame, EOF before INIT, and death of an
unready worker. A deliberately withheld producer token is never published to
QEMU, even after the source overwrite and original GPU fence have completed;
it is canceled only through the producer's checked ACK. Three unpublished
failure leases are cleaned up. Header fragmentation and malformed version,
epoch, length, truncation, body and one/three unexpected descriptor rights are
checked, including fd-count equality before/after rejection.

Final passing state: three completed VNC frames, three mappings/native handles
released, no active adapter leases, no broker pending/resource entries, maximum
pending one, and explicit PBO+scratch maximum **7,372,800 bytes**. Per-run O0
readback duration is diagnostic only; there is no throughput/fluidity claim.
QMP independently confirms the consumer has no guest CPU or disk. No Windows,
network listener, guest driver or live VM is involved.

`--causality` runs two separate private Python broker mutations against the same
real workers: ignoring the consumer generation must fail on an old ACK with a
new lease pending; ignoring producer-token readiness must fail on the withheld
case. Both execute after actual GPU completion and checked overwrite, so they
do not introduce an unfinished producer/consumer GPU race. Passing sources and
binary remain untouched. Receipts are `neptune-broker-build.json`,
`neptune-broker.json` and `neptune-broker-causality.json` under private provenance;
baseline and mutant process logs have separate names.

## Remaining path to an accelerated Windows scanout

The private worker/supervisor protocol now proves the association, snapshot and
restart primitives. It does **not** establish that a Windows desktop satisfies
the single-writer scope. In particular DWM and application processes commonly
share resources; this implementation deliberately revokes such imports instead
of pretending ownership or inserting an unrelated FLUSH-thread Signal. Multiple
exports/rings, D3D12 writers and arbitrary device/alias relationships remain
unsupported. COM exports retain bounded references through explicit resource
or context lifetime; this is not a complete production COM_RELEASE broker.

The next minimum integration is to put this VM-global registry at the real
proxy's CREATE_RESOURCE/attach/detach and worker create/destroy boundaries,
transport the versioned worker observations through explicitly inherited private
channels, and bind the **actual QEMU scanout resource ID** to a checked blob and
producer generation. Every ingress must pass through that registry. The full
server's fork/reap/reset flow needs its own integration tests, followed by an
explicit writer-transfer model for resources imported by the Windows compositor.
Only then can the existing signed driver be tried in a separate offline-cloned
Windows experiment; no new guest driver or security bypass is required by this
host primitive. The independent signed DOD 2D clone path can proceed without
waiting for that missing 3D compositor ownership proof.
