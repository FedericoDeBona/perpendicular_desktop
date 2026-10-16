# Opt-in native display measurements

Set `PERPENDICULAR_DISPLAY_TELEMETRY_DIR` on the **native client process** to an
existing absolute directory owned by the current user with mode 0700. A final
symlink (including one with a trailing slash), a non-private directory, relative
path or invalid path is rejected. No directory/file is created when the variable
is absent. An invalid configuration silently disables this diagnostic; it does
not change the display or add UI warnings. The existing first-frame diagnostic
flag is independent.

One unique `native-presentation-PID-UUID.json` file is opened exclusively with
mode 0600 per process. It contains no pixels, device addresses, VM names/IDs,
connection/session identities, filesystem/socket paths, keys, pointer positions,
clipboard or guest text. Stream/submission ordinals are local counters only.
The directory is not automatically cleaned: one process never deletes another
run's reports.

All callbacks update bounded metadata under a lock. A utility serial writer
coalesces output to at most one asynchronous write per second, with at most one
pending write. The fixed file is capped at 128KiB, recent event storage at 128
records, each metric's sample window at 256, counter keys at 32, metric keys at 16,
and active stream history at 8. Counts remain cumulative; median/p95/min/max
describe each metric's **recent window**, not an arbitrarily long benchmark.
Reports are overwritten through the owned open descriptor, never an arbitrary
replacement path. A reader racing a write may need to retry parsing; wait at
least one second after the last activity for the coalesced snapshot. Abnormal
process exit may lose the final unflushed second. Disk errors do not interrupt
presentation. Locking, bounded bookkeeping and the writer add diagnostic work;
this is not a claim of zero measurement overhead.

## Meaning of the measurements

All times use the host monotonic domain. Event timestamps are relative to the
recorder's creation and durations are milliseconds. The receiver adds optional
local timestamps to the lease; it does not change the transport or guest ABI.

| Field or counter | What it actually observes |
| --- | --- |
| `frames_received` | The receiver worker takes an identity-validated frame from the C transport; it is not the producer's rendering/present time. |
| `frames_ready_imported` | Readiness has been observed and the shared Metal import validated. |
| `mailbox_replaced` | An undelivered frame was replaced before the main actor consumed it. |
| `frames_delivered` | A lease reaches the main actor with receive/readiness/delivery timestamps. |
| `presenter_accepted`, `presenter_rejected` | Native lease submission accepted/rejected by the actual presenter. |
| `presenter_pending_replaced` | A native submission replaces a pending presenter item; this is separate from the receiver mailbox and producer-side drops. |
| `receive_to_ready` | Time from worker receipt until the ready token is observed; includes receiver polling, not a measurement of total producer GPU work. |
| `ready_to_main_delivery` | Ready observation through validation/import and mailbox/main-actor delivery. |
| `receive_to_commit` | Local worker receipt until the first draw attempt is committed. |
| `commit_to_gpu_start`, `gpu_execution` | Actual `MTLCommandBuffer.gpuStartTime/gpuEndTime` measurements. Missing GPU timestamps remain unavailable. |
| `gpu_end_to_callback`, `gpu_callback_to_main` | CPU notification delay after GPU end, and the subsequent main-actor scheduling delay. |
| `drawable_presented` | Only a nonzero `MTLDrawable.presentedTime` received in `addPresentedHandler`; GPU completion alone never increments it. |
| `drawable_skipped` | A presented handler returned zero, which the SDK defines as not presented/skipped. Missing callbacks are not converted into success. |
| `commit_to_presented` | Actual drawable presentation timestamp minus commit, independently of callback delivery time. |
| `receive_to_presented` | Receipt to actual presentation for the first draw attempt of a lease. Redraws do not duplicate this sample; if that first attempt is skipped, this metric has no sample for it. |
| `drawable_interval` | Differences between increasing actual presented timestamps within the same live view/generation, including explicit redraws. |
| `redraws_submitted` | Further submissions sampling the same retained current lease. They are not newly received guest frames. |
| `stale_callbacks` | An event belongs to a reset/stopped/evicted stream generation. It is labeled stale and cannot change current presentation interval history. |

The GPU and drawable callbacks may be delivered in different orders. Events
carry the same local submission ordinal to distinguish them. The presented
handler retains only timing metadata, never the lease/texture: the existing
GPU-drained retirement and exact-identity ACK are not delayed until a screen
callback. Reset/stop keeps old callbacks separate from the current generation.

This is **host display pipeline evidence**. It does not measure Windows render
FPS, every guest Present, physical monitor scanout/photon time, or keyboard/
mouse input latency. Input-to-display latency requires a separate controlled
guest response causally associated with a known input; a nearby frame is not
sufficient. These reports cannot establish that association.

## Narrow checks

```sh
bash macos/Tests/run-display-telemetry-tests.sh /tmp/perpendicular-display-telemetry-result.json
bash macos/Tests/run-external-presenter-tests.sh
bash macos/Tests/run-display-presenter-tests.sh
```

For the receiver's extra real IPC scheduling fixture, create a fresh private
directory and apply the variable to that test process only:

```sh
telemetry_dir="$(mktemp -d /tmp/perpendicular-telemetry.XXXXXX)"
PERPENDICULAR_DISPLAY_TELEMETRY_DIR="$telemetry_dir" \
    bash macos/Tests/run-native-display-connection-tests.sh
```

The telemetry suite uses an owned offscreen Metal pipeline and a hidden,
disposable native view, never a Windows VM, visible application window or input.
A real shared-event gate withholds GPU work: neither elapsed wall time nor
submission can fabricate completion, and offscreen completion cannot fabricate
drawable presentation. Actual GPU timestamps are reported separately from
explicitly synthetic compositor timestamps used to test a 40ms presentation
versus a 1ms GPU duration, zero/skipped callbacks, duplicates, stale generation,
redraw accounting and bounded storage after 2048 submissions. Private-directory
and symlink rejection are exercised. A child fixture opts in before the shared
recorder is initialized, exercising production presenter hooks (100 submissions,
99 pending replacements and retained-image redraw). Hidden-window completion
does not qualify visible compositor latency.

The existing receiver test can additionally be launched with the opt-in
directory variable. It then adds one actual two-process FD fixture: MainActor
delivery is withheld while two ready frames arrive, the mailbox replaces the
first, and a deliberate 50ms scheduling stall is measured before the surviving
frame is consumed by Metal. It checks actual receipt/replacement counters,
texture dimensions/pixels and normal GPU-before-ACK cleanup. The ordinary
receiver suite also continues to run with the diagnostic disabled.

Windows measurements belong to a subsequent root-owned live trial of the exact
built client. No app/VM/runtime is launched or changed by the source tests.

Submission events additionally record scalar window/layer context: window
visibility/occlusion/key state, app activity, hidden ancestry, the actual view
and layer `presentsWithTransaction` values, and layer `displaySyncEnabled`.
These describe the submit instant, not an uninterrupted visibility guarantee.
Connection failure counters include numeric transport/errno classes without
paths, endpoint identities, error text or guest content. They share the same
bounded counter/event storage.
