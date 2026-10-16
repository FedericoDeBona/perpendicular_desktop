# Whole-repository Neptune Wire 1 profile

This isolated research profile builds the complete `utmapp/virglrenderer` commit
[`d3c970599eb0bfbfe417b86d87fc0e0641da9512`](https://github.com/utmapp/virglrenderer/tree/d3c970599eb0bfbfe417b86d87fc0e0641da9512).
The tracked generated protocol, decoder, dispatch, overrides and transport all
come from that commit. No wire constant is changed and no newer protocol source
is mixed in. This is a compiled host compatibility checkpoint, **not a successful
Windows 3D or scene test**. See the [signed-driver analysis](../../docs/NEPTUNE_DRIVER_WIRE_COMPATIBILITY.md).

## Frozen renderer outputs

| Artifact | SHA-256 |
| --- | --- |
| `.tools/graphics-wire1/prefix/lib/libvirglrenderer.1.dylib` | `d554a7b740bcd639c9b1aafca63992bbfcc2400f081058143a7fe0a04e17d83c` |
| `.tools/graphics-wire1/prefix/libexec/virgl_render_server` | `abb91b15d010fbb5a9637e92043d20b339e5e6a7078115a9f6dfeccec91a927c` |
| `src/neptune/neptune-protocol/npt_protocol_defs.h` | `30c843d723860bfda07d1c6e72262d56dc5224f9ffb61d0d8f9f7e645a4ec402` |

Both outputs are thin ARM64; strict local signature verification passes. The
server contains the matching renderer/decoder, not the newer server from the
original research prefix. The 578 tracked source files are individually hashed
in `.tools/graphics-wire1/provenance/source-files.json`; its SHA-256 is
`1a751a0975895e30d291b5d182b60da652fde656c189d73f0997946bfdb7e855`.
The source tree is clean and `compile_commands.json` contains no original
Wire 2 renderer source path.

## Reproduce the build

Run from the repository root using the already provisioned local dependencies:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1/build.py --profile .tools/graphics-wire1-repeat
```

The recipe requires a fresh output directory directly under `.tools`, fetches
the whole pinned repository over HTTPS, configures a separate Meson build,
compiles with at most two jobs, validates every installation destination, and
installs only into that profile's private prefix. It never starts a VM, edits
the original sources or installs into the original prefix. It verifies the
retained original QEMU, renderer, server, DXMT, Cocoa app executable and trace
candidate hashes before and after its work. To validate the frozen outputs
without rebuilding:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1/build.py --record-existing
```

Recorded tools: Python 3.14.6, Meson 1.12.1, Ninja
1.13.2.git.kitware.jobserver-pipe-1, Apple Clang 21.0.0, macOS 27 SDK,
PyYAML 6.0.3 and epoxy 1.5.11. Build options select EGL, Neptune and process
renderer/worker; Venus, vtest and tracing are disabled. Optimization is 0.
The exact options, compiler commands hash, dependency paths, versions, source
revisions, signatures and library imports are in
`.tools/graphics-wire1/provenance/build.json`.

Read-only dependencies came from `.tools/graphics-experiment`: epoxy at
`15d904dcb1d5a8d626ffe11e8f3339499d6f7b09` and ANGLE headers/libraries from
WebKit `6a7f464047e2f6f2b65fe315aaad5d1ff3229cb7`. Their existing paths must be
available; this recipe does not rebuild or redistribute them. Virglrenderer
licensing is retained verbatim in [COPYING](COPYING). Per-file upstream notices
remain in the pinned source, including Neptune code and its generated files.

## Paused HVF handshake receipt

The owned diskless fixture was run once with:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1/probe.py
```

Its frozen receipt is `.tools/graphics-wire1/probe/result.json`, with the exact
QEMU command/environment and dyld evidence in `probe/qemu.log`. The script
refuses to overwrite this receipt. The CPU remained paused (`prelaunch`), no
guest disks were attached, and only three GET_CAPSET_INFO requests and one
GET_CAPSET request were sent. Actual capsets were IDs 1, 2 and 7; capset 7
returned version 0, size 60, embedded wire version **1**, and flags `0xb6`.
QMP quit exited 0 and owned processes/sockets were cleaned up.

`DYLD_LIBRARY_PATH` put the private Wire 1 `prefix/lib` before the original
libraries, overriding the old absolute QEMU renderer dependency. Actual dyld
output confirms the new renderer loaded and the old renderer did not. The
matching server path was explicitly selected with `RENDER_SERVER_EXEC_PATH`,
but this capset-only fixture did **not** start a worker. It sends no COM, context
creation or rendering commands. It therefore does not validate frame production,
the complete renderer/backend ABI or Windows driver execution.

## Backend compatibility remains a separate gate

The original DXMT binary (`f01c20fd4fe4cd5d8a0a1ad8d93922f5c8045f325244bfbbe0ad27ebbf443e1c`,
source `2a7dd3e7d22541611433441b82894ec5bca75ca2`) was only reused read-only in
that initial capset fixture. Subsequent source comparison found a concrete
shared-texture ABI mismatch: this renderer expects `DMTX` v2 (72-byte POD,
file descriptor at offset 8), while that backend exports `DXNt` v1 (size at
offset 8, descriptor at offset 12). This is guarded later in shared-texture
operations; it does not itself explain a Windows boot with no context command.
Do not treat the reused backend as qualified or fix the mismatch by changing
constants. A whole, separately pinned compatible backend is required before
claiming this path is coherent. No existing app, runtime, VM or helper was
changed by this recipe.

## Coordinator Windows boot with the first profile

The same existing PCI8 trial VM was booted without a new VM/disk copy. Actual
dyld output verified both the new renderer library and matching server. Windows
Guest Tools answered and reported Microsoft Basic Display Driver at 800×600;
the GPU had no negotiated status/features and queue 0 used index stayed zero.
No Windows 3D rendering was established. Regular ACPI shutdown completed.
Private receipts: `.tools/windows-3d-wire1-boot1.json`,
`.tools/windows-3d-wire1-qmp-first.json` and `.tools/windows-3d-wire1-boot1.log`
(log SHA-256 `40e0794b4307bb84ee66aa0cf986a1c2724931418f52a4d53e8d11672e3e69c0`).

A second diagnostic boot separates firmware RAMFB from the same PCI8
`virtio-gpu-gl-pci` device, retaining Neptune/BLOB/hostmem settings. Selecting
RAMFB through Cocoa's View menu showed the Windows desktop. Device Manager
reported **Code 43** for Red Hat VirtIO GPU 3D controller at PCI bus 0, device 8,
function 0. This is a new guest-side initialization gate, not evidence that
the corrected wire version completed device creation or that the texture ABI
caused this early failure. Driver restart and a fully matched backend remain
to be tested.
