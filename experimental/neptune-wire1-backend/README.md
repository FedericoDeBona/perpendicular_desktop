# Whole DXMT backend for the Wire 1 research profile

This checkpoint builds the complete upstream DXMT commit
[`917b721c0f915c6524b416169fdce4427a39524f`](https://github.com/utmapp/dxmt/tree/917b721c0f915c6524b416169fdce4427a39524f)
in `.tools/graphics-wire1-backend`. It is the immediate parent of
[`2a7dd3e7`](https://github.com/utmapp/dxmt/commit/2a7dd3e7d22541611433441b82894ec5bca75ca2),
whose upstream message identifies a lockstep shared-texture ABI break. The
whole older backend is built without patches; no constants, layouts, event
code, newer dependency subprojects or decoder fragments are substituted.

It complements the [whole Wire 1 renderer](../neptune-wire1/README.md), whose
`d3c9705` source expects the older `DMTX` version 2 descriptor. This is a
successful small **native backend** fixture, not Windows driver or complete
Neptune scene qualification. In particular, a shared-texture ABI mismatch
occurs after context creation/export and does not by itself explain a Windows
boot that never submits a context command.

## Frozen artifact and sources

| Item | Value |
| --- | --- |
| Private backend | `.tools/graphics-wire1-backend/prefix/lib/libdxmt-native.dylib` |
| Backend SHA-256 | `4fade33095e08b341ceae2a35ee5dcebb0c452eb6fcc52f562df6f0d223b0da9` |
| Whole source pin | `917b721c0f915c6524b416169fdce4427a39524f` |
| Source tree | `5c26f68be7f5015082382700ad404b72db8c6d24` |
| Native public header SHA-256 | `6a6f4e5528dab829911dd0261079aebea0a03289aaaf5ee66898db7b0d3b7422` |
| DirectX headers submodule | `9df86f2341616ef1888ae59919feaa6d4fad693d` |
| Source inventory SHA-256 | `7c7310222687aebec79b7d6b922996b0530c7d06fcd91aaa0df1a22f44d9ee0c` |

The source checkout and header submodule are clean. The inventory records all
397 regular/symlink repository files and 66 header files separately; the whole
Git tree also binds the disabled, unfetched NVAPI submodule. The backend is thin
ARM64 and passes `codesign --verify --strict`. Its imports use system Apple
frameworks/libraries; LLVM is statically linked. This profile does not replace
any original dylib, server, QEMU executable, app, helper or active VM.

## Reproducible separate build

From the repository root:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1-backend/build.py --profile .tools/graphics-wire1-backend-repeat
```

A fresh output directory is required. The builder fetches the exact whole
upstream pin and its exact DirectX-header submodule, validates the native
header hash, configures a new Meson build with downloads disabled, compiles with
at most two jobs, checks every install destination, and installs only into the
new profile prefix. `--continue-source` supports the already fetched clean
source-only checkpoint; it refuses an existing build or prefix. No QEMU or VM
is launched by the builder.

The frozen original run used `--continue-source` after the same explicitly
logged Git init/remote/fetch/checkout/submodule commands. Configure, all 152
compile/link steps and private installation exited 0. To validate and record
the frozen artifacts without rebuilding:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1-backend/build.py --record-existing
```

Recorded tools are Python 3.14.6, Meson 1.12.1, Ninja
1.13.2.git.kitware.jobserver-pipe-1, Apple Clang 21.0.0, Metal compiler
32023.921 and macOS 27 SDK. Existing read-only dependencies are LLVM 15.0.7
from the already verified Homebrew bottle, zstd 1.5.7_1 and LLVM's static
libunwind. No package is installed or upgraded. Build options disable D3D12,
NVAPI and NVNGX, use optimization 0 and select the original private LLVM path.
This older pin builds its own `dxmt_native_event.c` and requires no
`directx-native` fallback/subproject.

`.tools/graphics-wire1-backend/provenance/build.json` records source/tree and
header hashes, exact options/tool versions, compile-commands digest, binary
imports/signature and dependency receipts. `source-files.json` binds upstream
source bytes. `llvm-static-inputs.json` hashes all 477 available static archives
in the reused LLVM directory (not a claim that every archive is linked).
Original renderer/server/DXMT/QEMU/app/diagnostic candidates and the new Wire 1
renderer/server are checked against retained hashes before and after work.

## Native fixture and its limits

The one-shot frozen test command was:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1-backend/test.py
```

It refuses to overwrite `.tools/graphics-wire1-backend/native-check`. Its
compile/run logs and `result.json` are retained there. The fixture:

- Extracts the actual descriptor declaration and constants from the clean
  Wire 1 renderer's `npt_shared.c`. Compile-time assertions compare every field
  offset, total size, magic and version with the exact old backend header.
- Tests manual-reset event creation, signal, clear, timeout and duplicated
  pollable descriptor.
- Creates a native hardware D3D11 device, a 64×32 shared BGRA texture, and
  obtains an actual `DMTX` v2 descriptor, 72 bytes with fd at offset 8.
- Rejects an altered version through the real `OpenSharedResource` entry
  point, then successfully imports the correct descriptor.
- Clears the texture with the real GPU, waits for a GPU fence/event, maps its
  exported storage and verifies all 2,048 BGRA pixels exactly.
- Uses dyld diagnostics to confirm this new backend loaded and the original
  backend did not; the artifact hashes remain unchanged.

Compilation uses warnings as errors; compile/run exit 0. The negative import
produces the expected upstream “bad shm descriptor” warning. Other upstream
runtime warnings about thread priority/Win32 stubs are retained in the log.
No guest CPU, guest disk, Windows, Neptune COM stream or QEMU is involved.
The test does not prove cross-process transport, full renderer dispatch,
scanout, signed Windows UMD compatibility, application performance or stability.

For a separately authorized trial, retain the matched Wire 1 renderer/server
selection and explicitly set each of `NPT_D3D11_LIBRARY_PATH`,
`NPT_DXGI_LIBRARY_PATH` and `NPT_D3D12_LIBRARY_PATH` to this backend's absolute
path. The last variable does not enable D3D12 in this build. Actual process
library readback is still required; merely setting an environment variable is
not evidence of loading. This recipe does not edit or start a trial helper.

## Notices

Upstream [LICENSE](LICENSE), [COPYING.LIB](COPYING.LIB) and
[LICENSE.OLD](LICENSE.OLD) are retained verbatim. DXMT is LGPL-2.1-or-later;
vendored upstream files retain their individual notices. DirectX headers
retain `include/native/directx/COPYING.MinGW-w64.txt` at the pinned submodule.
The reused LLVM bottle's Apache-2.0-with-LLVM-exception notice and third-party
notices remain under `.tools/graphics-experiment/provenance/licenses/llvm15`.
The newly written recipe and fixture follow this repository's Apache-2.0
license; these terms do not replace upstream licenses.

## Optimized comparison profile

The builder now accepts explicit `--optimization 2` for a fresh profile;
optimization0 remains the historical default. The same actual native GPU
fixture can select that profile:

```sh
.tools/build-venv/bin/python experimental/neptune-wire1-backend/build.py --profile .tools/graphics-wire1-backend-o2 --optimization 2
.tools/build-venv/bin/python experimental/neptune-wire1-backend/test.py --profile .tools/graphics-wire1-backend-o2
```

The actual O2 build completed, passed strict signature verification and the
native test verified2048GPU pixels plus rejection of a wrong shared-texture
version. The complete tracked source inventory matches the original backend,
including the same DirectX header submodule. Meson option comparison found
only optimization0→2 and the new prefix changed; no ABI or feature option was
changed. This does not yet establish Windows compatibility or an improvement
in pacing/latency. Both original checkpoint binaries remain unchanged. Private
comparison: `.tools/graphics-o2-comparison.json`.
