# Windows ARM graphics: evidence and isolated experiment

## Latest Windows and host checkpoints — 2026-10-15

The installed native console now presents its RFB frames with Metal; a live
completed-frame diagnostic confirms the actual GPU path. A separate Windows
clone booted the pinned fork with hybrid `virtio-ramfb` at PCI slot 7. Windows
validated and loaded the official ARM64 Red Hat DOD package, reports device
error 0, and independently measured successful active-mode changes to
**1920×1080** and **1920×1200**. Secure Boot still reports `True`. An unsupported
1280×720 mode was refused without changing the display. This is a 2D
display-only driver. Hardware 3D and actual automatic window fitting remain
unfinished; Guest Tools still cannot connect as the limited desktop user.
The native sizing controller and bounded protocol are implemented and tested,
but require a working guest channel. [Runtime evidence and remaining gates](VERIFICATION.md).

The Xcode/Metal dependency below is now resolved: Xcode 27.0 and Apple's Metal
toolchain are verified locally, and official Homebrew LLVM 15.0.7 static
libraries/headers were hash-verified and extracted privately. Pinned ANGLE,
libepoxy, native DXMT, Neptune/virglrenderer and QEMU 10.0.12 have built under
`.tools/graphics-experiment` with at most two compiler jobs and functional
optimization level 0. The QEMU private copy passes strict signature verification
with only the public Hypervisor entitlement, and `--version` succeeds. The
packaged runtime and live VM were not replaced or reconfigured by this work.

The host-only Metal → ANGLE EGLImage → ES3 framebuffer → pixel-pack-buffer → CPU
test passes **16 trials / 14,084,084 exact pixel comparisons**: private and shared
linear textures, surfaceless and pbuffer contexts, growth/shrinkage through
800×600 → 1920×1080 → 803×607 → 800×600, BGRA/RGBA colors and constant top-row
orientation. The direct CPU readback route crashed on private textures; the
verified PBO route needs no ANGLE source patch. This uses a completed producer
and same-process buffers: it does not test render-server IPC, live guest fences,
or an accelerated Windows desktop. No graphics performance measurement is
claimed, and these host builds do not establish macOS 14 runtime compatibility.

See the [repeatable fetch/build instructions and actual limits](../scripts/graphics-README.md)
and [immutable source/dependency lock](../scripts/graphics-sources.json).
**Guest 3D acceleration and its integration into the native VNC console remain
unverified.** A separate macOS headless QEMU adapter now
passes its real diskless/CPU-less callback harness: **4,616,442 exact pixels**
through Metal → ANGLE/PBO → bounded DisplaySurface → Unix VNC, including crop,
resize, missing/delayed producer proof, timeout and exact native-handle teardown.
Two deliberately broken variants fail for their expected thread-handoff and
color-conversion causes. See the [implementation, repeatable command and limits](../experimental/metal-headless/README.md).
The existing base experiment binaries and pinned source trees remain unchanged.
This synthetic producer supplies an explicit ready event and immutable read
lease; actual Neptune handle-only frames remain rejected. The next step is to
prove and bridge the real renderer's producer completion and buffer-reuse
contract before an accelerated guest-driver experiment. No fluidity result is claimed.

A separate real DXMT producer and ANGLE consumer now pass an ordered snapshot
test across Unix descriptor transfer: **7,042,042 exact snapshot pixels** and
the same number of independently verified overwrite pixels. Copy-before-Signal
and ACK-after-read preserve the snapshot even when the original texture is
reused; a withheld Signal is rejected before reading. This proves the identified
single-producer primitive, while actual Neptune resource ownership and RPC
integration remain unfinished. See [the test and source evidence](../experimental/producer-sync/README.md)
and [the paused HVF/TPM/PCI checks and Windows trial plan](../experimental/producer-sync/COMPATIBILITY.md).

