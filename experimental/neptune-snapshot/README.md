# Actual Neptune decoder → immutable snapshot → QEMU VNC

This development checkpoint connects the real pinned Neptune decoder and DXMT
producer to the [headless adapter](../metal-headless/README.md). It uses a
separate host decoder process and diskless/CPU-less QEMU, with native GPU work,
shared memory, actual completion fds, an immutable snapshot and a checked ACK.
It does **not** enable production capture from a running Windows VM.

```sh
.tools/build-venv/bin/python scripts/graphics-neptune.py --causality
```

The private stack from [graphics-README](../../scripts/graphics-README.md) must
already exist. `--test` omits the deliberate broken-reader variant;
`--registry-only` only compiles the registry/renderer overlay. Build is sequential
at optimization 0. The generated protocol helpers have unused scalar arguments,
so only that warning is suppressed; the overlay otherwise compiles with
warnings as errors. No dependencies are downloaded by this script.

## Real integration points

The applicator verifies immutable source pins, creates patched copies of
**three** existing renderer files under the private build directory and compiles
them with their actual Ninja recipe:

- `npt_context.c` counts successful context creation and drains the snapshot
  registry after its ring/sync workers stop, before context teardown.
- `npt_shared.c` registers successful D3D11 exports with object/blob identity,
  actual texture owner and immediate writer. Shared-resource import invalidates
  the admitted scope, including rejected import attempts.
- `npt_overrides_d3d11_fence.c` calls the new snapshot function from the **existing
  real Context4::Signal override**. It preserves the original Signal HRESULT
  and existing fence feedback behavior.

The builder copies the base `libvirgl.a` and replaces those members only in the
new archive, adding `snapshot.c` and `wire.c`. It checks the base archive hash
remains unchanged. The actual decoder fixture links that archive and the pinned
support libraries. QEMU gets a separate binary with the unchanged headless
adapter plus a development-only QOM bridge. The binary passes strict ad hoc
signature verification using the pinned public Hypervisor entitlement; the
fixture itself never invokes HVF. No pinned tree, base executable, application,
stable bootstrap or guest driver is replaced.

The fixture bootstraps native COM objects and explicitly owns their lifetimes.
It registers those objects in the actual Neptune object table. It then sends
**real binary wire commands** for shared-texture export, ClearView rendering
and Context4::Signal through `npt_context_submit_cmd`, including the generated
dispatcher and actual export/Signal overrides. It does not substitute a mock
decoder or invoke a test copy of the Signal hook.

## Ownership and ordering

Capture requires explicit closed-world **fixture-only** admission: exactly one
known Neptune context, one immediate writer identified by canonical COM identity,
one unambiguous exported texture, no shared-resource import and no multi-ring
state. The texture must have a bounded, CPU-inaccessible, default-usage 2D BGRA8
layout. Its actual device and immediate context are retained. Up to eight export
records are bounded; capture refuses multiple candidates rather than guessing a
scanout. Existing production entry points never grant this admission.

For an admitted Signal, the hook creates/reuses a separate shared linear
snapshot, registers an actual backend event on the producer fence, queues
`CopyResource(snapshot, original)` **before** the original Signal, then sends
snapshot fd, ready fd, blob/context identity and generation over the inherited
Unix channel. A busy snapshot is not rewritten; the original guest Signal still
executes and capture is dropped. A failed allocation/export clears partial
snapshot state before any retry. No FIFO relationship with RESOURCE_FLUSH is
assumed, and a consumer `glFinish` is never used as producer readiness.

The QEMU fixture validates descriptor/extent/pitch/format/bounds and increasing
generation. It maps the actual snapshot shm fd into a Metal buffer/linear
texture and publishes an adapter read lease. A pollable backend event proves
producer completion; only after that event and the separately verified original
overwrite does it signal the adapter's local ready event. The adapter reads
through ANGLE/PBO, writes DisplaySurface and notifies VNC. Its exactly-once
completion sends an ACK with the same generation. The producer checks that
generation and actual fence completion before allowing snapshot reuse. Invalid
ACK, disconnect, ambiguous owner or missing readiness closes capture.

