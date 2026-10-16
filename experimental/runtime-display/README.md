# Isolated QEMU 11 runtime: hybrid firmware framebuffer and VirtIO 2D

This checkpoint supplies a **candidate for root review**, not an installed runtime. No active VM, application, engine source, driver image, firmware, EFI variables or TPM state is changed here. Windows acceptance on this QEMU 11 candidate remains **not run**.

The candidate starts from the exact upstream QEMU 11.1.2 archive already pinned by the project (`731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016`). A fresh source tree was extracted from that verified archive; the existing `.tools/src` and stable build/prefix were not edited or copied as the source of truth.

Two production patches are applied:

- `hybrid-2d.patch` ports only UTM's `virtio-ramfb` wrapper from revision `88e5ee7ec6703662fec7b638cca74c4769e683d6`. One modern VirtIO GPU PCI function provides a firmware RAMFB before driver activation and the upstream QEMU 11 software 2D renderer afterward. `ui_info` is forwarded to the native VirtIO GPU. Changes cover QEMU 11 callback signatures, renamed console APIs, moved headers, `ramfb_setup(false, ...)`, and a setup error check. No OpenGL, VirGL, ANGLE, Rutabaga or Neptune rendering backend is enabled in the candidate.
- `hid-backpressure.patch` adapts the frozen input fix to QEMU 11's Linux keycodes and destructible VNC displays. Full RFB key messages wait for the global delayed queue and the actual active HID FIFO to drain; no prefix, modifier or release is skipped. Output/HUP/error handling stays active while input is suspended. The same watch helper covers encoder jobs and supported auth/transport implementations.

