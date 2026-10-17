# Private graphics experiment

Fetch/build outputs stay under `.tools/graphics-experiment`; network-free tests
also use temporary fixture directories which they remove afterwards. They do not change
the normal bootstrap, packaged runtime, installed app, guest drivers or VMs.
See [`docs/GRAPHICS.md`](../docs/GRAPHICS.md) for the source evidence and limits.

Use the project's existing Python, which also avoids the Apple developer-tools
launcher when Xcode first-launch setup is incomplete:

```sh
.tools/build-venv/bin/python scripts/graphics-fetch.py --llvm-bottle --qemu-wraps --python-tools
.tools/build-venv/bin/python scripts/graphics-fetch.py --verify --llvm-bottle --qemu-wraps --python-tools
.tools/build-venv/bin/python scripts/graphics-tests.py
.tools/build-venv/bin/python scripts/graphics-build.py --stage prerequisites
.tools/build-venv/bin/python scripts/graphics-build.py --stage llvm
```

The `llvm` and `epoxy` stages do not require the Metal shader tools and can run
while that optional Xcode component is pending; the default prerequisite check
and all other stages require both `metal` and `metallib`.
ANGLE targets macOS 14, matching the application baseline; Xcode 27 rejects the
older upstream example's macOS 11 target. Its DerivedData is explicitly kept in
the private build directory, and optional private WebKit SDK additions are off.
For Xcode 27's libc++, the removed `_LIBCPP_ENABLE_ASSERTIONS` build setting is
replaced with extensive hardening. The older ANGLE snapshot produces new Clang21
warnings (constant-false 32-bit bitset shifts, redundant virtual destructors,
and byte-copy descriptor methods). Vendor ANGLE/QEMU builds retain warnings in
their logs without treating them as errors; our smoke still compiles with
`-Wall -Wextra -Werror`. These are recorded build-setting overrides; the pinned
source trees stay clean. Passing the smoke is not validation of all vendor code.

The fetch lock contains full Git commit IDs and the official Homebrew LLVM15
ARM64 Sonoma bottle SHA-256 plus a pinned Homebrew formula. LLVM extraction keeps
headers, static libraries and notices only, avoiding Mach-O relocation and any
installation into Homebrew. It requires the already installed static zstd library
when linking DXMT. Source and dependency provenance, gitlinks (including unused
ones), wrap metadata, license copies, bottle receipts and hashes are retained in
the private `provenance/` directory. WebKit uses sparse checkout of ANGLE and its
build prerequisites; no full WebKit checkout or recursive submodule update occurs.
Only the required DirectX-header gitlink is fetched; optional NVAPI is disabled.
QEMU's six required wrap revisions are checked against its pinned tree before
fetching. Meson builds use `nodownload`, QEMU uses `--disable-download`.
The pinned QEMU's slirp wrap provides the obsolete `libslirp_dep` name, whereas
its pinned slirp source exports `libslirp_libdep`. The QEMU stage first builds that
same slirp revision as a private pkg-config library, keeping both source trees
unchanged. QEMU's private build environment can also install its bundled pycotap
wheel offline from the pinned QEMU tree; it does not fetch it from PyPI.
FDT is selected explicitly as `internal` so the already verified dtc checkout
is used even with automatic downloads disabled. Private HVF features stay off.
The renderer's YAML generator uses [PyYAML 6.0.3](https://pypi.org/project/PyYAML/6.0.3/):
the official source archive is hash-pinned, and only its pure Python package and
MIT license are extracted into the private `python-deps` directory. No `setup.py`,
native extension, global Python install or dependency resolver is run.

Build one stage at a time, in this order:

```sh
.tools/build-venv/bin/python scripts/graphics-build.py --stage angle
.tools/build-venv/bin/python scripts/graphics-build.py --stage epoxy
.tools/build-venv/bin/python scripts/graphics-build.py --stage smoke
.tools/build-venv/bin/python scripts/graphics-build.py --stage dxmt
.tools/build-venv/bin/python scripts/graphics-build.py --stage renderer
```

