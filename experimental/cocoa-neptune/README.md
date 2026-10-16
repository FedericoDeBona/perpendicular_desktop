# Cocoa-only Neptune configuration checkpoint

This checkpoint tests the existing private QEMU **10.0.12** graphics candidate,
not the normal QEMU11 runtime or the separate `neptune-live` overlay. It builds
no dependencies and changes no firmware, Windows disk, TPM state, app bundle or
stable runtime. The fixture owns its paused diskless QEMU, temporary TPM and
renderer children; it closes only those processes.

The pinned candidate is
`.tools/graphics-experiment/prefix/bin/qemu-system-aarch64`, SHA-256:

```text
8d4d5ec3f94f7f8117568a2fbf426499e71636c2b0af3f5854adf19a33e94981
```

## Observed configuration and limits

The working path uses public HVF, `-display cocoa,gl=es` and the existing
`virtio-ramfb-gl` device at PCI7 with
`disable-legacy=on,neptune=on,blob=on,hostmem=256M`. `gl=es` selects ANGLE's
Metal EGL device in this Cocoa implementation. `gl=on` instead selects CGL;
that also passed the memory-level texture fixture, but is not the chosen path.

The working environment is confined to the launched QEMU and its children:

```text
DYLD_FALLBACK_LIBRARY_PATH=PREFIX/lib:PREFIX/ANGLE.xcarchive/Products/usr/local/lib
ANGLE_DEFAULT_PLATFORM=metal
NPT_BACKEND=dxmt
RENDER_SERVER_EXEC_PATH=PREFIX/libexec/virgl_render_server
NPT_D3D11_LIBRARY_PATH=PREFIX/lib/libdxmt-native.dylib
NPT_DXGI_LIBRARY_PATH=PREFIX/lib/libdxmt-native.dylib
NPT_D3D12_LIBRARY_PATH=PREFIX/lib/libdxmt-native.dylib
DXMT_LOG_PATH=PRIVATE_TRIAL/dxmt
```

`PREFIX` is the existing private graphics prefix. A second successful run
without the three explicit D3D overrides established that the native ARM64
defaults locate the same library. The wrapper fixes these paths to prevent
inherited overrides. It does not need `DYLD_LIBRARY_PATH`. `NPT_BACKEND=dxmt`
also controls advertised backend capabilities; the Darwin default has different
capabilities. No D3D12 support is implied by the override name: the observed
Neptune capset is wire version2, flags `0xb6`, with D3D12 and DXIL clear.

QEMU's real renderer proxy/server/worker and Neptune command decoder created
two 64×64 D3D11 render targets. Their real mapped texture storage contained
**8192 exact red/green pixels** after a real fence/flush. The same device
accepted `SET_SCANOUT_BLOB` and `RESOURCE_FLUSH`. The loader trace identifies
the prefix's virglrenderer, ANGLE EGL/GLES, renderer-server child and DXMT dylib.
This does **not** verify the final Cocoa drawable's pixels, a Windows driver,
guest CPU/cache ordering, composition, frames per second or latency.

With HVF enabled, QMP reported `prelaunch` throughout: no guest CPU instructions,
firmware payload or guest disk were used. Startup with `highmem=on` also passed.
The qtest queue driver uses low ECAM (`highmem=off`) for rendering. These results
exclude an unconditional HVF/device initialization failure in this scope; they
do not prove Windows can boot or render under HVF with this configuration.

Three real negative configurations exited1 before QMP readiness:

| Configuration | Actual diagnostic |
| --- | --- |
| Cocoa ES plus the engine's Unix VNC endpoint | `Display vnc is incompatible with the GL context` |
| Cocoa `gl=off` | `The display backend does not have OpenGL support enabled` |
| Fork10 TPM with `ppi=off` | `Property 'tpm-tis-device.ppi' not found` |

The fork's `tpm-tis-device` has no PPI property or PPI memory region. Omitting
only that unsupported option starts a real TPM2 backend successfully; it does
not establish Windows TPM health or change the existing TPM's security state.
The private wrapper preserves the TPM device and existing cloned state.

## Repeat the diskless fixture

Use fresh labels; existing result directories are refused. A real short-lived
Cocoa window can appear. Do not run while another task needs uninterrupted UI.

```sh
.tools/build-venv/bin/python experimental/cocoa-neptune/probe.py \
  --label repeat-hvf-es-render --tpm --render --fallback-only --explicit-d3d
.tools/build-venv/bin/python experimental/cocoa-neptune/probe.py \
  --label repeat-highmem-startup --tpm --highmem on --fallback-only --explicit-d3d
```

Expected negative commands return1 rather than simulating success:

```sh
.tools/build-venv/bin/python experimental/cocoa-neptune/probe.py \
  --label repeat-vnc-negative --tpm --vnc --fallback-only
.tools/build-venv/bin/python experimental/cocoa-neptune/probe.py \
  --label repeat-ppi-negative --tpm --ppi-off --fallback-only
.tools/build-venv/bin/python experimental/cocoa-neptune/probe.py \
  --label repeat-gl-negative --tpm --gl off --fallback-only
```