The expected runtime device is `virtio-ramfb,id=gpu,addr=7` (plus the engine's existing options). It presents modern VirtIO identity `1af4:1050` at PCI slot 7; the real qtest verifies this location. The existing TPM implementation and `tpm-tis-device,ppi=off` support are retained. The root agent owns the engine selection and bundling; this checkpoint does not rewrite normal launch arguments itself.

## Bounded input lifetime

Per-client retained input remains capped at one 4 KiB read plus a 12-byte key header. Accepted ownership is tracked separately for each client of the same VNC display. Disconnect cancels only that client's retained packet/timer and schedules only its unshared owned releases.

QEMU 11 can free a `VncDisplay`. Deferred releases therefore detach into a fixed pool of **32 console/handler slots**, each containing a fixed Linux-key bitmap and at most one timer. Repeated display open/close on the same stalled console/backend reuses a slot. A full pool rejects new input before it acquires ownership or enters a device FIFO. The context pins the console object and retains no freed client/display pointer. It drops that reference only after the final release drains, or after the target input handler is gone.

Handler identity is essential: removing a USB keyboard can reactivate an older keyboard. Releases belonging to the removed device are discarded rather than delivered to its replacement. No global keyboard/input-queue reset is used. An active display whose keyboard handler changes refuses subsequent input; recreating that display establishes a new handler identity. The engine's ordinary keyboard is fixed for the VM lifetime.

Limits remain explicit: ownership is scoped to one VNC display, not unrelated displays, Cocoa, QMP or other input producers. Those producers retain upstream admission behavior and could still fill a shared device. A guest that never polls can defer releases indefinitely, within the stated memory bounds. Unix None-auth RFB is exercised; TLS/SASL/WebSocket runtime paths are not acceptance-tested. These tests do not measure Windows FPS, USB IRQ timing or HVF scheduling. Migration/savevm of the hybrid wrapper is not validated; the UTM wrapper's firmware RAMFB migration limitation is retained.

## Reproduce

Use the repository's provisioned Python/Meson/Ninja environment and Homebrew libraries. The builder validates archive and source hashes, extracts into a **fresh** private tree, applies the production patches, and builds only `qemu-system-aarch64` with at most two jobs. It never invokes `install`. The install prefix is an unused path inside that private output.

```sh
.tools/build-venv/bin/python experimental/runtime-display/build.py \
  --output .tools/runtime-display/repro-new --jobs 2
.tools/build-venv/bin/python experimental/runtime-display/test-display.py \
  --binary .tools/runtime-display/repro-new/candidate/qemu-system-aarch64 \
  --source .tools/runtime-display/repro-new/source
.tools/build-venv/bin/python experimental/runtime-display/test-input-server.py \
  --binary .tools/runtime-display/repro-new/candidate/qemu-system-aarch64 \
  --source .tools/runtime-display/repro-new/source --production-smoke
```

The byte-copied candidate avoids FinderInfo/ResourceFork metadata. Before signing, its uninstalled Slirp dependency is copied into a private `candidate/lib` directory and assigned absolute dependency IDs. That library's license is retained in `Slirp-COPYRIGHT`. The only candidate executable entitlement is `com.apple.security.hypervisor=true`; strict signature, thin ARM64 identity and probe absence are checked. Root bundling reads the actual bytes/signature and rewrites library paths in its own output.

The builder preserves the caller's developer-tool selection. A host with usable
Command Line Tools can select them explicitly with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools` and the corresponding
`SDKROOT`, `CC`, `CXX` and `OBJC` environment values; full Xcode is not forced
for this software 2D build. The selected environment is recorded in the new
build's provenance, alongside its actual configure/build logs.

`provenance.json` records the frozen candidate, archive, source revision, patch hashes, notices, exact build arguments and validation. A fresh builder run produces its own manifest beside its private build; select that file explicitly when reviewing another build. Firmware and `qemu-img` continue to come from the root-owned normal prefix.

## Separate QA build and tests

```sh
.tools/build-venv/bin/python experimental/runtime-display/build.py \
  --output .tools/runtime-display/qa-new --qa --jobs 2
.tools/build-venv/bin/python experimental/runtime-display/test-input-server.py \
  --binary .tools/runtime-display/qa-new/candidate/qemu-system-aarch64 \
  --source .tools/runtime-display/qa-new/source
.tools/build-venv/bin/python experimental/runtime-display/test-cleanup.py \
  --source .tools/runtime-display/qa-new/source
```

`qtest-probe.patch` is **separate from both production patches**. Device properties are registered only with the explicit qtest accelerator. Their `x-input-test-` / `x-runtime-test-` markers remain in the QA binary, so root bundling rejects it even if selected accidentally. The production candidate has neither markers nor properties. No protocol/agent or guest-side code is added.

The input server adapter reuses the frozen QEMU 10 regression without modifying it. It changes only the private source/binary directory, qtest CPU (`cortex-a57`), hybrid GPU fixture, QEMU 11 internal rebind fixture wording and the new lifetime tests. QEMU 11 exposes no equivalent public runtime display-reopen API; the QA hook invokes the real internal switch helpers and real `vnc_display_free/new` functions.

All child processes are diskless, explicitly spawned qtest children with private Unix sockets. No existing QMP socket, VM, guest agent, desktop window or host clipboard is contacted.

## Frozen QA: exact commands

The frozen QA executable is a signed copy in `.tools/runtime-display/qa/`; its verified source and build directories are `.tools/runtime-display/source` and `.tools/runtime-display/build`. There is **no** `.tools/runtime-display/qa/source` directory. `qa_build` in `provenance.json` records these paths and the source-pin file's SHA-256; the production pins with `qa_patched_files` overrides match the frozen QA source bytes.

```sh
.tools/build-venv/bin/python experimental/runtime-display/test-input-server.py \
  --binary .tools/runtime-display/qa/qemu-system-aarch64 \
  --source .tools/runtime-display/source
.tools/build-venv/bin/python experimental/runtime-display/test-cleanup.py \
  --source .tools/runtime-display/source
```

## Evidence

The full fresh build completed 2173 targets. The final candidate comes from the fresh archive→patch→configure→link builder run, followed by the builder's private dependency normalization/signing step. All configured consumers of the modified input/VNC headers are rebuilt in that fresh tree.

`test-display.py` uses actual firmware and device protocols, without a test property that flips renderer state:

1. Writes an `etc/ramfb` configuration through real fw_cfg DMA and verifies its readback and 640×480 exact red pixels over RFB.
2. Enumerates/configures the PCI7 modern VirtIO function and submits real resource-create, attach-backing, transfer, set-scanout and flush commands through its control virtqueue. The same console changes to 800×600 exact blue pixels.
3. Sends RFB251. Status 4 reports forwarding while the framebuffer remains 800×600; a real VirtIO GET_DISPLAY_INFO response carries the requested 1280×800 hint. Only the next guest scanout command changes actual RFB dimensions/pixels to 1280×800 green.

The real input server tests pass for all 26 transitions under suspended polling, output/jobs during suspension, two-client HUP ownership, fragmented extended messages and E0/E1 sequences, deferred console switching, and exact final modifier release. Bypassing only FIFO readiness reproduces **exactly ten** actual queue-full drops. The new tests additionally destroy/recreate real VNC displays 49 times with polling suspended, retaining one cleanup slot; resumption drains releases. Actual USB device removal leaves the replacement keyboard untouched.

The ASan/UBSan cleanup fixture extracts the production pool function bodies verbatim and narrowly models outer console/timer services. It passes 2,000 stalled teardowns, pool exhaustion at 32 slots, console-reference/device removal cleanup and replacement-handler isolation. Removing only the identity guard fails the causal negative control. This source fixture complements the real server/device tests; it does not substitute for Windows acceptance.
