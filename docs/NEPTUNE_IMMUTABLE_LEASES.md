# Immutable native scanout generations

This is an opt-in private host extension. It preserves the matched renderer
`d3c970599eb0bfbfe417b86d87fc0e0641da9512`, native backend
`917b721c0f915c6524b416169fdce4427a39524f`, guest Wire1 and native DMTX v2
descriptor. Private broker version **3** is distinct from those guest/native
versions. Host v2 remains the default build recipe.

## Ownership and synchronization

The actual Context4 Signal override copies all explicitly admitted source
resources into immutable snapshots **before** the original Signal. Its actual
fence/event authorizes publication. An original source resource can subsequently
change without changing the published snapshot.

The v3 worker moves busy snapshots into a retained-generation registry before
capturing their successors. Source COM owners stay in the current Export;
retained slots own only the snapshot, completion event and fence. The registry
has eight retained/cache slots, at most four idle entries and a 64-MiB total
producer-owned allocation budget, including current and cached snapshots.
Admission preflights slots and bytes before detaching current busy snapshots.
Unsupported plans drop capture rather than overwrite a leased allocation.

An exact ACK, checked against actual GPU completion, permits allocation reuse.
Cancellation of a never-exposed candidate also permits reuse. A publisher
disconnect/reset is a separate **abandon** operation: the worker releases the
allocation and never caches it for rewriting. Duplicated consumer descriptors
and mappings retain their old kernel backing. The byte budget does not claim
to bound memory independently retained by a disconnected external consumer.

Owner identity, explicit exports/claims, resource/worker epochs, import denial,
one immediate writer, one monotonic fence and multi-ring rejection remain
required. Cache keys do not replace these admission checks. The experiment
does not establish a general Windows Present/compositor contract.

For full, zero-offset BGRA scanouts, QEMU duplicates the worker's ready token
and passes the immutable memory FD directly to the native publisher. Neither
the QEMU sink nor publisher maps/imports/copies these pixels. The publisher
creates an independent per-frame readiness pipe after checking the actual
upstream token; upstream event teardown cannot invalidate an accepted frame.
The app's existing Swift receiver/Metal renderer imports and reads that FD.
Two publisher slots permit a successor while the client retains its predecessor.

Publisher callbacks may run on another thread or before submission returns.
Their complete identity is initialized first, and retirement is dispatched back
onto QEMU's main thread. ACK and abandonment apply to that exact lease even
after display selection changes. Cropped scanouts retain the existing GPU-copy
fallback; this direct path does not silently discard crop support.

Broker frame capacity is eight independently leased generations; export/claim
admission remains four resources. Newer generations supersede only ready,
never-leased candidates. Callbacks and ready-FD lookups match context, worker
epoch, resource epoch, blob and snapshot generation, never FD integer identity.

## Reproduction

Use already verified complete matched renderer/backend/QEMU profiles. Every
new build output must be fresh; input changes invalidate its protected hashes.
The examples use private directories, do not install the runtime or start a VM.

```sh
.tools/build-venv/bin/python scripts/check-worker-generations.py \
  --backend .tools/graphics-rebuild-backend-20261016

.tools/build-venv/bin/python scripts/graphics-wire1-sync-build.py \
  --renderer .tools/graphics-rebuild-renderer-20261016 \
  --backend .tools/graphics-rebuild-backend-20261016 \
  --output .tools/graphics-rebuild-generations4-20261017 --generations

.tools/build-venv/bin/python scripts/graphics-wire1-sync-qemu.py \
  --qemu .tools/graphics-rebuild-qemu-native-20261016 \
  --sync-renderer .tools/graphics-rebuild-generations4-20261017 \
  --output .tools/graphics-rebuild-generations-qemu3-20261017

.tools/build-venv/bin/python scripts/graphics-qemu-probe.py \
  --profile .tools/graphics-rebuild-qemu-native-20261016 \
  --sync-qemu .tools/graphics-rebuild-generations-qemu3-20261017 \
  --swift-receiver --label direct-generations-final6
```

The standalone real-native GPU check verifies 14,336 exact pixels, actual
backing reuse through the original FD, unchanged abandoned storage, and a
real 64-MiB allocation-budget rejection before destructive detachment. Its
deliberately unsafe cancel-as-ACK control must fail at `abandoned backing changed`.
It does not exercise the decoder or a guest.