Results, exact commands, selected environment, loader lines and log tails live
under `.tools/graphics-experiment/build/cocoa-neptune/LABEL`. `checkpoint.json`
binds the retained receipts by hash. `DYLD_PRINT_LIBRARIES=1` is used only in
these owned fixtures, not in the Windows trial wrapper.

## Explicit stopped-clone preparation

`prepare-trial.py` is an independent helper, not the earlier private2D wrapper.
It accepts only clone `12755108-83c6-4790-b477-58ca87b1a00e`, with protected
source `7fc97463-74e6-478c-ba3d-a8e21afc7433`. It checks store ownership, both
stopped supervisors, independent flat qcow2/EFI/TPM files, the exact current
configurations, read-only media identities, fixed graphics binary/library hashes,
and the real swtpm executable. It writes only a fresh private wrapper directory.
Preparation never starts QEMU, swtpm or Windows and never opens QMP.

```sh
.tools/build-venv/bin/python experimental/cocoa-neptune/test-trial.py
.tools/build-venv/bin/python experimental/cocoa-neptune/prepare-trial.py \
  12755108-83c6-4790-b477-58ca87b1a00e \
  --data-dir '/Users/federico/Library/Application Support/Perpendicular Desktop'
```

The actual stopped clone was bound after the coordinating task completed its
baseline/media update. The helper, generated wrapper and private manifest are
frozen; editing the helper invalidates the prepared wrapper. The generated
wrapper forwards only exact `--version` and `-device help` metadata probes to
the real binary. Both exited0 and produced byte-for-byte identical stdout/stderr
to direct binary probes; the device list includes the hybrid and GL devices.
Other arguments must match the complete fixed engine launch contract, current
config/owner/state bindings, held supervisor lock and owned cloned TPM socket.

At launch it makes only four reviewed changes:

1. Replace the expected `-display none` with `cocoa,gl=es`.
2. Remove only the expected Unix `-vnc` pair, because this fork rejects it with GL.
3. Remove only unsupported `ppi=off` from the existing TPM device argument.
4. Replace only PCI7's2D hybrid device with the GL/Neptune/blob variant above.

Disk, firmware, optical-media, USB, network, audio, guest-agent and QMP options
retain their original order and values. The source is never a permitted target.
The source and clone may have different post-baseline EFI/TPM bytes; independence
and immutable source bindings are checked rather than requiring copied state to
remain byte-identical forever. An unexpected argument, changed config/media,
modified artifact, shared/replaced state file, active source or missing supervisor
ownership refuses launch. Nothing falls back to another target or renderer.

**The app's integrated VNC console is unavailable for this trial.** Input and
display use the separate Cocoa window. The engine's QMP lifecycle remains in
place. The trial binary predates the later bounded VNC/HID backpressure fix;
no claim of reliable rapid synthetic input is made. Start is an explicit action
of the coordinating task; this checkpoint did not launch Windows.

The seventeen private-file/socket tests cover the exact transformation,
source/unrelated-VM rejection, argv injection and read-only booleans, independent
post-baseline state, hardlinks/backing chains/symlinks, active supervisors,
changed config/source/media/owner/helper/artifacts, preexisting control sockets,
manifest tampering, actual lock ownership and exact probe/env forwarding.

## Native app container and current generation3

The first coordinated boot started QEMU10 and its renderer successfully, but
the standalone CLI process was unavailable by app identity to native UI tooling.
The app generations package the same executable code as a separate private app with
bundle ID `org.perpendicular.cocoa3dtrial`. This is a trial container, not a
replacement for the installed Perpendicular Desktop app.

```sh
.tools/build-venv/bin/python experimental/cocoa-neptune/package-cocoa-app.py
.tools/build-venv/bin/python experimental/cocoa-neptune/prepare-app-trial.py \
  12755108-83c6-4790-b477-58ca87b1a00e \
  --data-dir '/Users/federico/Library/Application Support/Perpendicular Desktop'
```

Both commands require fresh private output paths and neither launches the app.
The already-prepared outputs are frozen. The app is
`.tools/cocoa-neptune-app/Perpendicular 3D Trial.app`; the **current generation3**
wrapper and manifest are under
`.tools/cocoa-neptune-app-trials-gen3/12755108-83c6-4790-b477-58ca87b1a00e`.
Its current configuration binds the final `windows-3d-trial3.iso`. The old
generation1/media2 wrapper and generation2 wrapper are obsolete.

