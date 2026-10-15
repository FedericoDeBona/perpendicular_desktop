# Isolated VNC → USB keyboard backpressure

Frozen review checkpoint for the pinned UTM QEMU 10.0.12 source at revision `88e5ee7ec6703662fec7b638cca74c4769e683d6`. **Not promoted to an installed application or either active runtime.** The nine production files have original/patched SHA-256 pins in `source-hashes.json`. The patch is `qemu-10.0.12-backpressure.patch`; `validation.json` records the private linked binaries and hashes.

The real Windows trial established the failure beyond the app writer: `Clear-Host ` produced all 11 native/responder down/up events and all 13 modifier-inclusive accepted/written pairs, with wire gaps 10.198–11.126 ms. QEMU nevertheless emitted exactly ten `hid_kbd_queue_full` events and left H pressed. The client’s 10 ms pacing remains a burst guard; consumption must be checked at the device.

The patch admits a complete RFB key message only when QEMU’s delayed keyboard queue is empty **and** the active keyboard’s device FIFO has drained. USB HID registers a readiness callback in the opaque input-handler state; the public input-handler structure ABI is unchanged. Other handlers retain their previous admission behavior. Classic and extended VNC messages use the gate before mapping, lock synchronization, ownership or guest-input changes. A single admitted message may generate lock synchronization plus a complete E0/E1 transition, which fits inside the unchanged 16-scancode FIFO.

When blocked, the entire message remains intact in its `VncState`. G_IO_IN is suspended while G_IO_OUT, HUP and errors remain enabled. The same watch-mask helper is used by the main client, encoder jobs, SASL, VeNCrypt and WebSocket paths, so a jobs flush cannot accidentally restore G_IO_IN. A per-connection 10 ms realtime retry checks actual readiness; it does not promise guest polling at that interval. Retained bytes are explicitly capped at one 4 KiB socket read plus 12 bytes of incomplete key header. An invariant violation closes only that connection with an error. Kernel socket buffering supplies upstream backpressure. No click or release is coalesced or skipped.

Disconnection cancels the retained message and destroys that connection’s retry timer. Accepted key ownership is tracked per client. Cleanup transfers only keys no longer owned by another client into a fixed-size display bitmap, then sends their releases through the same readiness gate, with priority over later client input. It does not clear the global input queue, reset a keyboard or affect another input device. Deferred cleanup holds no pointer to the disconnected/reused `VncState`; its timer is freed when the bitmap drains. `VncDisplay` is process-lifetime in this fork. A stopped guest may delay releases indefinitely, bounded to one bitmap and timer per display.

Ctrl-Alt-console shortcuts defer switching until every client’s accepted keys, retained input, pending cleanup and the old device FIFO have drained. A pending switch retains a console index, not a potentially unplugged console pointer; disconnect cancels it. Public display rebinding rejects pending keyboard work **before** closing a listener or changing authentication state, preserving the original console until idle.

Scope limits:

- Ownership covers clients of the same VNC display. Native Cocoa, QMP and other non-VNC producers retain upstream admission behavior. Shared key ownership across independent VNC displays/native producers is not claimed; another producer could still fill the same device after the VNC check.
- None-auth Unix RFB is exercised end to end. TLS/SASL/WebSocket watch changes compile with the configured fork, but those authenticated transports were not exercised at runtime.
- qtest tests call the actual HID poll function via a QA-only property, so they prove real FIFO/parser/event-loop/socket behavior, not Windows USB scheduling, IRQ timing or HVF performance. Windows acceptance remains pending and belongs to the root agent.
- No app/native source, installed binary, driver ISO, guest disk, live VM or guest setting was changed for this checkpoint.

## Reproduce the source checks

Run from the repository root. `apply-overlay.py` refuses existing destinations and mismatched pinned sources; choose a fresh private output name.

