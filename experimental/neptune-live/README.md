# Actual Neptune proxy/server and QEMU scanout overlay

This is an isolated development checkpoint, not enabled in the installed app,
stable engine or Windows VM. It replaces the earlier worker bootstrap fixture
with the actual QEMU virtio device, renderer public API, proxy, server process,
spawned renderer worker and Neptune wire decoder. The signed Windows driver is
unchanged and has **not** been tested with this overlay.

The guarantee being tested is **a completed immutable snapshot of the exact
selected resource/blob/worker/resource epoch**. A one-to-one association with a
particular Windows Present is **not proved**. In particular, SET_SCANOUT_BLOB and
RESOURCE_FLUSH do not carry the original present fence token. Multiple Signal
calls, queued presents, DWM cross-process composition and real driver behaviour
remain acceptance gates; a correct host test is not proof of Windows acceleration.

## Repeat the checkpoint

Prerequisites are the existing pinned private graphics build from
[`scripts/graphics-README.md`](../../scripts/graphics-README.md), including its
source verification. No dependency download or installer runs here.

```sh
.tools/build-venv/bin/python scripts/graphics-live.py --causality
```

The builder uses one compiler job, applies exact-context overlays to private
copies, and checks all source pins. Outputs are only under
`.tools/graphics-experiment/build/neptune-live`. It creates a separate renderer
dylib, complete `virgl_render_server`, and ad-hoc-signed experimental QEMU. The
stable QEMU, original source checkouts and earlier checkpoint sources are not
edited. `--test` omits the two deliberately unsafe mutation checks; omitting both
flags only builds. Individual tests can be repeated without building:

```sh
.tools/build-venv/bin/python experimental/neptune-live/test-live.py --mode baseline
.tools/build-venv/bin/python experimental/neptune-live/test-live.py --mode withheld
.tools/build-venv/bin/python experimental/neptune-live/test-live.py --mode reused-fence
.tools/build-venv/bin/python experimental/neptune-live/test-live.py --mode reset-pending
.tools/build-venv/bin/python experimental/neptune-live/test-live.py --mode late-completion
```

Each test owns a new 128 MiB QEMU machine, one stopped TCG vCPU, no firmware
payload, no disk and private Unix qtest/QMP/VNC sockets. It never opens an existing
VM. The Python qtest client enumerates the real virtio PCI capabilities and
submits actual control-queue requests. Device, texture, render-target and fence
objects are created only by the normal Neptune decoder. There is no native COM
fixture bootstrap or extra guest opcode. The normal server/worker spawn topology
and native DXMT backend are used.

The actual asynchronous Neptune ring carries the COM calls. The real
SUBMIT_VQ_SEQNO/WAIT_VQ_SEQNO edge orders context and ring work; reply streams are
set on the ring's own encoder. qtest's stopped-CPU memory writes exercise this
transport, not ARM guest CPU/cache memory-ordering behaviour.

## Ingress and lifetime

* The actual proxy context start transfers a private side-channel descriptor
  over its existing context socket after INIT. No fork arguments or inherited
  descriptor topology are changed. The extension is enabled only by the private
  `PERP_NEPTUNE_SCANOUT_BROKER=1` environment opt-in.
* The worker independently observes successful shared-texture exports and actual
  successful CREATE_RESOURCE claims. The proxy also waits for successful
  **VM-global** virgl resource registration. Export and claim records join by
  identity in either arrival order, never by FIFO position.
* At most four explicitly associated candidates from one verified immediate
  device/writer may be admitted. Another writer/device, canonical texture alias,
  shared-texture import, multiple rings, unknown epoch, resource-ID reuse or
  unsupported layout closes capture. Candidate exports are not called
  backbuffers until QEMU selects an exact resource.
* The real Context4::Signal override inserts CopyResource for every admitted,
  non-denied candidate **before** the original Signal. A native event for that
  fence/value travels with each immutable snapshot. This first scope accepts
  only one observed fence, owned by the same device, with strictly increasing,
  not-already-completed values. Reusing a value could otherwise make an event
  ready before a new copy; it is rejected while the original guest Signal still
  executes. A second fence is unsupported, not guessed to be a present fence.
* QEMU's real SET_SCANOUT_BLOB selects a resource after Signal may already have
  run. A later timer/RESOURCE_FLUSH consumes only the exact resource and current
  epochs, after actual producer POLLIN without EOF/HUP/error. Selection changes
  cancel the old adapter lease before changing its configuration generation.
  Unselected ready candidates are cancelled; they are not published speculatively.
  A host-only batch identity groups the snapshots inserted before one Signal.
  Reading or cancelling one chosen lease retires the other candidates of that
  batch, including an event that becomes ready just after the first callback.
* The snapshot fd is mapped into a Metal buffer/texture. A local shared-event
  value records completion already established from the producer descriptor; it
  does not pretend to signal another process's GPU queue. The frozen headless
  adapter performs Metal/ANGLE/PBO readback into the real DisplaySurface/VNC.
* ACK/cancel identifies worker, resource, blob, epochs and snapshot generation.
  The worker verifies its real fence has completed before allowing reuse.
  Mapping/texture lifetimes survive asynchronous callbacks independently of the
  original texture. A different context's import first waits for an explicit
  denial barrier and completion of any already-added copy before forwarding;
  failure denies forwarding. This barrier may block the experimental caller for
  up to 1.1 seconds and is not a performance solution.