The end-to-end probe instead sends actual Wire1 commands through real QEMU
virtqueues/decoder/backend and uses unchanged production Swift receiver/renderer
sources. It overwrites original source textures before connecting the reader,
holds old snapshots across updates/resize, and holds a blue snapshot across
disconnect while its original source is explicitly changed to green. A new
connection must receive magenta and still read the old blue snapshot intact.
Final ACKs are drained through the actual worker, rather than inferred from an
empty broker queue. Previously captured candidate images may be delivered on
selection changes; the fixture records skipped images and counts their ACKs.

## Recorded qualification, 2026-10-17

The final v3 QEMU run passed with the production Swift receiver and renderer:

| Observation | Actual result |
| --- | --- |
| Exact matching pixels, including three retained-image rechecks | 1,015,802 |
| Expected images / extra older candidate skipped | 19 / 1 |
| Consumer GPU reads / RFB uploads | 23 / 0 |
| Connections / geometry | 2 / 64×32 → 803×607 → 64×32 |
| QEMU sink copies / source mappings | 0 / 0 |
| Publisher backing allocations / mappings | 0 / 0 |
| Accepted external leases / exact ACKs / abandonment | 20 / 19 / 1 |
| Worker snapshot allocations / reuse from retained idle cache | 9 / 18 |
| Worker peak producer-owned bytes / retained busy generations | 7,849,408 / 5 |
| Worker retirements / received snapshots | 46 / 46 |
| Final broker pending / publisher occupied | 0 / 0 |

The worker's copy-before-Signal remains: this removes the **second** GPU copy,
not every copy. Reuse counts cover transfers out of the retained idle cache;
they omit ordinary reuse of a current Export's already-retired allocation.
Producer-owned cached/current allocations remain bounded while the context is
alive. The final listener detects disconnection; capture admission is false.
An anonymous resource without checked export/writer identity is rejected, and
its FLUSH does not resume the old unfenced fallback or publish another image.

Private positive receipt:
`.tools/graphics-rebuild-qemu-native-20261016/direct-generations-final6/result.json`,
SHA-256 `82476361a802fa1cd95255b4a74d6705d83f6ae0be0cffe1173242ea2eb7a94c`.

The causal `--withhold-producer-token` run completes the actual GPU fence at
value 2 but withholds the corresponding readiness token. It must exit nonzero,
log `producer completion timeout`, publish no initial image and leave the
reader reporting `native frame timeout`. This distinguishes actual producer
readiness from merely observing that some GPU work completed. The separately
compiled default host-v2 regression also passed: 19 QEMU sink GPU copies,
19 source mappings released, zero external submissions, six publisher backing
allocations/releases and 13 publisher backing reuses. Both paths drain their
outstanding broker/publisher slots, but the v3 path additionally waits for
actual worker retirement of all 46 snapshots.

Additional private receipts under `.tools/graphics-rebuild-qemu-native-20261016/`:

| Receipt | SHA-256 |
| --- | --- |
| `direct-generations-token7/result.json` (expected failure) | `de7e54a9f455dba52e90d515f00e641c7c7b49d4c247e12a3eca313df92a4a87` |
| `generations-v2-final8/result.json` (default regression pass) | `dce6f4a4eb0b125c6206e85813f4eaea6ee79bc08831a27450ef80037e243c10` |

`.build/checks/worker-generations/qualification.json` records the combined
verification: current protected source/dependency hashes, both actual QEMU
results, the withheld-token expected failure and the native-generation causal
fixture. Previous failed attempts remain separately preserved; an earlier
reader test closed its socket before the final queued ACK drained, correctly
producing a second abandonment. The final test waits for that real ACK and
does not relabel disconnect as successful acknowledgment.

These checks execute no guest CPU or disks and perform no visible presentation.
They do not measure Windows interaction latency, frame pacing, real GPU-driver
mapping of odd-sized blobs, arbitrary multi-context producers, shutdown with
pending GPU work, installed-app 3D stability or resource consumption in normal
use. Default startup still initializes Cocoa/ANGLE. The subsequent opt-in
[native headless backend](../experimental/native-metal-headless/README.md)
qualifies windowless startup with these actual decoder/receiver fixtures;
installed-app and running-Windows qualification remain outstanding.