The transport is deliberately a tiny, same-host fixture protocol: fixed 176-byte
frame, exactly two SCM_RIGHTS fds and 16-byte ACK, no pointer/fd-number reuse
across processes, no listener or TCP. A short/malformed transfer fails closed;
this is not yet the general render-server RPC framing implementation. Mapping
size is capped at 64 MiB, pixels at 8,388,608 and each dimension at 4096. Only one
snapshot is captured at once. Up to eight retained source export resources can
remain until explicit fixture removal or context destruction; that is bounded
retention, not a production COM-release/resource broker.

## Verified behavior

On this Mac the pipeline passes **8 frames / 7,042,042 exact VNC pixels** through
800×600 → 1920×1080 → 803×607 → 800×600, two reversed color generations per
backing, plus a constant midtone cross. For every frame, the real decoder first
captures the image, then rewrites the original magenta; a GPU fence and D3D11
staging map verify every original pixel **before** the consumer reads the
snapshot. This supplies a causal non-reuse check, rather than keeping the
original conveniently idle.

The final successful registry has captures=8, acked=8, busy drops=8,
active=0, exports=0, contexts=0. QEMU releases all 8 native handles and 8 mappings;
the adapter has zero remaining read leases. The maximum pending count is one,
and PBO plus scratch reaches 16,588,800 bytes at 1920×1080. Per-run synchronous
read duration is retained in the receipt for diagnosis; this O0 fixture has no
fluidity/throughput claim.

The withheld-token case completes and verifies the original GPU work, but
deliberately never signals the token given to the consumer. The adapter times
out and cancels without a single pixel read: completed=0, explicit readback
bytes=0, readback duration=0, native/mapping cleanup=1 and ACK=1. The original
producer fence still completes, so cancellation can safely release the unused
snapshot. The intentionally unsignaled Metal notification may retain backend
notification state until the short-lived producer process exits; it is not a
production cancellation API.

Seven rejection tests use the actual Signal dispatcher: unadmitted scope,
different native device/writer, multi-ring flag, a second actual Neptune
context, actual shared-open import path, ambiguous exports and a 4097-pixel
width. Each emits no snapshot and increments its specific rejection counter.
The multi-ring test exercises the state guard; it does not run concurrent guest
ring threads. Two additional tests reject a wrong ACK generation and consumer
disconnect after the original overwrite, with no consumer GPU read.

`--causality` compiles a separate reader that deliberately ignores the ready fd
after the verified overwrite. The withheld-token test must fail because that
reader exposes one frame; the passing source and binary remain unchanged.
This mutant reads only after real GPU writes have completed and been checked,
so detecting the missing-token guard does not introduce an unfinished producer
GPU race into the test itself.

Receipts under `.tools/graphics-experiment/provenance/` are:
`neptune-snapshot-build.json`, `neptune-pipeline.json`,
`neptune-pipeline-withheld.json`, `neptune-guards.json` and
`neptune-causality.json`. Detailed command/process output is in private `logs/`.
QMP independently verifies the QEMU fixture has no guest CPU or disk.

## Explicit remaining gates

This is real decoder/DXMT/QEMU/VNC execution in a **closed host fixture**, not a
full guest render-server integration. It does not run asynchronous Neptune ring
workers, the existing proxy IPC, multiple writer devices or Windows flips.
The production path remains denied until a VM-global broker associates exported
blob/resource identities and imports across worker **processes**, proves the
writer relationship, handles resource/COM release and selects the snapshot
generation for a real scanout. Source-fd identity alone is insufficient; Darwin
POSIX shm fstat has no useful regular-file inode identity to infer that relation.

Next integrate a versioned worker-broker message carrying that registry and
snapshot lifecycle, with bounded parsing and failure cleanup, while retaining
these rejection guards. Replay reordered control/ring delivery and worker
restart with real workers before any accelerated Windows trial. Multi-writer
ownership stays unsupported until explicit queue ordering is implemented. The
published signed guest driver can remain unchanged; no new guest protocol or
security override is introduced by this host-only primitive. The separate
[2D clone trial plan](../producer-sync/COMPATIBILITY.md) can proceed independently.