The real Neptune decoder now drives that snapshot path through unchanged
QEMU/VNC in a closed host fixture: **7,042,042 exact pixels**, verified original
buffer reuse, missing-token rejection and ownership/ACK guards. A further
versioned broker exercises actual render workers and asynchronous Neptune rings,
including control/export reordering, producer death, worker restart, stale ACKs
and real imports. It still uses a development supervisor and rejects compositor
resources with ambiguous writers; the full proxy/server and actual QEMU scanout
association remain the next integration gates. These are functional ownership
and pixel results, with no Windows 3D or fluidity claim. See
[decoder integration](../experimental/neptune-snapshot/README.md) and
[worker broker](../experimental/neptune-broker/README.md).

The [REA inspection of the installed Parallels executable](PARALLELS_GRAPHICS_REA.md)
records static Metal/IOSurface/display-link imports and explicit analysis limits.
It supplies no recovered guest GPU protocol or runtime performance claim.

## Earlier source inspection and capability checks

The research below preserves the earlier observations and proposals. Statements
such as “Xcode pending” and “proposal not executed” describe that earlier stage;
the host checkpoint above records the work completed since then.

Research snapshot: 2026-10-15. This document records source inspection and local capability checks. **Windows GPU acceleration has not been demonstrated in Perpendicular Desktop.** No graphics driver was installed and no running VM, firmware setting, security policy, or engine configuration was changed for this research.

## Current working display

The packaged QEMU 11.1.2 is built with VNC, without OpenGL or Cocoa. Its display list is `none`, `curses`, `dbus`; its graphics devices include `ramfb` and the ordinary 2D `virtio-gpu` devices, but no GL or rutabaga variant. The engine selects `-display none -vga none -device ramfb`. HVF accelerates the guest CPU; it does not establish GPU acceleration.

