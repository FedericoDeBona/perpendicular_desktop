# Ordered DXMT snapshot across processes

This host-only experiment exercises **the real pinned native DXMT library**,
rather than a synthetic Metal render loop. It tests the core proposed for a
Neptune host-side snapshot bridge, while leaving the existing QEMU adapter,
renderer sources, installed runtime, Windows and VM files unchanged.

```sh
.tools/build-venv/bin/python scripts/graphics-producer.py
```

Build the private stack first, as described in
[graphics-README](../../scripts/graphics-README.md). The script verifies pins,
compiles sequentially at optimization 0 with warnings as errors and runs two
owned processes with an inherited Unix socket pair. No TCP, VM, firmware,
driver, account or system setting is involved. Logs and the hashed receipt
`provenance/producer-sync.json` stay under `.tools/graphics-experiment`.

## What the test does

1. DXMT creates a hardware D3D11 device (actual feature level 11.0, native ABI
   1), a private producer render target and a separate shared linear snapshot.
   `ClearView` draws color quadrants plus a midtone cross through the real
   D3D11→Metal command path. No WARP fallback is requested.
2. `CopyResource(snapshot, original)` is queued on that same immediate context
   before its `ID3D11DeviceContext4::Signal`. The snapshot fd and the backend's
   real event fd are transferred using SCM_RIGHTS, with a fixed-size validated
   descriptor. Pointers and original fd numbers never cross the process boundary.
3. The consumer confirms the event is not ready; only then does the producer
   queue Signal. `ID3D11Fence::SetEventOnCompletion` and `dxmt_event_dup_fd`
   turn actual GPU completion into a pollable descriptor. An intentionally
   withheld Signal is tested separately and must fail before any pixel read,
   even though the producer calls Flush.
4. The producer immediately overwrites the original magenta, completes another
   GPU fence and verifies every overwritten pixel through a D3D11 staging
   resource. The consumer waits for that verification before importing the
   snapshot. The original therefore need not remain immutable for readback.
5. The consumer validates layout, dimensions, format, pitch, actual fd extent
   and bounded allocation; maps the producer's real POSIX shared memory;
   wraps it as a Metal buffer/linear texture on ANGLE's device; imports EGLImage
   and reads through a PBO. It checks every RGBA pixel, including orientation.
6. Only after consumer GPU work and readback finish does it send ACK, allowing
   the producer to reuse the snapshot backing. Two inverted color generations
   on each backing detect stale reads. Every mapping is released before exit.

The test passes **8 frames / 7,042,042 exact snapshot pixels**, through
800×600 → 1920×1080 → 803×607 → 800×600. Another 7,042,042 staging pixels
verify the original was magenta before each snapshot read. All 8 shared-memory
mappings are released. The missing-Signal fixture rejects before its first
snapshot read. These are functional checks, not a fluidity benchmark.

