# Bounded VirtIO GPU opcode diagnostics

This is a separate diagnostic candidate for the private UTM QEMU10.0.12 fork at
`88e5ee7ec6703662fec7b638cca74c4769e683d6`. It does not enable3D, repair a driver,
change command dispatch, install a runtime or start a VM. Existing prefix/app
executables, renderer libraries, source and helper pins remain unchanged.

`diagnostics.patch` modifies only `hw/display/virtio-gpu-virgl.c`. The derived
patch follows that file's **GPL-2.0-or-later** terms; the original Red Hat authors
and license header remain intact. The full GPLv2 text is retained as `COPYING`.
The unchanged source is available from
[the pinned UTM fork](https://github.com/utmapp/qemu/tree/88e5ee7ec6703662fec7b638cca74c4769e683d6).

## Recorded fields and bound

Only this exact environment value enables the diagnostic:

```text
PERPENDICULAR_GPU_COMMAND_DIAGNOSTICS=1
```

The setting is cached at the first command; other/unset values produce no added
log lines. A shared process-lifetime budget admits at most **64 records total**
across all three sites, followed by one suppression line. Each command entry and
each capset metadata call consumes a record; this is not64 records per site or
per device. Processing is under QEMU's BQL. No timer, queue, guest memory dump,
command payload, frame, pointer, clipboard text or user input is logged.

* Immediately after `VIRTIO_GPU_FILL_CMD(cmd->cmd_hdr)`: numeric `type`, `flags`,
  `ctx_id`, before renderer dispatch.
* `GET_CAPSET_INFO`: decoded index, advertised capset count, actual response
  capset ID/max version/max size, after response fields are constructed and
  before the normal response routine.
* `GET_CAPSET`: decoded requested ID/version, advertised count, backend maximum
  version/size and normal response/error type. Its wire response has no ID or
  version fields; the diagnostic does not invent them or inspect capset bytes.

All output begins `perpendicular-gpu-cmd` on the existing process stderr. The
last added line is exactly `perpendicular-gpu-cmd suppressed after 64 records`.
Other preexisting QEMU/renderer messages are outside this added log budget.

## Build without changing the existing runtime

Prerequisite: the already configured, compiled private graphics build and its
existing dependencies. No source download or installation is performed.

```sh
.tools/build-venv/bin/python experimental/gpu-command-diagnostics/build.py \
  --output .tools/graphics-experiment/build/gpu-command-diagnostics-repeat
```

Choose a fresh output directory directly under the private graphics `build/`
parent. The builder verifies the original source SHA, copies **one file** into
that new output, and applies the patch to the copy. It creates an additional
Ninja description that includes the unchanged existing build description and
reuses its compile/link flags, generated headers and already-built objects.
Only the private diagnostic object replaces the original GPU object in a
**new link target**. The source-local quoted-header search is preserved.
Jobs are capped at two. No `install` target or firmware target is requested.

The existing build's version-header generator can run and prints
`fatal: No names found, cannot describe anything` for the shallow source tree;
it returns successfully with the unchanged fallback version header. Ninja's
restat skipped the originally planned unrelated compiles: the successful log
shows one private C object compile and one separate link after generation.
The original unsigned executable and `build.ninja` hashes are checked afterward.

The new linked bytes are copied into `candidate/qemu-system-aarch64` without
extended attributes and ad-hoc signed with only the public Hypervisor entitlement.
Actual strict verification and XML entitlement readback are required for success.
The source fork, original unsigned binary, prefix binary, Cocoa app and renderer
library/server hashes are verified unchanged before reporting success.

The actual frozen candidate is:

```text
.tools/graphics-experiment/build/gpu-command-diagnostics-2/candidate/qemu-system-aarch64
SHA-256 fe5080ce69e0a8cf1b2bc3de73fab1df6657ca58fe4c8dbc53646b846025d9d1
```

Patch SHA-256:
`1f6bf65eb9bad919dc892fffae7c84cbb59084521888754d3e1eb50c506646ba`.
Build exit0, strict signature PASS, only `com.apple.security.hypervisor=true`.
The genuine candidate `--version` returned10.0.12 with exit0. Its complete
command/protected hashes are in `build.json`; compiler/link output is in
`build.log` beside the candidate directory. These are build/metadata results,
not a runtime observation of the currently investigated Windows command loop.

An initial private build-description attempt failed before compilation because
the renamed target also replaced an object-directory prefix. The corrected
builder changes only the target's first occurrence; that failed output remains
separate under `build/gpu-command-diagnostics`. No original artifact was altered.

## Verify the added log code without a VM

```sh
.tools/build-venv/bin/python experimental/gpu-command-diagnostics/test.py \
  --source .tools/graphics-experiment/build/gpu-command-diagnostics-2/source/hw/display/virtio-gpu-virgl.c
```

The harness extracts the exact gate and three added logging blocks from the
patched source, compiles them with bounded metadata stubs under
`-Wall -Wextra -Werror`, and checks five fresh processes. Unset/`0`/`true`/`01`
produce zero lines. Exact `1` processes4096 calls but produces only64 allowed
metadata lines and one suppression line. Output must match the three fixed
numeric formats and contain no fixture payload marker. Static checks bind each
site to its intended location after header/request fill.

These tests validate the added formatting, gating and bound, not the complete
QEMU event loop, guest byte ordering, driver initialization or GPU rendering.
Only the coordinating task may package a distinct trial app/adapter and explicitly
start the stopped clone with this candidate. Existing app/helper manifests are
not rewritten by these tools.

## Current variant3: preserve the budget until CONTEXT_INIT negotiation

The coordinator's first real boot trace consumed all64 records during the old
2D display path (`0x100`, `0x101`, `0x106`, `0x103`, then `0x105`/`0x104` paint
pairs). No capset command was observed within that initial budget. This is the
reason for a second, separate candidate; it is not evidence about capset failure.

`diagnostics-context-init.patch` is a cumulative alternative to the first patch.
It adds the negotiated-feature gate
`virtio_vdev_has_feature(VIRTIO_DEVICE(g), VIRTIO_GPU_F_CONTEXT_INIT)` before
environment initialization or any budget increment. In this QEMU10 API,
`virtio_has_feature` takes a numeric feature mask; the device accessor is
`virtio_vdev_has_feature`, which reads negotiated guest features. The first API
attempt failed compilation and is retained separately in the private
`gpu-command-diagnostics-3-api-failure` log directory. The corrected candidate
linked successfully.

Commands before negotiation produce no diagnostic lines and consume no budget.
After negotiation, the same combined64-record limit and one suppression line
apply. The counter is process-global and is not replenished by device reset.
The gate is not itself proof that a Windows3D driver initialized successfully.

```sh
.tools/build-venv/bin/python experimental/gpu-command-diagnostics/build.py \
  --context-init \
  --output .tools/graphics-experiment/build/gpu-command-diagnostics-repeat3
.tools/build-venv/bin/python experimental/gpu-command-diagnostics/test.py \
  --source .tools/graphics-experiment/build/gpu-command-diagnostics-3/source/hw/display/virtio-gpu-virgl.c
```

Use either cumulative patch on the pristine source, not both patches in sequence.
Current frozen variant3:

```text
.tools/graphics-experiment/build/gpu-command-diagnostics-3/candidate/qemu-system-aarch64
SHA-256 ed4116c76d948a6b21e4fc5af00c50dbecabc7ace94a745bce6ac8000d078cef
Patch SHA-256 5458a8717c5c122d1c3caf704ef395ec160e8983239c032466886a7818f8efa0
```

Build exit0, strict signature PASS, exactly the public Hypervisor entitlement.
The seven compiled-harness cases include4096 feature-disabled calls producing
zero lines, and4096 disabled calls followed by4096 enabled calls retaining the
complete64+1 output budget. This remains an extracted-code harness; no new
QEMU/Windows runtime test was performed by this checkpoint. The first candidate
`fe5080ce…`, original prefix/app executables, original source/build description/
unsigned executable and renderer library/server hashes were all checked unchanged.

## Coordinator Windows trial observations

The first candidate was packaged into a separate private Cocoa app and booted
the existing PCI8 trial. Exactly64 records plus suppression were produced, but
initial2D paint commands consumed the budget, so it did not identify the later
3D stage. Variant3 adds the negotiated CONTEXT_INIT admission gate before that
budget. It produced exactly64 records plus suppression during a Windows boot:
GET_CAPSET7/version0 returned backend size60/response1103, interleaved with
CTX_DESTROY, with no CTX_CREATE in the bounded window. A fresh renderer context
or visible3D scene was not established. The observed pattern can be an adapter
capability probe; teardown alone is not evidence of a failed context-create call.

The private trial used the same VM/disk and retained the original app/runtime.
Its receipt is `.tools/windows-3d-trace3-runtime.json`, with the bounded text in
`.tools/windows-3d-pci8-context-init-trace3.log` (SHA-256
`e0fc54b719df9119a949392ba12e07b64c944a475a821047ee5ee21def3d3d30`).
This trace records capset metadata, not the payload's internal wire version.
The separate [signed-driver compatibility review](../../docs/NEPTUNE_DRIVER_WIRE_COMPATIBILITY.md)
identifies the next compatibility gate; these diagnostic patches do not fix it.
