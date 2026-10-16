# Completed GPU snapshots

This bridge is a step toward presenting the working Windows3D path in the
application's own Metal view. It does not alter the signed guest driver,
renderer protocol or matched Wire1/DMTX backend. The ordinary installed
application remains separate from the private native-client trial; actual
Windows evidence is recorded in the checkpoint linked below.

By default, the pinned Cocoa console copies the selected guest texture into its
drawable. The separate build adds one more GPU blit from that drawable into a
new shared-memory Metal texture, in **the same command buffer**. Only a
successful completion handler signals the owned readiness pipe and offers the
snapshot over the private Unix connection. No pixels are read or copied by the
CPU. This adds a GPU snapshot copy; it is not a claim of zero total copies.

The readiness token proves completion of this owned snapshot operation.
QEMU's scanout interface carries no per-resource producer fence. Neither this
bridge nor the current Cocoa display proves correspondence with every Windows
Present, or absolute absence of an upstream source race. Copying the existing
console output preserves its current DWM/import/multiple-writer path without
inventing an association with the latest observed guest fence.

Two snapshots total may be reserved across GPU completion, queued transmission
and consumer ownership. With a full budget, capture is skipped while the
ordinary console continues. Each frame uses a unique immediately-unlinked
shared-memory allocation; no mutable backing pool is reused. The consumer
retains its current frame for redraw until replacement and acknowledges it
only after every consumer GPU read has ended. Disconnect is not treated as
permission to overwrite outstanding memory. Existing consumer mappings retain
their independent backing even after the publisher releases its own handles.

All transport state belongs to a serial worker queue. The console thread only
reserves a bounded slot, allocates the shared texture and encodes its blit.
The worker handles nonblocking accepts, partial sends and exact-identity ACKs.
Disable/reset closes the connection and changes its generation; a completion
from the previous generation cannot publish into a replacement connection.
Each accepted consumer requests an initial refresh, including when Windows is
idle. Cocoa's existing refresh callback observes this atomic request on QEMU's
main loop and uses its ordinary scanout/draw/inflight path to capture the
current output. The request remains pending until a completed snapshot for
that exact connection is queued. A full two-slot budget suppresses extra
refresh work without losing the request; stale GPU completions after a reset
cannot satisfy a replacement connection. No cached drawable is retained and no
guest input/redraw is required. This source correction still needs a fresh
private QEMU build and the host tab-switch qualification on actual Windows.
The transported format is top-left BGRA8 at destination offset zero, one plane/mip/layer/sample,
maximum4096 dimensions, eight megapixels and64MiB padded extent.

## Direct source snapshot opt-in

`PERP_NATIVE_DISPLAY_DIRECT=1` selects a separate branch in the copied
`drawFrame:` **before `nextDrawable`**. It takes the exact existing
`CocoaGLRead.texture`, `origin` and `size` and encodes one GPU blit into a new
immutable NDT snapshot. It does not acquire, present or capture a
`CAMetalDrawable`. The default branch and its full-texture capture API remain
compatible; unset, `0` and `true` do not enable direct mode. This is a process
launch option, not an application preference.

The new `perp_native_display_capture_region` API validates the texture/device,
BGRA8 format, 2D/single-sample layout, command-buffer state and crop bounds
without overflowing `origin + size`. Snapshot dimensions/pitch describe only
that selected region; NDT still receives an offset-zero texture. Readiness is
signalled by the real command-buffer **completed** handler. The existing Cocoa
read remains retained through GPU completion and is released on QEMU's main
loop.

Direct mode never falls back to a drawable when there is no consumer or the
two-snapshot budget is full. The main-loop dispatcher preserves `gl_dirty`
without allocating or dispatching another Cocoa read until admission becomes
possible. A transient allocation/encoding/GPU failure returns its read through
a separate bottom half: it preserves demand for the ordinary refresh instead
of the original completion bottom half's immediate redispatch. No worker
thread accesses QEMU scanout state, and no extra timer is added. Invalid input
or a disconnected generation is not explicitly rearmed by that failure path;
new connection refresh demand and later guest updates remain independent.

This removes the producer's drawable dependency and one GPU copy. It still
performs one GPU snapshot copy, keeps the Cocoa/GL context and window, and does
not add a guest Present fence or prove the source writer has finished. It is
not a zero-copy or window-removal claim. Host fixtures, source checks and a
fresh private full QEMU build passed on 2026-10-16. The signed candidate hash is
`c631e4ffa1ab77888edbcbcd188bd0c147c8d76143926700ea3661f45eeb0383`;
its private receipt is `.tools/cocoa-native-display-build/direct-source1/build.json`.
All 3,310 protected build inputs remained unchanged. This candidate is not
packaged, installed or tested in Windows, and contains the builder's original
trace3 GPU profile rather than the later STP/HVF diagnostic combination.
The live Windows trial and controlled presentation/latency comparison remain
separate gates.