Darwin's POSIX shm fd reports mode `0600` with no S_IFMT type bits. The consumer
accepts that observed form or a regular file, while retaining fd-size and
allocation bounds. This agrees with Apple's kernel `pshm_stat`, which copies
the creation mode into `st_mode` without adding S_IFREG.
[Apple source](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/posix_shm.c#L654).

## Source evidence and actual missing integration

The source lock remains [graphics-sources.json](../../scripts/graphics-sources.json).
The relevant pinned APIs are:

| Source | Observed contract |
| --- | --- |
| [DXMT Context4::Signal](https://github.com/utmapp/dxmt/blob/2a7dd3e7d22541611433441b82894ec5bca75ca2/src/d3d11/d3d11_context_imm.cpp#L604) | Inserts a Metal shared-event signal into the context's command stream and flushes it. |
| [DXMT D3D11 fence](https://github.com/utmapp/dxmt/blob/2a7dd3e7d22541611433441b82894ec5bca75ca2/src/d3d11/d3d11_fence.cpp#L79) | GetCompletedValue observes the event; SetEventOnCompletion uses the backend's shared-event listener. |
| [directx-native event ABI](https://github.com/osy/directx-native/blob/52fb0875e5717119becd89e7c4f258321aeec427/include/directx-native/dxn_event.h) | Opaque event handles belong to their backend; exported poll fds survive SCM_RIGHTS. A consumer must not operate on a backend's handle using another copy of the library. |
| [Shared descriptor ABI](https://github.com/osy/directx-native/blob/52fb0875e5717119becd89e7c4f258321aeec427/include/directx-native/dxn_shared.h) | Descriptor is scalar layout, fd is out-of-band identity; legacy GetSharedHandle lifetime belongs to the exporting resource. |
| [Existing Neptune Signal override](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/src/neptune/npt_overrides_d3d11_fence.c) | Already intercepts actual host Context4::Signal in the producer's ordered decoder. This is a concrete insertion point for copy-before-Signal. |
| [Neptune shared export](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/src/neptune/npt_shared.c) | Exports texture fd/layout and resource association, but no display snapshot lease. |
| [Neptune event-ring pairing](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/src/neptune/npt_event.c#L555) | ARM and virtio fences can arrive through separate channels; a missing ARM parks, rather than proving completion. |
| [QEMU native scanout](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/include/ui/console.h) | Native handle carries texture type/pointer, with no producer-ready token or consumer-done callback. |

The signed-release KMD source at
[`769e75cd645fc48f4aaae716ca8a74795fe5e241`](https://github.com/osy/kvm-guest-drivers-windows/tree/769e75cd645fc48f4aaae716ca8a74795fe5e241)
normally gates flip promotion on the exact GPU present token. However,
[`TryPromoteFlip`](https://github.com/osy/kvm-guest-drivers-windows/blob/769e75cd645fc48f4aaae716ca8a74795fe5e241/viogpu/viogpu3d/viogpu_vidpn.cpp#L2236)
also publishes after a token deadline; allocation/submission failure paths in
[`viogpu_adapter.cpp`](https://github.com/osy/kvm-guest-drivers-windows/blob/769e75cd645fc48f4aaae716ca8a74795fe5e241/viogpu/viogpu3d/viogpu_adapter.cpp#L1829)
can retire tokens early.
[`FlushToScreen`](https://github.com/osy/kvm-guest-drivers-windows/blob/769e75cd645fc48f4aaae716ca8a74795fe5e241/viogpu/viogpu3d/viogpu_allocation.cpp#L916)
then sends SET_SCANOUT_BLOB and RESOURCE_FLUSH without carrying the original
producer token. Consequently a bare FLUSH or a texture retain is insufficient
as an unconditional completion/immutability proof. This conclusion is source
analysis, not an observed Windows failure.

The two-process fixture proves the **single, identified producer queue** case.
It does not yet implement Neptune resource registration, renderer RPC or the
QEMU VNC adapter connection. A proposed host-only bridge, preserving the signed
guest driver, must:

- Retain and associate exported scanout textures with blob/resource identity,
  originating device and actual writer context; follow shared-resource imports
  and reject unknown/multiple writer ownership until ordered explicitly.
- Inside the producer decoder's Signal override, queue a bounded snapshot copy
  **before** the original Signal, then attach a backend-created completion fd.
  Adding Signal on the unrelated FLUSH control thread does not supply a decoder
  barrier or prove the final render commands have arrived.
- Publish at most one immutable snapshot per scanout, with generation, complete
  layout, fd, ready fd and ACK identity through a versioned bounded renderer RPC.
  If the snapshot is busy, coalesce/drop the capture; never rewrite it early.
- Have FLUSH select an already captured generation and have QEMU reject a
  missing/unready snapshot. Consume it with the headless adapter and ACK only
  after consumer read completion. Failures cancel/drop frames; they never turn
  missing proof into an early successful fence.
- Exercise actual Neptune dispatch with interleaved contexts, out-of-order
  control/ring arrival, multiple writers, worker crash, resize and teardown
  before connecting an accelerated Windows clone. Our current fixture does not
  prove those cases or establish a one-to-one mapping between a guest flip and
  a particular Signal. Capturing every Signal may add substantial GPU copies;
  this first bounded design has no performance claim.

This path needs host source changes and tests, while the released signed guest
package can remain unchanged. It is a proposed integration built on a verified
primitive, not an implemented accelerated Windows console. See also the
[isolated Windows trial plan](COMPATIBILITY.md).