`--stage all` runs those stages and then the optional private QEMU build;
`--stage qemu` only builds that QEMU. Stages do not implicitly build missing prior
stages. The default stage only checks prerequisites. Logs go into the private
`logs/` directory. Compiler jobs are capped at **two**. No script runs `sudo`,
accepts a license, invokes Xcode first-launch setup, downloads Apple components,
changes the selected system Xcode, or starts QEMU. If Apple setup is required,
the script stops for the coordinating task to handle it. `--developer-dir` selects
a full Xcode `Contents/Developer` path for this process only.

The default `--optimization 0` is deliberate for the first functional smoke:
it reduces compiler memory/time while Windows remains active. This is not a
performance build. `--optimization 3` requests a later optimized rebuild; its
actual settings are recorded in the toolchain provenance and command logs.
These are host experiment binaries, not a distributable macOS 14 runtime.
ANGLE records a minimum OS of 14.0; the current Meson DXMT and renderer binaries
record 27.0 with this Xcode SDK. Broader macOS compatibility remains untested.

The smoke test renders four exact color quadrants plus a fixed midtone cross
into a private Metal texture on ANGLE's own device, waits for GPU completion,
imports it as an EGL image, and reads RGBA pixels from an ES3 framebuffer through
a pixel-pack buffer (PBO). It maps that buffer only after the GL transfer and
checks **every pixel** while growing and shrinking
800×600 → 1920×1080 → 803×607 → 800×600 (including row padding)
in the same context, with both surfaceless and 1×1-pbuffer modes. Its records
identify the actual row orientation; this functional test reports no graphics
performance measurements.

The harness also includes a shared linear buffer-backed texture layout matching
the renderer's `virgl_metal_create_texture_from_shm` descriptor. A Metal GPU blit
fills that texture before import. This layout test uses a same-process Metal
buffer: it does not exercise shared-memory mapping, render-server IPC or producer
fences across processes. Its result is reported separately as `shared_linear`.

On this Mac (macOS 27.2, Xcode 27.0, functional optimization level 0), all 16 PBO
trials passed: 14,084,084 pixel comparisons, including exact BGRA-to-RGBA channel
conversion and the non-primary-color cross. Readback row zero was the Metal top
row in every case. This is actual host-only evidence for native texture import,
readback and framebuffer replacement in this pinned ANGLE snapshot. The compact
machine-readable receipt is `provenance/smoke-results.json`; detailed traces are
in `logs/smoke-run.log` inside the private experiment directory.

The initial direct-CPU `glReadPixels(..., rgba.data())` route terminated with
SIGSEGV in both surface modes after successful image import and a complete FBO.
Source inspection finds `FramebufferMtl::readPixelsImpl` calls
`mtl::ReadTexturePerSliceBytes` → `Texture::getBytes`, whose precondition is
CPU-accessible texture storage. Our imported producer texture uses private GPU
storage. In contrast, `FramebufferMtl::readPixelsToPBO` uses GPU blit/compute
conversion, followed by synchronized `BufferMtl::mapRange`. That route passes
without changing ANGLE sources, texture storage, system permissions or library
metadata. The precondition is a plausible explanation, not a debugger-proven
crash stack. The standalone binary retains `--direct-readback` for explicit
diagnosis; the default is the verified PBO route.

A successful host-only smoke does not establish
guest acceleration, driver trust, or synchronization with an actively flipping
Windows framebuffer. The private QEMU still needs a separately reviewed
VM hardware compatibility check before any future VM experiment. Upstream's
Darwin build itself applies an ad hoc signature with the pinned
`accel/hvf/entitlements.plist` (only `com.apple.security.hypervisor`), without a
certificate, credentials or system settings. Its later Rez/Finder metadata
additions make strict signature verification fail. The finalizer creates a new
data-fork-only copy of the private unsigned build target, signs it with that same
single public Hypervisor entitlement, and atomically replaces only the private
experiment binary. It verifies the signature and logs actual entitlements plus
input/output hashes. It does not remove attributes from other files, start a VM
or replace an installed executable. Private HVF features are disabled.

The WebKit build restricts direct linking to its GLES dylib. The smoke links EGL
and obtains GL functions via `eglGetProcAddress`, matching the intended dispatch
route, rather than changing the library's allowed-client metadata.

The subsequent [headless adapter and causal harness](../experimental/metal-headless/README.md)
are built separately with `graphics-headless.py --causality`. That development
script does start its own diskless, CPU-less QEMU callback fixture, unlike the
build stages above. It verifies exact Metal → ANGLE/PBO → DisplaySurface → VNC
pixels plus resize and teardown. Real Neptune scanouts remain rejected until
their producer-ready and buffer-reuse contract is implemented and verified.