* A malformed/unready/dead active worker closes capture until a full renderer
  reset. QEMU scanout disable/reset cancels leases first. QEMU intentionally
  defers renderer reset until its next GPU command; that real boundary is used
  in the reset test before recreating the same resource IDs in a new epoch.
  The configuration counter lives outside the cleared console struct. A callback
  can mutate its slot only when both that generation and the active read identity
  still match; it always retires its own old lease independently. An old leased
  descriptor also blocks allocation of a new worker's snapshot budget until it
  is released. Invalid private control messages can terminate the worker; this
  prototype is not promised to preserve guest rendering after failed admission.

The extra worker snapshot allocation budget is 64 MiB total with four candidate
slots. The proxy also caps pending descriptors and snapshot bytes at four and
64 MiB. Existing adapter limits remain in force (one pending lease per console,
4096 maximum dimension, eight megapixels and bounded PBO/scratch buffers). This
is not a limit on all guest allocations or on total QEMU memory. Metadata pools
are bounded to 32 contexts and 256 resource/tombstone entries; exhaustion fails
closed. One controller/output, BGRA8, linear single-plane, one mip/layer/sample
and zero source offset are supported. Capture completion timeout is one second.

## Real-path checks and evidence

`baseline` creates two distinct 800×600 texture/blob/resource tuples. After each
actual Signal, it selects the other resource using actual SET_SCANOUT_BLOB and
RESOURCE_FLUSH. It holds consumer readback, rewrites **both** original textures
to magenta, and reads every original pixel through real mapped blob memory to
prove GPU overwrite completed. It then releases the consumer and compares all
VNC pixels against two distinct quadrant/cross patterns. Four frames prove the
201→200→201→200 resource selection, orientation, colours and immutable storage:
1,920,000 displayed pixels and 3,840,000 overwritten original pixels. Eight
snapshots become four reads and four cancellations, with no pending lease;
disable releases all four native handles and mappings. Observed pending peak is
two snapshots / 3,840,000 bytes, with one adapter lease. Timings at O0 are only
diagnostics, not throughput or fluidity claims.

`withheld` requests an unreachable consumer event value while the original
Signal/copy use the real value. The real fence and full original overwrite must
finish, yet consumer reads, submissions and readback allocation remain zero.
The completion timeout closes capture and cleans pending descriptors.
`reused-fence` proves a repeated value is rejected without an extra snapshot.
`reset-pending` resets the actual virtio device with both snapshots pending,
proves zero publication, then recreates the real worker/context/resource IDs and
repeats the four-frame check under fresh epochs.
`late-completion` holds the real adapter's local consumer event, resets the
device with its lease pending, recreates the same resource IDs/dimensions in a
new worker, and holds a new adapter lease pending. It then releases a deliberately
delayed **post-ACK console-state continuation** from the old cancellation. The
new lease must remain active, its configuration generation must increase (2→4
observed), and its eventual VNC pixels must be exact. The old continuation owns
no fd or GPU buffer: this adversarial test does not claim the underlying adapter
cancel callback is asynchronous. One cancellation plus one completed read releases
both native handles and mappings.

The causality runner links two private mutated dylibs from copied archives.
Ignoring readiness must fail with `Unready producer token was published` after
real GPU completion. Ignoring exact resource selection must fail the VNC pixel
comparison or the count of publications for that exact Signal batch (a later
correct frame can mask an earlier incorrect frame in a VNC snapshot). The ordinary
libraries and binary are not overwritten by mutants.

Logs are under `.tools/graphics-experiment/logs/live-*` and `neptune-live-*`.
Build, per-mode and causality receipts are under that prefix's `provenance/`.
Successful runner output is required; these descriptions alone are not results.
The development QOM properties `perp-live-hold-read`, `perp-live-hold-adapter`
and `perp-live-delay-done` only hold the real consumer/its local event or delay
that final console-state continuation. They default false and are absent from
stable QEMU. They cannot manufacture producer completion.

## Remaining Windows gate

The minimum intended trial is a fixed-size, single-device/single-ring exclusive
D3D11 scene with at most four BGRA8 scanout candidates, one monotonic producer
fence, no shared-texture import and no resize/device reset during the scene.
That is a trial proposal, not proof that a real Windows desktop qualifies.

Research source [Triton present ordering](https://github.com/osy/virtio-win-mesa/blob/bf536bba65454900d782fa7417bc95c1608d7483/src/virtio/neptune/triton/tritonDxgi.c)
shows Signal/Flush before the later KMD scanout, and tuple rotation for a real
flip chain. The relation between that source commit and the prebuilt signed
release UMD is **unproved**. Release guest binaries, their source provenance and
the exact observed wire behaviour must be recorded independently in a reviewed
offline clone trial. A normal DWM/imported surface is deliberately unsupported.
No driver has been installed, no Windows VM started and no security policy
changed by this checkpoint.

Original extension/test code is MIT. Applied source remains under its upstream
licenses (QEMU GPLv2, renderer components MIT/Apache-2.0); see the pinned graphics
provenance. This folder contains no Parallels code or binaries.