```sh
python3 experimental/input-backpressure/apply-overlay.py \
  --output .tools/input-backpressure/review-fresh-source
python3 experimental/input-backpressure/test-backpressure.py \
  --overlay .tools/input-backpressure/review-fresh-source
python3 experimental/input-backpressure/compile-objects.py \
  --overlay .tools/input-backpressure/review-fresh-source \
  --output .tools/input-backpressure/review-fresh-objects
```

The C fixture extracts production FIFO/conversion/poll, admission, buffered parser, readiness, ownership, retry, disconnect, console-switch and I/O dispatch bodies verbatim. Outer QEMU services are narrowly stubbed; two clients use real private Unix socket pairs. ASan/UBSan check cleanup and storage reuse. Tests pass for suspended/resumed polling with all 26 transitions, E0/E1 prefixes, modifiers, a foreign delayed queue, output during input suspension, HUP with a retained release, shared ownership, byte bound, deferred switching, removed targets and an unrelated device. Disabling only admission reproduces exactly ten FIFO drops. All seven changed C translation units also compile with the fork’s recorded flags.

## Full build and real server tests

`build-isolated.py` clones the full source into a **fresh private directory**, applies the pinned production patch, replays the existing fork configuration with an unused private install prefix, and performs a complete link. It does not run an install command or mutate an existing build. The dependency environment is the already provisioned `.tools/graphics-experiment` and `.tools/build-venv` environment.

```sh
python3 experimental/input-backpressure/build-isolated.py \
  --output .tools/input-backpressure/repro-qa --test-probe
python3 experimental/input-backpressure/test-server.py \
  --binary .tools/input-backpressure/repro-qa/build/qemu-system-aarch64 \
  --source .tools/input-backpressure/repro-qa/source
python3 experimental/input-backpressure/build-isolated.py \
  --output .tools/input-backpressure/repro-production
python3 experimental/input-backpressure/test-server.py \
  --binary .tools/input-backpressure/repro-production/build/qemu-system-aarch64 \
  --source .tools/input-backpressure/repro-production/source --production-smoke
```

The separate `qemu-qtest-probe.patch` adds device properties **only under the explicit qtest accelerator**. It exposes FIFO count, one actual HID poll, a readiness-only bypass for the causal negative control, and display-rebind/visibility fixtures. It is excluded from the probe-free linked binary and must never be promoted to a runtime. The test spawns its own diskless qtest process with private temporary Unix sockets and terminates only that process.

The full fresh build completed 1960 targets. All configured consumers of the changed `ui/vnc.h` were rebuilt; their dependency-recorded object names are in `validation.json`. The final probe-free variant was relinked after restoring the original `hw/usb/dev-hid.c` and recompiling that object. Probe absence is checked in both binary strings and QMP properties.

Exact commands for the already built frozen artifacts:

```sh
python3 experimental/input-backpressure/test-server.py \
  --binary .tools/input-backpressure/full-build/qemu-system-aarch64-qtest-probe
python3 experimental/input-backpressure/test-server.py \
  --binary .tools/input-backpressure/full-build/qemu-system-aarch64 --production-smoke
```

The real linked server tests pass for: suspended polling; bounded ingress without a readable-socket spin; framebuffer/jobs output while input is suspended; all 26 transitions after resumption; two-client HUP cleanup with a retained release and a surviving held key; fragmented extended messages; atomic E0/E1 scans and final modifier release; rejected pending rebind with listener preserved; idle rebind; and a deferred Ctrl-Alt-2 switch. On that same server/device, bypassing only HID readiness reproduces exactly ten queue-full events. The probe-free binary separately passes QMP/RFB/framebuffer/clean-shutdown smoke testing.

The root agent independently repeated the native C sanitizer suite, real-server
suite and probe-free smoke successfully, verified both frozen binary hashes and
the production patch digest, and checked the Hypervisor entitlement. Strict
signature verification initially refused empty Finder/resource-fork metadata
on the build output. A fresh byte-only copy under the private
`runtime-candidate` directory preserves the exact frozen binary hash and passes
strict verification without changing the original artifact. This still does not establish Windows
guest acceptance. Both source patches remain under QEMU's upstream GPLv2
licensing; the original helper/test code follows this repository's license.
