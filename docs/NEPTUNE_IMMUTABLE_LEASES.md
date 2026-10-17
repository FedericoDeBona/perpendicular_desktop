# Immutable native scanout generations

This is an opt-in private host extension. It preserves the matched renderer
`d3c970599eb0bfbfe417b86d87fc0e0641da9512`, native backend
`917b721c0f915c6524b416169fdce4427a39524f`, guest Wire1 and native DMTX v2
descriptor. Private broker version **3** is distinct from those guest/native
versions. Host v2 remains the default build recipe.

## Imported inputs and exclusive outputs — 2026-10-17

The worker now admits incoming textures without invalidating every independent
output in that process. The proxy still taints each attached source before
another worker can import it. An owned source can be reopened only after its
exact denial handshake has stopped future copies and completed all queued
copies, including retained generations. The same-context open fast path cannot
substitute for that handshake: it returns E_INVALIDARG without it.

Successful imports retain their canonical COM identity in a bounded 256-entry
worker registry. Reexporting an imported texture, including through a COM
interface alias, does not make it an exclusively owned capture source. Held
references prevent pointer reuse from changing this identity. Exhaustion stops
capture, and references are released at worker teardown. Reclaiming this
metadata during a long-lived worker remains a lifecycle limitation; the 64-MiB
snapshot limit does not bound all source/import resource memory.

The actual decoder/virtqueue test can now use two independent renderer workers
with separate reply/ring memory. `--import-input` waits for the fixture's foreign
producer, imports its red texture into the display worker, and copies that
input into the worker's independent output. Both private and relocated app
runtimes then pass the existing 19-image, 1,015,802-pixel sequence with twelve
additional sources, held-image checks, resize and reconnect. This explicitly
waited input fixture does not prove arbitrary Windows interprocess ordering.

Three real-path controls retain the first red image and require the next image
to time out: `--import-owned-output` rejects reopening without the completed
denial; `--import-selected-output` completes foreign import and a subsequent
owned reopen while suppressing new captures of that shared output;
`--reexport-input` repaints the imported input in its foreign worker and proves
that a fresh export/resource ID cannot turn it into a capture source. The held
red pixels remain unchanged in every case. None of these controls is an
accepted passing presentation run.

Receipts under `.tools/graphics-rebuild-qemu-native-20261016/`:

| Case | Receipt SHA-256 | Outcome |
| --- | --- | --- |
| `imports2-positive1` | `01d5eb3794201507e356b3750a55c382a5fa68a6226ba303f71eb7aeab4f41c6` | Pass |
| `imports2-packaged1` | `b4b264fbf4c2ab85ea2bec3c9089f67e3070408b6f9274390334ae5a947d2470` | Pass |
| `imports2-owned-negative1` | `fbed7ab102182feab78aa751b43d6cd17cbcdacc94c8e0de48be01037acad3bf` | Expected frame timeout |
| `imports2-output-negative1` | `56663efb17f3297f835ffbd3a225cc3769cc0788f26ae868a458e4ab242c7057` | Expected frame timeout |
| `imports2-reexport-negative2` | `00dce42f36bb00fdc57c3039838d01a0a073708d1c66b82389dfbfeac86cc396` | Expected frame timeout, queried COM alias |

Windows still reports its 3D controller at 2048×1152, but native delivery
remains closed with one worker rejection and no published snapshot. The
rejection's exact operation is not distinguished by its current generic log.
Owned-source reopening, multiple fences/rings and shutdown remain unqualified;
the installed application has not been changed. The same VM was restored to
the clean 2D checkpoint with the driver staged but inactive after the trial.

## Selected-source capture — 2026-10-17

The current broker separates source identity metadata (256 bounded entries)
from immutable snapshot storage. It grants capture for the selected scanout
source instead of copying every exported surface. A new selection replaces
future worker capture admission while preserving old resource/worker identities
for already queued frames and exact ACKs. Unselected sources do not consume
snapshot allocations. The existing 64-MiB producer allocation budget and eight
retained/cache slots remain unchanged. Source ID reuse and table exhaustion
still fail closed; this is not an unbounded resource-lifecycle implementation.

The real decoder/virtqueue test now optionally keeps twelve extra shared
textures alive (`--source-pressure`). Both private and relocated application
runtimes delivered 19 images with 1,015,802 exact checked pixels, held images
across resize and disconnect, two connections, zero RFB uploads and no pending
leases at completion. Only 19 worker snapshots were received, compared with 46
in the preceding packaged run of the same presentation sequence. No unselected
snapshot was copied or cancelled. Five allocations served 19 retirements;
the `worker_reuses` field counts transfers from the retained idle cache only,
so its zero value does not count reuse of an Export's current allocation.
Peak producer snapshot storage was 3,928,800 bytes. One disconnected allocation
was abandoned, and its retained old image remained intact.

Withheld completion still prevents publication even after the actual producer
GPU fence completes. Withholding the green update still fails its pixel check.
Passing receipts: `selected-pressure2/result.json` SHA-256
`372c9a408f469047acf06e85c6d66b546063ece127718b00691c7ea405a1da72`,
`selected-packaged1/result.json` SHA-256
`9088e0d643ad0c1f380289d84f4d6055084abf0c739eb7c6a207b2f9f6923e68`,
under `.tools/graphics-rebuild-qemu-native-20261016/`.

The same VM trial still has black output. The old fifth-export failure no
longer occurs; the single remaining worker rejection follows unrelated shared
resource imports into the compositor. Static inspection confirms that the
current import hook invalidates the entire worker, beyond the proxy's existing
per-resource denial handshake. Correctly admitting unrelated input imports
while retaining denial of imported output sources remains unfinished. Multiple
producer fences/rings and resource lifecycle also remain unqualified. These
diskless pixel results do not establish Windows presentation or latency.

The VM shutdown again reached an unsupported ISV0 write in the GPEX unassigned
PCI window. The VM-runtime builder now carries the existing read-only abort
diagnostic immediately before the retained assertion; raw addresses stay in
private receipts. No instruction is skipped or new emulation admitted. The
same VM was restored to its clean 2D checkpoint with the driver staged only.

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
