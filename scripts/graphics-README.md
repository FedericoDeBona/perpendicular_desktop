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