The producer requires `PERP_NATIVE_DISPLAY_DIR` naming an already private0700
runtime and `PERP_NATIVE_DISPLAY_SESSION` naming its32-hex launch identity.
Its socket is `native-display.sock`, mode0600. The consumer independently checks
the exact expected server PID, user, session and epoch1. No listener is created
when the environment is absent; existing socket paths are never replaced.
These are developer launch parameters, not user-facing integration settings.

Only with that validated publisher enabled, the copied Cocoa backend also
accepts ordinary non-GL display listeners. This permits the existing private
VNC connection to carry input, layout and firmware/2D surfaces while the app
uses the separate native stream for3D pixels. It does not make VNC read native
Metal textures. Without the publisher, Cocoa's original compatibility rule
remains. Qualification applies to the exact private trial and artifacts
recorded in the Windows checkpoint.

## Actual two-process GPU check

```sh
python3 experimental/cocoa-native-display/test-publisher.py
```

The fixture starts two owned native processes, no Windows VM, firmware, disk,
hypervisor or network listener. A real Metal shared-event wait withholds the
first producer command. No frame can arrive until that wait is released.
The other process then verifies the completed shared-memory pixels. It holds
the first snapshot while the original private texture is overwritten magenta,
and verifies that the snapshot remains red. It accepts a differently sized
second frame while still holding the first, checks that a third allocation is
skipped at the two-slot budget, then acknowledges one frame and accepts a new
one. It checks1,927,421 pixels including the immutability recheck. This consumer
reads CPU pixels solely to validate the fixture; the publisher does no readback.

The first actual run passed all these boundaries on the M4, with three
allocations/maps and three releases/unmaps, three exact ACKs, and no occupied
slot at completion. The repeatable runner records exact input hashes and raw
output under `.build/checks/native-publisher/`. A source description or successful
compile alone is not a Windows or application integration result.

The same runner now includes a static-image reconnect regression. Its second
owned process connects three times. A texture rendered red **before any
consumer connects** is captured without another render pass and read correctly
after reconnection (4,096 exact pixels total). Two real Metal commands are
withheld behind a shared-event gate, filling the complete snapshot budget. A
reset/reconnect preserves the next consumer's refresh demand, the old GPU
completions cannot publish into it, and freeing those slots permits the static
image to be published. Four allocations/maps are matched by four releases/
unmaps, with zero occupied slots at completion. An invalid capture does not
consume demand and publication stops the initial-refresh loop.

For a causal negative, the runner compiles a separate private copy with only
the new accept-refresh signal removed. The same fixture must fail specifically
at `initial refresh was not requested`. It never packages or uses that binary
outside the fixture. `refresh_pending` in the bounded statistics distinguishes
a pending request from lack of free snapshot capacity; it contains no pixels,
guest input, session identity or endpoint. The runner records this result and
source hashes alongside the original three-frame GPU test. This verifies the
publisher boundary; Cocoa's hook is checked against its pinned source by
`build.py --check --self-test`, and the real Windows tab switch remains a
separate post-build test.

The region fixture adds three actual Metal snapshots from an11×8 source,
including crops at(3,2) and(6,5) and the final bottom-right pixel(10,7). It checks
56 exact pixels including a held-snapshot immutability recheck after the source
is overwritten. A shared-event gate proves no publication/completion before
the blit can finish. Twelve invalid command/format/region cases allocate no
snapshot and do not consume initial-refresh demand; a full budget returns
backpressure and an ACK restores admission. All three mappings/allocations
are released. A private negative build changing only the source origin to zero
must fail at `exact nonzero crop pixel mismatch`. Separate process fixtures
verify the explicit environment opt-in. These checks do not start QEMU,
Windows, a Cocoa window or an application.

See [separate build and source pins](BUILD.md), the
[transport contract](../native-display-transport/ndt.h), and the
[actual Windows baseline](../../docs/NEPTUNE_WINDOWS_3D_CHECKPOINT.md).

The publisher, fixtures and packaging helper use the MIT license in this
directory. The source-pinned build helper is Apache-2.0 as marked.
The separately patched QEMU source
retains its upstream GPLv2 license; no Parallels implementation is included.