RAMFB exposes guest memory configured through `fw_cfg` as a display surface. It is useful before a guest graphics driver takes over, but has no runtime `ui_info` resolution callback. The native application receives raw pixels over a private Unix VNC socket and scales them to its view. A real 800×600 boot framebuffer was compared against QMP `screendump`: all 1,440,000 RGB bytes matched. That verifies the current 2D transport and orientation, not a GPU renderer. See the [RAMFB implementation](https://github.com/qemu/qemu/blob/v11.1.2/hw/display/ramfb.c) and the local capture harness in `macos/Tests/`.

The existing driver media contains `Drivers/viogpudo/w11/ARM64`: a signed-package candidate for the Red Hat VirtIO GPU **display-only** driver, version 22.7.38.43 (INF date 2025-04-18). The SYS is ARM64. Upstream initializes a display-only WDDM driver through `DxgkInitializeDisplayOnlyDriver`; this is not a Direct3D user-mode driver. Its presence on the ISO does not mean it has been installed or tested with this VM. [Driver source](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/c962dba85897b54da0060bcfa80f1b45e163a970/viogpu/viogpudo/driver.cpp), [Windows 11 ARM64 packaging](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/c962dba85897b54da0060bcfa80f1b45e163a970/win11_arm64.ddf).

## Resolution changes

There are three separate behaviors: scaling a host view, accepting a guest mode change, and asking Windows to select a new mode. Today the console handles incoming RFB `DesktopSize` and rescales its image; resizing the Mac window does not request a new Windows resolution.

QEMU's VNC server accepts RFB `SetDesktopSize` (message 251), passes width/height through `QemuUIInfo` when the device supports it, and reports an `ExtendedDesktopSize` response. VirtIO GPU updates its requested display state and signals `VIRTIO_GPU_EVENT_DISPLAY`. A complete implementation therefore needs console negotiation of `ExtendedDesktopSize` (-308), bounded/debounced requests, device support, and a working Windows mode-selection path. RAMFB alone cannot supply the device part. [VNC implementation](https://github.com/qemu/qemu/blob/v11.1.2/ui/vnc.c), [VirtIO GPU callback](https://github.com/qemu/qemu/blob/v11.1.2/hw/display/virtio-gpu-base.c).

Current upstream Windows `viogpuap` handles a driver escape plus `QueryDisplayConfig`/`SetDisplayConfig` to apply modes. The bundled 2025 Windows 11 ARM64 DOD directory contains only CAT/INF/SYS; its Windows Server 2025 ARM64 sibling contains the helper executables. Do not silently transplant those executables or assume current upstream source describes that older package. First verify guest-selected 1280×720 and 1920×1080 modes on a disposable VM, then add and test host-requested resize. [Windows helper source](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/c962dba85897b54da0060bcfa80f1b45e163a970/viogpu/viogpuap/GpuAdapter.cpp).

## Candidate 3D paths

| Path | What primary sources establish | Consequence here |
| --- | --- | --- |
| VirGL | Mesa guest OpenGL commands are rendered by host virglrenderer. Mesa's generic VirGL page still lists Windows/Direct3D support as future work. | Enabling ordinary VirGL is insufficient for a Windows D3D driver. [Mesa](https://docs.mesa3d.org/drivers/virgl.html) |
| Venus | Vulkan virtualization with specific guest/host memory-sharing requirements; upstream documents Linux/Android hosts. | UTM has macOS patches, but this is a separate experimental Vulkan route, not proof of Windows D3D11. [Mesa](https://docs.mesa3d.org/drivers/venus.html) |
| Rutabaga / gfxstream | Rust graphics transport and render backends; QEMU documents their capsets. gfxstream's documented builds target Android/Linux stacks. | Rewriting the VM manager in Rust does not provide Windows WDDM or translate D3D to Metal. [QEMU](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html), [rutabaga](https://crosvm.dev/doc/rutabaga_gfx/index.html), [gfxstream](https://github.com/google/gfxstream) |
| Triton / Neptune / native DXMT | A Windows ARM64X driver release and host forks for D3D11 virtualization to Metal now exist. | This is the concrete candidate for a private experiment. Compatibility and native-console integration remain to be measured. [UTM announcement](https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/), [driver v0.3](https://github.com/osy/kvm-guest-drivers-windows/releases/tag/v0.3) |

### Signed guest package, without changing Secure Boot

The v0.3 release (2026-09-01) supplies `viogpu3d-arm64x-signed.zip`, 2,117,369 bytes. Its GitHub asset digest and locally calculated SHA-256 agree:

```text
af976d1fc6cbd1c8462ba06a45f860ae1638d9a6a007e2bfe95bb9b235251c5d
```

The inspected package contains `viogpu3d.sys`, CAT/INF, Neptune ARM64/ARM64EC/x86 UMD components, Vulkan components, and the mode helpers. INF version is 100.6.101.58000 (2026-08-30), with an ARM64 installation section. The catalog embeds a Microsoft Windows Hardware Compatibility Publisher certificate issued by Microsoft Windows Third Party Component CA 2014. The SYS also embeds a Turing Software LLC EV signature. **Certificate presence is not a Windows trust-chain, catalog-membership, HVCI, or driver-load test.** [Exact release source](https://github.com/osy/kvm-guest-drivers-windows/tree/769e75cd645fc48f4aaae716ca8a74795fe5e241), [release asset](https://github.com/osy/kvm-guest-drivers-windows/releases/tag/v0.3).

The source build instructions discuss test-signing locally built drivers. That does not require enabling test mode for the separate published signed asset. In the future disposable guest, record `Confirm-SecureBootUEFI`, `Get-Tpm`, and `bcdedit /enum '{current}'` before and after. Validate the CAT with `Get-AuthenticodeSignature`; with the Windows SDK available, verify membership and kernel policy explicitly:

```powershell
signtool verify /kp /v /c viogpu3d.cat viogpu3d.sys
signtool verify /kp /v /c viogpu3d.cat viogpu3d.inf
```

Only a successful install, reboot, working display device, and clean relevant Code Integrity events on unchanged security settings establish that the driver loads. If it is rejected, stop and record the error. Do not enable `testsigning`/`nointegritychecks`, disable Secure Boot/HVCI, or import a test certificate to pass this experiment. Microsoft distinguishes signature acceptance from compatibility testing; the observed catalog does not prove WHQL/HLK certification. [Guest build instructions](https://github.com/osy/kvm-guest-drivers-windows/blob/769e75cd645fc48f4aaae716ca8a74795fe5e241/viogpu/viogpu3d/BUILDING.md), [Microsoft verification](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/signtool), [signing offerings](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings).

## Host sources, libraries, and licenses

These are immutable **research pins**, resolved from the branches named by UTM. No release lockfile was found tying v0.3 to this exact set. They are a reproducible candidate, not a known-good host/guest compatibility manifest. The QEMU fork reports version 10.0.12, so it is not a replacement build of our current 11.1.2.

| Component / source | Candidate revision | Role and source license |
| --- | --- | --- |
| [utmapp/qemu, utm-edition](https://github.com/utmapp/qemu/tree/88e5ee7ec6703662fec7b638cca74c4769e683d6) | `88e5ee7ec6703662fec7b638cca74c4769e683d6` | Neptune device/capset, native Metal scanout, RAMFB hybrid. [GPLv2, with per-file licenses](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/COPYING). |
| [utmapp/virglrenderer, macos-next](https://github.com/utmapp/virglrenderer/tree/e83b630ea14c9e8be33955462c80272f44927031) | `e83b630ea14c9e8be33955462c80272f44927031` | Neptune decoder, process render server, native shared textures. [MIT](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/COPYING). |
| [utmapp/dxmt](https://github.com/utmapp/dxmt/tree/2a7dd3e7d22541611433441b82894ec5bca75ca2) | `2a7dd3e7d22541611433441b82894ec5bca75ca2` | Native ARM64 `libdxmt-native.dylib`, D3D11→Metal. [LGPL-2.1-or-later](https://github.com/utmapp/dxmt/blob/2a7dd3e7d22541611433441b82894ec5bca75ca2/LICENSE). |
| [utmapp/libepoxy, macos-venus](https://github.com/utmapp/libepoxy/tree/15d904dcb1d5a8d626ffe11e8f3339499d6f7b09) | `15d904dcb1d5a8d626ffe11e8f3339499d6f7b09` | EGL/GL dispatch. [MIT](https://github.com/utmapp/libepoxy/blob/15d904dcb1d5a8d626ffe11e8f3339499d6f7b09/COPYING). |
| [utmapp/WebKit ANGLE subtree](https://github.com/utmapp/WebKit/tree/6a7f464047e2f6f2b65fe315aaad5d1ff3229cb7/Source/ThirdParty/ANGLE) | `6a7f464047e2f6f2b65fe315aaad5d1ff3229cb7` | EGL/OpenGL ES over Metal, shared Metal device. [BSD 3-clause](https://github.com/utmapp/WebKit/blob/6a7f464047e2f6f2b65fe315aaad5d1ff3229cb7/Source/ThirdParty/ANGLE/LICENSE), retain bundled third-party notices. |
| [osy/directx-native](https://github.com/osy/directx-native/tree/52fb0875e5717119becd89e7c4f258321aeec427) | `52fb0875e5717119becd89e7c4f258321aeec427` | Shared-resource/event ABI; both DXMT and renderer wrap files pin this revision. [Apache-2.0](https://github.com/osy/directx-native/blob/52fb0875e5717119becd89e7c4f258321aeec427/LICENSE). |
| [LLVM 15.0.7](https://github.com/llvm/llvm-project/tree/8dfdcc7b7bf66834a761bd8de445840ef68e4d1a) | `8dfdcc7b7bf66834a761bd8de445840ef68e4d1a` | Build-time headers/static libraries for DXMT shader translation; [Apache-2.0 with LLVM exceptions and per-file notices](https://github.com/llvm/llvm-project/blob/8dfdcc7b7bf66834a761bd8de445840ef68e4d1a/llvm/LICENSE.TXT). |

The guest KMD has BSD-licensed source files; its Mesa UMD has Mesa's per-file license mix, predominantly MIT. Preserve each component's notices and corresponding-source obligations when distributing a private build later. A source license is not a claim about every bundled binary's provenance. [KMD source header](https://github.com/osy/kvm-guest-drivers-windows/blob/769e75cd645fc48f4aaae716ca8a74795fe5e241/viogpu/viogpu3d/driver.cpp), [Mesa license explanation](https://github.com/osy/virtio-win-mesa/blob/neptune/docs/license.rst).

Existing QEMU dependencies (GLib, Pixman, libslirp, compression/crypto libraries and their transitive dependencies) still need their own build manifest/notices; they are not replaced by this table. Native DXMT avoids the optional proprietary D3DMetal framework and its x86_64/Rosetta worker. Venus/MoltenVK and D3D12 are excluded from the first experiment. The pinned DXMT source has a separate disabled-by-default D3D12 build option; no D3D12 result is claimed. [Native library build](https://github.com/utmapp/dxmt/blob/2a7dd3e7d22541611433441b82894ec5bca75ca2/src/dxmt-native/meson.build), [renderer backend loading and ABI check](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/src/neptune/npt_library.c).

### Toolchain availability on this Mac

Local checks found only `/Library/Developer/CommandLineTools`; `xcrun --find metal` fails. Spotlight's `com.apple.dt.Xcode` search returned no application, and direct checks found no Xcode under `/Applications` or `~/Applications`, no user/system `Developer/Toolchains`, and no installed Metal toolchain asset in the standard location. LLVM 15 was not found at Homebrew's standard prefix. The repository already has a Meson/Ninja build environment, so their absence from the general PATH is not a blocker by itself.

DXMT documents Xcode 16+ with Metal tools, ARM64 LLVM **15** headers/static libraries, macOS Sonoma+, Meson 1.3+, and CMake 3.27+ if building LLVM. This Mac's OS is new enough; the Metal/LLVM prerequisites remain unresolved at these checks. The coordinating task subsequently started the official App Store Xcode 27 download; completion, Metal tool availability and compatibility with these pins have not yet been verified. This graphics research did not install tools or access an account. [Pinned prerequisites and native build](https://github.com/utmapp/dxmt/blob/2a7dd3e7d22541611433441b82894ec5bca75ca2/docs/DEVELOPMENT.md).

There are no GitHub Releases in the [UTM DXMT fork](https://github.com/utmapp/dxmt/releases) or [UTM WebKit/ANGLE fork](https://github.com/utmapp/WebKit/releases) at this snapshot. DXMT's CI defines an ARM64 native artifact, but it is not a durable release asset. Upstream 3Shain v0.80 supplies a Wine-oriented archive (SHA-256 `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`); it does not establish compatibility with UTM's native Neptune ABI and is not a substitute for the pinned fork. [Fork CI](https://github.com/utmapp/dxmt/blob/2a7dd3e7d22541611433441b82894ec5bca75ca2/.github/workflows/ci.yml), [upstream release](https://github.com/3Shain/dxmt/releases/tag/v0.80). No Parallels binary is needed or proposed.

## Proposed private build, after prerequisites are available

Use a new directory outside `.tools/qemu` and the installed application. All commands below are a **proposal, not executed or build-validated**. Run a native ARM64 shell, point `DEVELOPER_DIR` at the explicitly selected full Xcode without changing `xcode-select`, and confirm both `xcrun --find metal` and `xcrun --find metallib` first. Let `GFX_ROOT` be a fresh private experiment directory, `GFX_PREFIX="$GFX_ROOT/prefix"`, `GFX_SRC="$GFX_ROOT/src"`, and `GFX_LLVM15` the native LLVM 15 installation. Check out the exact source pins above and their recorded git submodules; capture `git submodule status --recursive` in the build manifest.

1. Sparse-checkout the ANGLE repository paths `Source/ThirdParty/ANGLE`, `Configurations`, `Tools/ccache` at the pinned revision. Build the ARM64 macOS archive below; verify its EGL/GLES dylibs with `file` and `otool -L`.
2. Build the pinned epoxy, DXMT, then renderer into the private prefix. Populate each DXMT/renderer `subprojects/directx-native` from the fixed HTTPS repository/revision above before Meson; the original wrap uses SSH, so prepopulating avoids an implicit SSH-account requirement. Use `--wrap-mode=nodownload` to reveal any other missing dependency rather than fetching an unrecorded version.
3. Configure the pinned QEMU with explicit Cocoa/OpenGL/virgl/HVF/VNC/TPM support. Preserve its dependency/configure logs and check native-scanout detection. Sign only this private QEMU executable with the project's existing Hypervisor entitlement for local HVF use.

```sh
# Working directory: the pinned ANGLE subtree.
xcodebuild -scheme ANGLE -configuration Release -sdk macosx -arch arm64 \
  -archivePath "$GFX_PREFIX/ANGLE" archive CODE_SIGNING_ALLOWED=NO \
  WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR="" \
  MACOSX_DEPLOYMENT_TARGET=11.0

GFX_ANGLE_HEADERS="$GFX_SRC/WebKit/Source/ThirdParty/ANGLE/include"
GFX_ANGLE_LIB="$GFX_PREFIX/ANGLE.xcarchive/Products/usr/local/lib"
export PKG_CONFIG_PATH="$GFX_PREFIX/lib/pkgconfig"
export DYLD_FALLBACK_LIBRARY_PATH="$GFX_PREFIX/lib:$GFX_ANGLE_LIB"

meson setup "$GFX_ROOT/build-epoxy" "$GFX_SRC/libepoxy" \
  --prefix="$GFX_PREFIX" --libdir=lib --wrap-mode=nodownload \
  "-Dc_args=-I$GFX_ANGLE_HEADERS" -Degl=yes -Dglx=no -Dx11=false -Dtests=false
meson install -C "$GFX_ROOT/build-epoxy"
meson setup "$GFX_ROOT/build-dxmt" "$GFX_SRC/dxmt" \
  --prefix="$GFX_PREFIX" --libdir=lib --buildtype=release --wrap-mode=nodownload \
  "-Dnative_llvm_path=$GFX_LLVM15" -Denable_d3d12=false
meson install -C "$GFX_ROOT/build-dxmt"
meson setup "$GFX_ROOT/build-renderer" "$GFX_SRC/virglrenderer" \
  --prefix="$GFX_PREFIX" --libdir=lib --buildtype=release --wrap-mode=nodownload \
  "-Dc_args=-I$GFX_ANGLE_HEADERS" -Dplatforms=egl \
  -Dneptune=true -Dvenus=false -Dvtest=false -Drender-server-mode=process \
  -Drender-server-worker=process -Dcheck-gl-errors=false
meson install -C "$GFX_ROOT/build-renderer"

# Working directory: a fresh out-of-tree QEMU build directory.
"$GFX_SRC/qemu/configure" --prefix="$GFX_PREFIX" --target-list=aarch64-softmmu \
  "--extra-cflags=-I$GFX_ANGLE_HEADERS" "--extra-ldflags=-L$GFX_ANGLE_LIB" \
  --enable-hvf --enable-vnc --enable-tpm --enable-slirp --enable-cocoa \
  --enable-opengl --enable-virglrenderer --disable-docs --disable-gtk --disable-sdl \
  --disable-pvg
ninja
ninja install
```

These options follow the pinned [epoxy options](https://github.com/utmapp/libepoxy/blob/15d904dcb1d5a8d626ffe11e8f3339499d6f7b09/meson_options.txt), [renderer options](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/meson_options.txt), [renderer Darwin dependencies](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/meson.build), and [QEMU options](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/meson_options.txt). Reject an ARM64/x86_64 mixture. The renderer and DXMT must report matching directx-native ABI versions. Hash all resulting executables/libraries and preserve actual compiler/SDK/dependency versions before treating this as reproducible.

Before booting any guest, inspect this private QEMU's `-display help`, `-device help`, `-device virtio-ramfb-gl,help`, `-device tpm-tis-device,help`, and `-accel help`. Required graphics properties are `hostmem`, `blob`, and `neptune`. The fork's hybrid `virtio-ramfb-gl` retains firmware RAMFB until the VirtIO GPU becomes active and forwards the GPU's resolution callback; it avoids requiring the firmware's VirtIO GOP to be the only boot display. [Hybrid device source](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/hw/display/virtio-ramfb.c).

For the first graphical guest experiment, create a separate disposable VM from a **stopped**, owned Windows installation or install a fresh one. Give it separate disk, EFI-variable and TPM-state files, UUID, runtime directory, QMP and VNC sockets. Do not open the live VM's writable files with another QEMU. Verify the full hardware/firmware command against this older fork first: for example its TPM device does not expose our 11.1.2 `ppi=off` property. Do not drop TPM or Secure Boot merely to make the older command parse.

The graphics change to that independently validated launch is:

```text
-vga none
-device virtio-ramfb-gl,hostmem=8G,blob=true,neptune=true
-display cocoa,gl=es
```

Set the environment for this process only:

```sh
export NPT_BACKEND=dxmt
export NPT_D3D11_LIBRARY_PATH="$GFX_PREFIX/lib/libdxmt-native.dylib"
export NPT_DXGI_LIBRARY_PATH="$GFX_PREFIX/lib/libdxmt-native.dylib"
export RENDER_SERVER_EXEC_PATH="$GFX_PREFIX/libexec/virgl_render_server"
export ANGLE_DEFAULT_PLATFORM=metal
```

`DYLD_FALLBACK_LIBRARY_PATH` remains the private value above. This chooses a native ARM64 worker and open-source backend. Venus is deliberately off; do not add its 4 KiB HVF granule/MoltenVK requirements to a Neptune-only trial without evidence they are required. Install only the verified released ARM64X package inside this disposable guest when that experiment is separately undertaken. First prove the driver and a D3D11 hardware-adapter triangle in QEMU's Cocoa window. A DirectX version in `dxdiag`, a smooth desktop, WARP/software rendering, or successful DLL loading alone is insufficient.

## Keeping the native console: feasible API route, still unimplemented

The inspected Cocoa GL backend accepts only its own GL listener; VNC is a 2D listener. Its Metal path blits the guest texture into a `CAMetalLayer`, not into the CPU `DisplaySurface` consumed by VNC. Adding `-vnc` to the Cocoa command therefore does not prove an accelerated native console. Linux `egl-headless` does read back to a display surface, but its build requires GBM and its scanout code assumes a GL texture. This macOS fork does not establish a GBM-backed headless configuration. [Cocoa listener and presentation](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/ui/cocoa.m), [headless implementation](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/ui/egl-headless.c), [UI build conditions](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/ui/meson.build).

A small **new macOS backend** is supported by the following source-level building blocks, rather than by assuming Linux EGL works unchanged:

1. ANGLE's Metal `DisplayMtl` enables surfaceless contexts and PBUFFER configurations. Initialize an EGL display explicitly on the Metal backend; use a surfaceless ES context or a tiny pbuffer fallback, without `CAMetalLayer`/GBM. QEMU's Darwin EGL initialization already discovers the ANGLE `MTLDevice`, which the renderer uses for native sharing. [ANGLE implementation](https://github.com/utmapp/WebKit/blob/6a7f464047e2f6f2b65fe315aaad5d1ff3229cb7/Source/ThirdParty/ANGLE/src/libANGLE/renderer/metal/DisplayMtl.mm), [QEMU EGL initialization](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/ui/egl-helpers.c).
2. The GPU's native blob scanout can supply `SCANOUT_TEXTURE_NATIVE_TYPE_METAL` with **GL backing ID 0**. Import that `id<MTLTexture>` with `eglCreateImageKHR(..., EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, ...)`, then bind the image to an ES texture using `glEGLImageTargetTexture2DOES` and attach/blit to an FBO. Require the texture's Metal device to match ANGLE and reject unsupported formats. Merely feeding ID 0 to existing `egl-headless` would lose the native scanout. [QEMU native scanout](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/hw/display/virtio-gpu-virgl.c), [ANGLE extension contract](https://github.com/utmapp/WebKit/blob/6a7f464047e2f6f2b65fe315aaad5d1ff3229cb7/Source/ThirdParty/ANGLE/extensions/EGL_ANGLE_metal_texture_client_buffer.txt), [actual import validation](https://github.com/utmapp/WebKit/blob/6a7f464047e2f6f2b65fe315aaad5d1ff3229cb7/Source/ThirdParty/ANGLE/src/libANGLE/renderer/metal/ImageMtl.mm).
3. On scanout flush, make a bounded, correctly oriented BGRA/RGBA CPU snapshot into a `PIXMAN_x8r8g8b8` surface, then call `dpy_gfx_replace_surface` on size changes and `dpy_gfx_update` for new pixels. QEMU already implements `glReadPixels` into such surfaces. Check the actual ES read format/type and convert if BGRA readback is unsupported; honor crop, stride, alpha, color space and top/bottom origin. Register compatibility with 2D listeners only because the backend now provides their pixels. [Readback helper](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/ui/egl-helpers.c), [display dispatch](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/ui/console.c).
4. Prove producer/consumer synchronization before trusting the image. The Cocoa code documents that flip-model guest buffers may be reused after the next flip and initiates its read at flush. Retaining a texture alone does not freeze its contents. Start with synchronous flush/readback and at most one frame in flight; explicitly resolve cross-queue Metal/DXMT ordering, completion and scanout replacement/reset lifetime. If those guarantees are absent, add an explicit fence/snapshot protocol instead of deferring arbitrary reads to a timer. This remains an implementation/test gap, not an established API guarantee.

The first independent backend test should create a Metal texture on ANGLE's queried device, draw four labeled color quadrants, import it, read back, and compare every pixel at 800×600 and 1920×1080. Test surfaceless and pbuffer paths, crop/flip/resize, unsupported format/device, teardown while a frame is pending, and bounded allocations. Only after that passes should the backend be attached to Neptune's real scanout and the existing Unix VNC transport. The current `capture-console.sh` and `CompareConsoleFrame.py` can compare our actual `VMConsoleView` with a read-only QMP screenshot.

This keeps an achievable CPU-copy display path for the native app, with a measurable cost: full 1080p BGRA readback is about 8.3 MB per frame, before VNC copies and transmission. Measure actual readback latency, CPU use, sustained frame rate, memory, and frame correctness; do not infer them from the earlier raw-VNC microbenchmark. A later shared Metal/IOSurface transport could avoid copies, but requires a separate lifecycle/security design.

## Acceptance gates and next step

The next concrete step is to resolve the full Xcode/Metal and native LLVM 15 toolchain, then build the pinned stack in a private prefix and run the **host-only ANGLE Metal import/readback test**. This can fail early without installing a guest driver or touching the active VM. A successful source build is not an acceleration result.

Subsequent isolated guest acceptance requires: unchanged Secure Boot/TPM/HVCI and no test mode; successful signed driver load/reboot; 2D and resolution handoff without a black screen; D3D11 hardware adapter rendering a known scene with corresponding Metal GPU work (not WARP); repeated resize/reboot/stop-start checks; and finally exact colors/orientation plus stable updates in `VMConsoleView` through the new readback backend. External Cocoa rendering and integrated-console rendering are separate gates. Until these pass, GPU acceleration and automatic Windows resolution remain experimental proposals.