## Fresh matched Wire1 rebuild on the current host

The archived Wire1 recipes retain exact hashes for their original experiment
binaries. Those gates still describe that historical installation. When those
artifacts are absent, use `graphics-wire1-rebuild.py` to create a fresh profile
from the same complete upstream source pins; it does not rewrite or skip the
archived recipes' gates. The selected pair is renderer `d3c970599eb0bfbfe417b86d87fc0e0641da9512`
and DXMT backend `917b721c0f915c6524b416169fdce4427a39524f`, with the original
DirectX-header pin and exact protocol/native header hashes. No wire constants,
protocol fragments or backend layouts are substituted.

First build the common ANGLE/epoxy dependencies with the existing private
builder, selecting optimization 3 explicitly, and run its Metal smoke. Then
prepare each matched source profile (these two commands do not compile):

```sh
.tools/build-venv/bin/python scripts/graphics-wire1-rebuild.py --component backend --output .tools/graphics-rebuild-backend-20261016 --source-only
.tools/build-venv/bin/python scripts/graphics-wire1-rebuild.py --component renderer --output .tools/graphics-rebuild-renderer-20261016 --source-only
```

Build sequentially, retaining the same component/output/optimization plan:

```sh
.tools/build-venv/bin/python scripts/graphics-wire1-rebuild.py --component backend --output .tools/graphics-rebuild-backend-20261016 --resume
.tools/build-venv/bin/python scripts/graphics-wire1-rebuild.py --component renderer --output .tools/graphics-rebuild-renderer-20261016 --resume
```

Use a new `.tools/graphics-rebuild-*` name for another profile; existing output
requires `--resume` and the exact recorded plan. Only optimization 2 or 3 is
accepted; 3 is the default. Meson downloads stay disabled and compilation is
limited to two jobs. Every install destination must remain inside the profile.
The source/header pins, clean source inventories, actual dependency hashes,
compile commands, compiler/SDK, binary identities and signatures are recorded
under that profile. Resume rejects changed read-only dependencies. A current
byte baseline of the installed application is checked before and after work;
it replaces no historical hash assertion and grants no VM/start permission.
Logs use distinct names for each invocation. The final `build.json` exists
only after successful compilation, private installation and verification.