Normal ad-hoc bundle signing changes the Mach-O signature bytes. The signed app
Mach-O SHA-256 is
`3707f441f6d593add3dd0a60a7033cc7672b68dab840292cea131172c5fffbc9`;
the original prefix binary remains `8d4d5ec3…` unchanged. All file-backed Mach-O
section hashes match. The image preceding the signature also matches after
normalizing only `LC_CODE_SIGNATURE`'s offset/size and the `__LINKEDIT` segment's
VM/file sizes. The normalized image digest is
`3b242189e9d5aaf41ddb3ba1d343f6c664c7d0b3dcd80b292b7dab4e939ede15`.
No source compilation, instruction change or additional entitlement occurred.

The app passed actual `codesign --verify --deep --strict`; its XML entitlements
are exactly `com.apple.security.hypervisor=true`. Launch Services registered its
metadata without opening the app. Copying the old standalone signature alone
was insufficient for a sealed bundle, and external resource symlinks were
rejected by strict verification. The final app therefore contains ordinary
copies of only the existing keymap data. No firmware is copied. The dylib
dependencies still use the frozen private prefix, and the fixed renderer
environment is unchanged. `package.json` records original/signed hashes, every
file-backed section, Info.plist and keymap hashes, and the actual signing checks.

The first app launch failed before guest execution because relocating QEMU's
executable changed its default resource lookup: `failed to find romfile
efi-virtio.rom`. Its actual exit1 record was preserved, rather than rewritten as
a clean shutdown. Generation3 adds one fixed `-L PREFIX/share/qemu` pair to the
transformed command. The existing ROM is read from the original prefix, SHA-256
`26be36901db7f8181c306cc62bd74891d8646528965a78e40cceadba5dd7c8e7`.
No ROM, EFI code/variables or TPM state is copied or replaced. The current
manifest records the prior reaped failure and the previous helper hash.

`prepare-app-trial.py` is the current frozen generation3 helper; it retains the same
exact-clone, source, state, media, supervisor, argv and pinned-library checks,
and adds the signed app/Info.plist identity and packaged keymap checks. Its
app metadata probes returned0; no VM was started by those probes. A preparation
gate can explicitly accept the allowlisted clone's reaped nonzero exit only
when its supervisor lock is free and its recorded child PID is gone. The default
and source gates still require a successful reaped exit. The recorded failure
is returned in the manifest and the original runtime ledger is unchanged.

```sh
.tools/build-venv/bin/python experimental/cocoa-neptune/test-app-trial.py
```

All nineteen generation3 private-file/socket regressions pass, including the
fixed resource pair with unchanged disk nodes, failure rejected by default,
failure rejected with a live/missing PID, explicit clone failure gate with no
ledger mutation, and changed app metadata/keymaps. Only the coordinating task
starts or operates Windows.

The coordinating task subsequently reported **generation3 start exit0**, a
recognized `Perpendicular 3D Trial` app and a visible Windows desktop through
native UI tooling. Its saved QMP receipt is `.tools/windows-3d-cocoa-live-qmp.json`:
QEMU10.0.12 running, one TPM, and the expected UUID/launch-name ownership.
This is an observed Windows boot/display result reported by the coordinator.
The hybrid device can show an existing2D desktop; this observation does not
establish a loaded3D driver, accelerated D3D scene or sustained performance.
Driver installation and actual Windows rendering validation are separate gates.

## Source attribution and REA evidence

This checkpoint adds only Apache-2.0 project fixtures/documentation. It does not
copy or rebuild QEMU, virglrenderer, DXMT or ANGLE. Their pinned source revisions,
licenses and build provenance remain in
[`graphics-sources.json`](../../scripts/graphics-sources.json) and
[`graphics-README.md`](../../scripts/graphics-README.md). The selected QEMU pin is
UTM `88e5ee7ec6703662fec7b638cca74c4769e683d6`; the separate public2D QEMU11
checkpoint is unchanged.

Source evidence is in QEMU `ui/cocoa.m` (ES/Metal choice and native scanout),
`ui/console.c` (listener compatibility), `hw/display/virtio-gpu-virgl.c`
(Neptune/native sharing), `hw/tpm/tpm_tis_sysbus.c` (no PPI property), and
virglrenderer's `src/neptune/npt_renderer.c` / `server/render_worker.c`
(capabilities/backend/worker selection). `checkpoint.json` records their observed
hashes, not an assertion that every source tree is pristine.

REA inspected the exact Mach-O identity and dependency declarations. Its summary
Evidence is `ev_e5a3ec96cd95e31ba9c424c2413cefb471ef5c5dff03cce158910cddb4139a22`
(parent `ev_797615934783d19a57fec5316932d7fec1be8f9d12adeeeb3bf2032d4c943c97`).
Loader-resolution Evidence is
`ev_d832ab84c96f19cf1b39752fb9d6185ee5a20c13495e534e7c9b2fb844cf7e06`.
The latter leaves absolute dependencies outside its analyzed root undetermined;
it is not a claim that all dependencies loaded. The actual fixture loader trace
is separate execution evidence. The REA session was closed with its three retained
Evidence records in the private `rea-analysis.json` snapshot.
