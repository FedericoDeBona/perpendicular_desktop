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
ordinary console continues. The consumer retains its current frame for redraw
until replacement and acknowledges it only after every consumer GPU read has
ended. Only that exact ACK makes its immediately-unlinked shared-memory/Metal
backing eligible for reuse. The publisher caches at most two idle backings in
addition to two active leases (at most 256 MiB at the 64-MiB extent limit,
excluding source/consumer/driver storage). Reuse requires the same Metal device,
dimensions and connection generation. An idle geometry/device mismatch is
evicted on a cache miss so a resize cannot strand a full cache of old sizes.
Every frame still gets a new identity and fresh readiness pipe; a previously
signalled token cannot authorize a new copy. Disconnect drops unacknowledged
storage and clears the idle cache, without overwriting old consumer mappings.
Shutdown also clears the cache. Failure and stale-generation paths never cache
a frame that lacks an exact ACK.

All transport state belongs to a serial worker queue. The console thread only
reserves a bounded slot, checks out or allocates shared texture backing and
encodes its blit. A short lock protects cache ownership; no transport or GPU
wait occurs under that lock.
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

The same opt-in now retains an **internal NSWindow without ordering it on
screen**. The process uses the Accessory activation policy instead of the
foreground transformation; fullscreen and full keyboard-grab options are
ignored in this mode. View, window, Metal device/queue, EGL context and the
NSApplication runloop remain alive. This is a hidden-window bridge, not a
windowless backend or a separation from NSView.

During firmware/2D output, direct mode still runs `cocoa_refresh` and hardware
updates but returns before rendering or swapping the invisible EGL window
surface. VNC continues to carry firmware/2D pixels and input independently of
Cocoa focus. This guard matters because the current ANGLE window-surface
implementation can retry `nextDrawable` with its timeout disabled. Once a
native scanout is available, the direct snapshot branch runs normally.
Existing client policy after native output has activated is unchanged: this
patch does not add an automatic native-to-2D client fallback. The publisher's
existing connected-consumer activity remains unchanged; no global power or
activation settings are altered.

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

The internal-hidden-window hooks are a subsequent source-only change to that
candidate. Exact-anchor/reversal checks pass; a new private full build and
runtime qualification are still required. The earlier `direct-source1` hash
does not describe these new window/activation/2D-refresh hooks.

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
one. A second real GPU gate withholds the copy into that reused backing: the
consumer cannot receive it early. Thirty-two further alternating images reuse
the same buffers. A new 809×611 geometry replaces an idle mismatch, is reused,
and then returns to 800×600. Finally the consumer holds an unacknowledged red
snapshot across reset/reconnect while receiving blue through a new connection;
the old red pixels must remain unchanged.

The current M4 run checks 40 delivered frames and 20,196,019 exact pixels,
including immutability rechecks. Its first 35 frames use two backing allocations
and 33 reuses. The complete resize/reconnect run uses four backing allocations,
36 reuses and 39 exact ACKs; the one unacknowledged old frame is discarded on
reset. All 40 capture objects, four mappings and four backings are released at
teardown, with no idle cache or occupied lease remaining. Capture objects and
readiness pipes still exist per frame: this eliminates repeated backing/Metal
texture allocation, not every allocation or the GPU snapshot copy. This
consumer reads CPU pixels solely to validate the fixture; the publisher does
no readback. These allocation counts are not a Windows FPS/latency result.

Three private causal mutants must fail: disabling ACK-based caching at
`steady frames did not reuse backing`, retaining all mismatched cached sizes
at `resize cache did not replace idle mismatch`, and recycling an
unacknowledged buffer into the next connection at
`unacknowledged old snapshot changed after reconnect`. The repeatable runner
records input hashes, outputs and negative results under
`.build/checks/native-publisher/`. No mutant is packaged or installed.
The production pool still requires a fresh QEMU build and a live Windows trial;
the installed ordinary app continues to use its separately verified 2D runtime.

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
source hashes alongside the pooled-backing GPU test. This verifies the
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

## Already-ready external backing leases

`perp_native_display_publish_ready` accepts an immutable shared-memory backing
whose actual producer-ready FD is already signalled. It duplicates the memory
FD and supplies a new retained per-frame readiness pipe after checking that
proof. It allocates no Metal/shared-memory backing, performs no mapping and
encodes no GPU copy. Metadata must satisfy the current zero-offset NDT layout:
BGRA8, bounded dimensions/pitch, size exactly pitch×height and a page-padded FD
extent covering the image. A regular file cannot substitute for a ready token.

On acceptance, one of the same two bounded publication slots owns the provider
retirement callback. Exact consumer ACK invokes it with true. Disconnect,
reset or cancellation invokes it with false; that is **not permission to reuse
the backing**. The provider must abandon its allocation or otherwise preserve
the old reader's immutable storage. Rejected calls invoke no callback. Accepted
callbacks can run on any thread, including before the call returns; provider
state must be marshalled to its own owner queue. External storage never enters
the publisher's owned Metal-backing cache.

The normal publisher runner also builds `test-publisher-external.m`. Real Metal
clears populate three independent source backings. The separate consumer checks
8,192 pixels, rejects an unready offer, and retains an unacknowledged green frame
through disconnect, provider object/FD/map destruction and a new blue frame on
a second connection. Two ACKs and one abandoned lease release all three provider
objects; publisher backing allocations/mappings remain zero. A deliberately
unsafe provider keeps a duplicate of the abandoned backing and rewrites it;
the old consumer must fail at `external abandoned backing was rewritten`.

This entry point is not yet connected to QEMU's worker snapshots. That bridge
must retain multiple immutable generations while the app holds its current
image, bind each callback to the exact worker/resource/snapshot epoch, and
distinguish reusable ACK retirement from allocation abandonment. Returning the
existing worker's single snapshot on publication or treating disconnect as its
ordinary cancel/ACK would allow overwriting the old reader. The validated QEMU
path still uses two GPU copies until that lifetime protocol is implemented.
