# Native Metal display without a QEMU window

This opt-in backend initializes ANGLE/Metal with a 1×1 ES3 pbuffer, releases
the initialization thread's context and supplies QEMU's GL context callbacks.
It creates no NSApplication, NSWindow, CAMetalLayer or image readback path.
Checked immutable host-v3 snapshot leases still carry accelerated images
directly to the app's existing Swift receiver/Metal renderer. Ordinary QEMU
RAMFB/2D listeners can coexist; this backend does not convert 3D pixels for VNC.
Handle-only GL/native callbacks are counted and never captured without proof.

Build a fresh private overlay using the verified matched source profiles:

```sh
.tools/build-venv/bin/python scripts/graphics-wire1-sync-qemu.py \
  --qemu .tools/graphics-rebuild-qemu-native-20261016 \
  --sync-renderer .tools/graphics-rebuild-generations4-20261017 \
  --output .tools/graphics-rebuild-native-headless2-20261017 --headless

.tools/build-venv/bin/python scripts/graphics-qemu-probe.py \
  --profile .tools/graphics-rebuild-qemu-native-20261016 \
  --sync-qemu .tools/graphics-rebuild-native-headless2-20261017 \
  --swift-receiver --headless --label native-headless1
```

Existing output names must be changed for a rerun. Launch uses
`-display egl-headless,gl=es` with `PERP_NATIVE_DISPLAY_DIRECT=1` and
`PERP_NEPTUNE_SCANOUT_BROKER=1`. Host v3 is mandatory; guest Wire1 and native
DMTX v2 remain unchanged. Omitting the probe's `--headless` tests the same
binary's existing Cocoa route. No installed runtime or VM is changed.

## Verification on 2026-10-17

The actual QEMU/Wire1 decoder/native GPU/production Swift receiver run passed:
1,015,802 matching pixels, 64×32 → 803×607 → 64×32, two connections, retained
image rechecks across update/resize/disconnect, zero QEMU sink GPU copies,
zero publisher mappings/backing allocations and all 46 worker snapshots retired.
NSApplication remains nil and the window count is zero from startup to shutdown.
The context handoff is checked by actually binding/restoring the root context
on the execution thread. Both created client contexts are destroyed at shutdown.
QEMU's console GL pointer cannot be cleared; at most 16 small closed context
tombstones remain until process exit.

The same binary's Cocoa regression also passes. Two separate controls fail as
required: withheld producer readiness logs `producer completion timeout` after
the actual GPU fence completes; a private source mutant that retains the init
context logs `thread handoff failed (0x3002)` on QEMU's execution thread.
The latter is built only with the explicitly unsafe test option
`--headless --headless-keep-context`; it is not a usable runtime candidate.

Private receipts under `.tools/graphics-rebuild-qemu-native-20261016/`:

| Receipt | SHA-256 |
| --- | --- |
| `native-headless1/result.json` | `38c921396f07af97d5d7d18b78de099372d452482b73762eabf974bd7aa76f31` |
| `native-headless-cocoa2/result.json` | `f3a6640fdbff919f3cef10a50b94d3792cd7c291db0addb42f937b0c8fb68fd8` |
| `native-headless-handoff3/result.json` (expected failure) | `904c39310d9a4092683efe73ed01f96164d38c320a9b5966626c880bba0fed12` |
| `native-headless-token4/result.json` (expected failure) | `f015c9fe3f3e9fdc52dca2d6ab46c0967d1a3144dff109f4d81d8404acff30e1` |

Combined current-input verification is saved at
`.build/checks/worker-generations/headless-qualification.json`.
These diskless tests execute no guest CPU and do not measure visible frame
pacing or Windows input latency. Installed-app integration, real Windows
producer scope, boot/driver mapping and shutdown with pending GPU work remain
separate qualification steps. This is not a Windows performance result.
