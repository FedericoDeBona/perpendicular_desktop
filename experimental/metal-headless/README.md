# Metal headless display experiment

This original adapter implements the pinned QEMU fork's existing `egl-headless`
display slot on macOS. It imports a Metal texture through ANGLE, reads pixels
through an ES3 pixel-pack buffer, converts RGBA into QEMU's `PIXMAN_x8r8g8b8`
DisplaySurface and notifies ordinary 2D listeners, including VNC. It opens no
window or TCP listener. The synthetic device is a development fixture only.

## Build and verify

First build the pinned private stack following
[the graphics instructions](../../scripts/graphics-README.md). Then:

```sh
.tools/build-venv/bin/python scripts/graphics-headless.py --causality
```

The applicator reuses the pinned build's actual Ninja compiler/link recipes,
adds two new native objects, and writes a **distinct** executable under
`.tools/graphics-experiment/build/metal-headless/`. It changes neither pinned
source trees nor the existing private/stable QEMU executables; hashes of the two
base experiment executables are checked before and after. Compilation is
sequential (one job), optimization level 0. Ad hoc signing uses the pinned
public Hypervisor entitlement only; strict verification is required. The
synthetic fixture does not invoke HVF.

`--test` runs the positive fixture alone. `--causality` also compiles two
separate broken variants, outside the source checkout, and requires each to
fail for its specific reason. It never changes the passing adapter source.
Receipts, input/binary hashes and logs remain under the private `provenance/`
and `logs/` directories. The fixture is linked only into this development
binary, never the application or stable runtime.

## Callback and ownership contract

The adapter is a DisplayChangeListener and DisplayGLCtx. It supports 2D
listeners alongside its GL scanout listener. A separate shared EGL read context
preserves the renderer's current context and GL state. The initialization
thread explicitly unbinds its context and pbuffer: Darwin QEMU transfers its
main loop to another thread after initialization.

The producer calls `qemu_console_resize` **before** native scanout publication,
as the pinned VirtIO GPU native path does. The adapter never changes the console
scanout kind from inside a scanout callback. It checks native texture type,
format, device, backing dimensions, crop, surface dimensions and bounded pixel
count. Native coordinates are Metal top-left coordinates, including crop.
GL-only scanouts are unsupported. Ordinary 2D framebuffer behavior remains
available through the existing DisplaySurface callbacks.

Each read needs an explicit `perp_metal_headless_publish` lease: the producer
keeps those pixels immutable until the exactly-once completion callback. A
retain keeps an object alive; it does not keep its contents immutable. The
publication retains its own texture and MTLSharedEvent independently of QEMU's
console-owned native handle. Its nonzero event value must be signaled **after**
all producer writes. Texture/device identity is checked; shared events may
legitimately have a nil `.device` (Apple's SDK explicitly permits cross-device
MTLSharedEvent). The fixture signals a real Metal event after a render/blit.

A pending event never blocks QMP/VNC: refresh checks readiness, and cancels the
lease after one second without reading it. Each console has at most one lease;
replacement, invalid geometry, timeout and shutdown have separate cancellation
results. A successful read maps the PBO synchronously, copies before unmapping,
checks errors, then exposes the converted CPU pixels. `glFinish` drains only
this consumer's commands before returning the lease. It supplies **no producer
or cross-process synchronization**. Failure to establish consumer completion
terminates the isolated experimental process rather than permitting texture
reuse with unknown GPU work outstanding.

At shutdown listeners are unregistered, leases cancelled and retained GPU/EGL
objects released. QEMU's API cannot unset a console's DisplayGLCtx pointer, so
at most 16 small closed context tombstones remain until process exit; their
operations reject new work. The fixture separately releases QEMU's final
native handle and verifies the exact cleanup count.

## Actual verification, 2026-10-15

The harness starts only its own `-machine none -S -nodefaults` process, with no
CPU, disks, firmware or network device, and private Unix QMP/VNC sockets in a
0700 temporary directory. QMP independently checks there are no CPUs/disks.
It uses the actual QEMU callbacks, Metal GPU, ANGLE import/PBO, DisplaySurface
and raw RFB client; expected pixels are independently constructed in Python.

The passing run checked **4,616,442 exact pixels** through eight snapshots:
2D 320×200, private 800×600, shared linear 1920×1080, cropped 803×607 with
nonzero backing origin, growth/shrinkage and a return to the 2D surface.
Negative checks cover missing producer proof, invalid crop, withheld event,
event timeout, pending-lease replacement, 2D fallback and shutdown cancellation.
There were 11 accepted leases: 7 reads and exactly 4 cancellations (one each
invalid, superseded, timeout and shutdown), zero remaining leases, and exactly
12 QEMU native-handle cleanup callbacks. No CPU framebuffer changed before its
event became ready.

The thread-handoff mutant fails with `EGL_BAD_ACCESS` (0x3002) and a callback
timeout; the red/blue conversion mutant fails the exact pixel comparison.
These demonstrate that the harness detects those actual causes, beyond merely
checking that an executable returns success.

The test observed at most one pending lease. Its largest explicit readback
allocation was 16,588,800 bytes (PBO plus scratch at 1920×1080), excluding texture,
driver and DisplaySurface memory. The observed maximum synchronous read call in
this unoptimized cold run was 512,782 microseconds, including first-use driver
work; this is diagnostic evidence of potential blocking, **not a throughput or
fluidity benchmark**. Every run records its own value. The hard allocation
limit is 8,388,608 pixels, dimensions at most 4096, and thus at most 64 MiB for
PBO plus scratch per executing read. GPU/kernel calls have no hard execution
timeout; a wedged GPU can still stall the process.

## Remaining integration gap

The pinned `ScanoutTextureNative` and renderer native-handle APIs contain a
texture type/handle **without a producer fence or immutable lease**. Those
upstream handle-only frames deliberately fail closed here. The synthetic
producer proves the adapter contract; it does not establish that a running
Neptune/DXMT Windows producer fulfills it. No Windows driver, live VM,
cross-process resource export, real present flip or guest acceleration was
tested. A producer-ready plus consumer-done bridge and non-reuse guarantee are
required before using this backend with the real renderer.

The current host libraries target macOS 27 with this toolchain; this is not
macOS 14 runtime validation. Cursor scanout and GL texture fallback are not
implemented. The linked original C/Objective-C files are MIT licensed (see
[LICENSE](LICENSE)); QEMU and its dependencies retain their own licenses.