Test a rebuilt backend against the matching renderer's shared-layout source:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1-backend/test.py --rebuild-backend .tools/graphics-rebuild-backend-20261016 --rebuild-renderer .tools/graphics-rebuild-renderer-20261016
```

The fixture requires a new `native-check` directory in the backend profile and
records actual loaded-library identity, GPU pixels and incompatible-version
rejection. It requires only the renderer source preparation above.

These builds do not install a runtime in the application, change drivers or
start a VM. Renderer pairing and Windows/native-client qualification are still
required before using them in the ordinary app.

## Fresh QEMU with the native publisher

Once both matched profiles have complete `build.json` receipts, build the
whole pinned QEMU in another private profile:

```sh
.tools/build-venv/bin/python scripts/graphics-qemu-rebuild.py --output .tools/graphics-rebuild-qemu-native-20261016 --renderer .tools/graphics-rebuild-renderer-20261016 --backend .tools/graphics-rebuild-backend-20261016 --source-only
.tools/build-venv/bin/python scripts/graphics-qemu-rebuild.py --output .tools/graphics-rebuild-qemu-native-20261016 --renderer .tools/graphics-rebuild-renderer-20261016 --backend .tools/graphics-rebuild-backend-20261016 --resume
```

Source preparation copies the verified whole QEMU and its populated pinned
wraps, applies the existing reversible Cocoa direct-source hooks, and adds the
publisher/transport through separate Meson libraries. Publisher Objective-C
uses ARC/blocks; original Cocoa remains MRC and transport uses C17. Compilation
uses optimization 3 and at most two jobs. Only private Slirp is installed into
this profile. The QEMU candidate is a data-fork copy signed with only the
public Hypervisor entitlement; the candidate must link the selected renderer.
Source and local implementation inventories, matched dependencies and the
installed app's file baseline are preserved. No QEMU installation or VM launch
occurs. This profile includes no historical GPU diagnostic overlay, STP/HVF
extension or HID backpressure patch; it is not ready to replace the installed
Windows runtime.

Resume requires the exact recorded recipe and input hashes. After editing a
recipe, choose a fresh profile; existing successful receipts still bind their
original Git revision. Meson's generated `subprojects/.wraplock` is excluded
from the source inventory so its creation does not invalidate an unchanged
recipe's prepared-source check.

Run the owned, paused, diskless protocol fixture separately:

```sh
.tools/build-venv/bin/python scripts/graphics-qemu-probe.py --profile .tools/graphics-rebuild-qemu-native-20261016
.tools/build-venv/bin/python scripts/graphics-qemu-probe.py --profile .tools/graphics-rebuild-qemu-native-20261016 --com
```

The COM variant uses a 4 KiB HVF IPA granule and the matching protocol's
HRESULT-only QueryInterface response. It sends actual virtqueue/ring commands
through the unmodified renderer decoder, creates two shared textures, checks a
real GPU fence and verifies red/green then magenta pixels through their mapped
storage. It records the matching server's actual descendant executable path
and loaded renderer/backend identities. It does not submit a scanout, exercise
the native publisher or execute Windows. Use `--label` with a fresh name to
retain another attempt; existing receipts are never overwritten. Full source,
dependency hashes and logs remain in the private profile; console output is a
compact result.

To include actual native scanout publication and an independent Metal reader:

```sh
.tools/build-venv/bin/python scripts/graphics-qemu-probe.py --profile .tools/graphics-rebuild-qemu-native-20261016 --native --label native-check-new
```

This compiles `experimental/cocoa-native-display/qemu-receiver.m` against the
production C transport, then exercises real decoder-created scanouts through
the existing QEMU direct-source publisher. The separate reader imports each
shared backing as a Metal linear texture, copies through its own GPU queue and
waits for GPU completion before ACK. Pixel readback is diagnostic only.
Nineteen snapshots cover repeated red/green updates, 64×32 → 803×607 → 64×32,
retained old snapshots and a second connection. The latter receives a static
image without another producer update after connect. Old unacknowledged storage
is checked again after the replacement connection receives a different image.
All reader frames/mappings must drain before exit.

The fixture explicitly waits for the actual producer GPU fence **before**
scanout/flush. It verifies this ordered case, not automatic Windows writer
ownership or multicontext synchronization. It does not show a drawable, run the
app's Swift receiver/presenter, measure presentation latency or install a
runtime. Producer backing reuse counts are not exposed by this QEMU profile.

For a causal negative, add `--withhold-native-update` and a fresh label. This
deliberately omits the first green update; the command must exit nonzero while
waiting for green. Its failed receipt and receiver log are expected evidence,
not a successful graphics result.

Select the actual app receiver and renderer instead of the independent reader:

```sh
.tools/build-venv/bin/python scripts/graphics-qemu-probe.py --profile .tools/graphics-rebuild-qemu-native-20261016 --swift-receiver --label swift-native-new
```

This implies `--native` and compiles the unchanged production
`NativeDisplayConnection`, `NativeDisplayEndpoint`, `VMDisplayPresentationQueue`
and `VMMetalRenderer` with a separate Swift command harness. Both Swift and C
transport target arm64 macOS 14. The same scanout/resize/reconnect sequence
passes through the real receiver's worker/mailbox, external leases and renderer
shader, with zero RFB uploads. Diagnostic rendering is offscreen; no MTKView,
drawable callback or installed application is exercised. Per-held-frame queues
extend lease retirement deliberately so old source textures can be re-rendered
after later producer updates and a disconnect. ACK follows completed GPU reads
and production queue retirement/reset. `--withhold-native-update` also applies
to this variant and must fail when the omitted green image never arrives.

## Matched Wire1 synchronization extension

The earlier worker/proxy synchronization experiment uses a newer native shared
descriptor. Build its separate Wire1 adaptation against the complete matched
renderer/backend profiles:

```sh
.tools/build-venv/bin/python scripts/graphics-wire1-sync-build.py --renderer .tools/graphics-rebuild-renderer-20261016 --backend .tools/graphics-rebuild-backend-20261016 --output .tools/graphics-rebuild-sync-new
```

Output must be fresh. It copies the whole selected renderer, applies the
existing unique source hooks and compiles/installs privately with at most two
jobs and optimization 3. All original dependencies, source recipes and the
installed app are hashed before/after. It uses the actual old backend's
72-byte `DMTX` v2 declaration; the old descriptor lacks Usage, so that property
is checked with the actual texture's `GetDesc`. Shared texture creation uses
the old backend's ordinary SHARED path, which is already linear. Generated
guest protocol headers remain unchanged (Wire1).

The distinct private **host extension** is version 2 and carries a 96-byte
snapshot packet. It is not interchangeable with the earlier version-1
development transport or the newer native descriptor. The existing
copy-before-Signal hook, exact owner/fence checks, increasing fence values,
bounded candidate/snapshot budgets, import rejection, multi-ring rejection,
resource generations and ACK validation are retained. This does not add
arbitrary compositor alias/multi-writer support.

Check ordinary decoder behavior with capture disabled, using a fresh label:

```sh
.tools/build-venv/bin/python scripts/graphics-qemu-probe.py --profile .tools/graphics-rebuild-qemu-native-20261016 --sync-renderer .tools/graphics-rebuild-sync-new --com --label sync-disabled-new
```

The probe verifies the selected build/plan/source inventory and actual loaded
renderer/backend/server identities. It deliberately keeps broker admission
disabled. Passing this check establishes ordinary decoder compatibility; it
does not exercise snapshot capture, remove the fixture's producer wait, or
qualify Windows. The next integration must connect the real QEMU scanout
ingress to this matching host extension and test actual Signal-driven capture
and retirement before enabling it in a Windows candidate.

## Automatic Signal-driven Wire1 scanout

Link the matching synchronization renderer into a separate QEMU overlay:

```sh
.tools/build-venv/bin/python scripts/graphics-wire1-sync-qemu.py --qemu .tools/graphics-rebuild-qemu-native-20261016 --sync-renderer .tools/graphics-rebuild-sync2-20261017 --output .tools/graphics-rebuild-sync-qemu-new
.tools/build-venv/bin/python scripts/graphics-qemu-probe.py --profile .tools/graphics-rebuild-qemu-native-20261016 --sync-qemu .tools/graphics-rebuild-sync-qemu-new --swift-receiver --label automatic-sync-new
```

The builder copies/patches only two GPU source files, compiles the native sink
against their actual QEMU recipes, and relinks a private candidate. Explicit
reused link inputs and selected original artifacts are protected by hashes;
signing grants only Hypervisor access. No runtime is installed or VM started.

Real SET_SCANOUT_BLOB/RESOURCE_FLUSH ingress selects the checked resource in
the VM-global proxy broker. The original worker's real Signal override queues
its immutable snapshot copy before Signal; the broker waits for that actual
completion descriptor. QEMU imports the ready snapshot as a Metal texture and
copies it into the existing bounded native publisher. That copy's real GPU
completion retires the worker lease on QEMU's main loop. Unsupported selections
and subsequent flushes are consumed as rejection, without re-entering the old
unfenced update path. Per-frame Cocoa drawable acquisition, PBO and CPU pixel
readback are absent from this sink. Cocoa/ANGLE initialization still exists in
the base candidate.

The automatic probe uses decoder/control admission round trips but performs no
producer fence-value wait for native publication. Before its first consumer
connects, it overwrites and verifies both original textures as magenta: the
later red result must come from the earlier immutable worker snapshot. Then
the ordinary Swift reader/renderer runs the same updates, resize and reconnect.
It waits for asynchronous producer teardown before recording drained counters,
and rejects an anonymous scanout with no checked writer/export identity.

For the readiness negative, add `--withhold-producer-token` and a fresh label.
The real copy/Signal and checked original overwrite complete, while the worker
token remains withheld. This command must fail before its first native frame;
the broker must report a producer-completion timeout. The failed receipt is
expected safety evidence, not a passing graphics result.

This development path currently makes **two GPU copies** (worker snapshot and
native publication). It retains the single-writer, bounded export and import/
multi-ring rejection guards; arbitrary compositor aliasing is unsupported.
Reconnection is tested with an image produced while disconnected, not every
static reconnect case. This is not Windows, visible drawable, shutdown-under-
pending-GPU, latency/FPS or installed-app qualification.
