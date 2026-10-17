# Windows 3D inside the native application

2026-10-16: the private native-client candidate now displays the real Windows
ARM64 desktop and Edge WebGL2 output inside its own existing Metal console.
Mouse, keyboard and automatic resolution selection work on this path. The
ordinary installed application still uses its validated 2D runtime. This is an
integration checkpoint, not production packaging or performance parity.

A subsequent direct-source candidate now also boots the same Windows guest and
displays Edge in the native client without showing the producer's Cocoa window.
The newer run and its unresolved presentation loss are recorded under
[Hidden direct-source run](#hidden-direct-source-run). Earlier observations
below retain their original runtime scope.

## Source-level backing reuse follow-up

A later source change adds a bounded cache to the independent Metal publisher.
Only an exact consumer ACK makes a backing reusable; device, dimensions and
connection generation must match. New frames retain distinct readiness pipes
and identities, and disconnect discards unacknowledged storage. Geometry
misses evict idle mismatches rather than forcing repeated allocation forever.
There remain at most two active snapshot leases plus two cached idle backings.
The GPU snapshot copy itself is unchanged.

On the current host, the expanded real-Metal/two-process fixture passed 40
frames and 20,196,019 exact pixels, including a reused-buffer GPU gate, resize
and an old unacknowledged mapping retained across reconnect. Its first 35
frames used two backing allocations; a private no-cache control allocated 35.
The complete run used four backing allocations and 36 reuses, and drained all
captures/backings/mappings at shutdown. Private controls that retain only old
sizes or recycle an unacknowledged snapshot fail the resize and old-image
checks respectively. The native receiver and external-presenter suites also
passed their GPU-before-ACK, replacement, reset and disconnect checks.

The publisher has subsequently been compiled into a fresh current-host QEMU
candidate and exercised through real decoder-created native scanouts. A separate
Metal reader passed 19 snapshots, resize and reconnect with 1,015,802 exact
pixels and no reader frames left at exit. That fixture explicitly waits for
the producer's real GPU fence before each scanout; it does not qualify the
automatic Windows writer barrier or producer reuse counts in QEMU. See the
[current verification ledger](VERIFICATION.md#actual-qemu-native-scanout--metal-reader--2026-10-17).
It is not installed or tested with Windows; the earlier live Windows results
below still belong to their frozen artifacts. Writer synchronization, measured
Windows presentation/latency and installed 3D integration remain outstanding.
[Publisher contract and tests](../experimental/cocoa-native-display/README.md).

## Hidden direct-source run

The first combined direct-source/STP candidate launched after correcting a
trial-client TPM executable mismatch (bundled versus pinned Homebrew swtpm).
That initial refusal occurred before QEMU and was not a graphics failure.
The actual subsequent QEMU PID 1940 handled one zero-offset STP Q store, then
aborted on the adjacent signed-offset instruction. The original failure and
null exit-code field were preserved. An offline qcow2 check found no image
errors; it does not certify the Windows filesystem.

The next candidate combines the signed-offset extension described in
[the HVF experiment](../experimental/hvf-stp-pci-hole/README.md) with direct
scanout publication and a hidden internal Cocoa window. It retains the view,
Metal/EGL context, queue and event loop; this is not a windowless engine. The
hidden producer skips the firmware/2D EGL swap path, avoiding a wait for an
invisible drawable. Direct 3D snapshots occur before Cocoa drawable acquisition.
One immutable GPU snapshot copy and unique per-frame allocation still remain.

Build receipt: `.tools/cocoa-native-display-build/direct-stp2-hidden/build.json`.
Only three display objects and the HVF object changed relative to its seed;
GPU/PCI/reset objects and 3375 protected inputs were verified unchanged.
Signed candidate SHA-256:
`4249af46e8a1a2aa1bec545b9737f15148d0831cefc0ac3558406a31b091cce4`.
Packaged executable SHA-256:
`e319fdf585fc59834afa015915ac1f8e8922e6a4161cbcd7cb5082ed0717e41c`.
Strict signature verification passed with only the Hypervisor entitlement.
Decoder/range tests under ASan/UBSan exhaust 4194314 cases; the actual HVF
translation unit compiled and linked. Those checks alone do not qualify every
hardware fault path or prove a general shutdown fix.

The existing guest started as QEMU PID 4503 with native client PID 4424. Actual
visible observations: Windows desktop, Edge, an automatically selected
2048×1152 desktop and a rotating WebGL2 triangle, with no separate producer
window. No VM copy, driver replacement or security-setting change was made.
The ordinary installed application still uses its earlier 2D runtime.

The local browser probe completed 110 warm-up and 1651 measured draws in
2013.2/30014.5 ms respectively. rAF spacing median 16.8 ms, p95 31.7 ms,
maximum 625.8 ms, with 8 gaps above 50 ms. Shaders linked, verification pixel was
97/78/80/255, with no GL errors, context loss or document visibility change.
Private report: `.tools/windows-browser-webgl2-direct1.json`. Guest rAF is not
Mac presentation FPS or input latency.

A separate host recorder sampled the live native telemetry every 0.5 seconds.
Within a 25.311-second continuous interval of that workload it observed 900
received frames, 899 GPU completions, 380 positive drawable presentation
callbacks and 520 callbacks with `presentedTime == 0`. This is approximately
35.56 received and15.01 confirmed presentations per second. There were no
connection failures or resets in that interval. This interval is not the exact
guest 30-second interval, an A/B comparison or a physical-photon measurement.
Private samples/derived summary:
`.tools/native-direct2-probe-host-samples.jsonl` and
`.tools/native-direct2-probe-host-summary.json`.

The direct path is therefore functionally exercised, but poor presentation
remains a measured problem. GPU completion is not counted as visible output.
Next discrimination: exercise the unchanged presenter with host-generated GPU
snapshots to separate presenter/compositor loss from guest/producer delivery.
Source-writer synchronization, buffer pooling, local cursor, input-to-visible
latency and installed 3D runtime integration remain incomplete.

### Subsequent presentation, resize and shutdown checks

In the same live guest and unchanged client, entering full screen selected
1920×1440 automatically and returning selected 2048×1152. A second identical
browser probe at full screen produced 1759 measured draws in 30009.5 ms,
median 16.1/p95 31.6 ms, maximum 33.8 ms, with no gaps above 50 ms or GL/context/
visibility errors. In a separate 25.260-second central host interval there were
1147 received/completed frames, 693 positive presentation callbacks and 454
zero-time callbacks: 45.41 received versus 27.43 confirmed presentations/sec.
Different desktop geometry means this is not a controlled improvement over the
earlier windowed run. Private reports use the `direct2-fullscreen` and
`native-direct2-fullscreen-host-*` names under `.tools/`.

A host-only fixture using the unchanged presenter completed 707 GPU commands;
its latest 256 positive presentation intervals had median 16.667375 ms and
p95 16.667625 ms. This shows a stable 60 Hz tail is possible in that fixture, not
that the embedded Windows path achieves it. The initial activation period was
mixed, so total counts divided by 12 seconds are not reported as steady FPS.

A proposed removal of the native console parent's per-frame invalidation was
compiled and exercised privately, then withdrawn from source. The client
reconnected and displayed Windows, but later resize/reconnect transitions
stalled on a black reconnecting view; a matched performance comparison was not
obtained. Its first launch also lacked the required telemetry directory and
therefore supplied no measurements. That directory must exist with mode 0700
before the recorder is first initialized. No resulting performance gain is
claimed and the proposed policy is not included in the app source.

The new parent-clean/parent-dirty host probes both completed and drained every
lease. Neither met their explicit active/key/visibility admission, so neither
is accepted as a steady A/B result. Their differing raw presentation counts
cannot establish causality under those conditions. Retained results:
`.tools/visible-presentation-parent-ab2/{parent-clean,parent-dirty}/`.
The standalone fixture and the pair are documented in
[native display telemetry](NATIVE_DISPLAY_TELEMETRY.md#explicit-visible-host-probe).

One passive sample of the stalled own QEMU process found the Cocoa event loop
and QEMU main loop waiting normally, rather than blocked in `nextDrawable` or
`eglSwapBuffers`. This bounded observation does not support an EGL deadlock
explanation for that instant. Windows Guest Tools still answered a read-only
display query with the actual 3D adapter and 1920×1440. Reconnect and resize
reliability remain unresolved.

Finally, a normal ACPI shutdown of the same QEMU PID 4503 completed at
15:42:35 UTC with matching supervisor launch identity, success=true and exit 0.
No assertion or STP-emulation log occurred in this launch. This qualifies one
successful boot/workload/shutdown cycle, not proof that the new signed-offset
branch executed or that all shutdown failures are fixed. The existing VM is
now stopped; no force stop or new VM copy was used. Private exact receipt:
`.tools/native-direct2-clean-shutdown.json`.

## Actual Windows run

The existing Windows 11 — 3D Trial was reused, without another VM copy.
The matching Wire1 renderer/DMTX v2 backend, signed ARM64 guest driver, PCI8
Neptune/BLOB and 4 KiB HVF configuration are unchanged from the
[earlier Windows checkpoint](NEPTUNE_WINDOWS_3D_CHECKPOINT.md).

Initial native launch identity:
`perpendicular-12755108-83c6-4790-b477-58ca87b1a00e-1bb850daaaed4ed593dae63e691405a7`.
The owned QEMU PID was 65674. The engine advertised its native endpoint only
after verifying the live owned process, matching QMP identity and private
runtime socket. The client verified the exact server PID, UID and launch
session independently.

Initial packaged QEMU SHA-256:
`22e73fa76f42e9c6883af48aa8a04a5debf93778799f811a85ad60cae18a3ae8`.
Private client executable SHA-256:
`64876abce644497ccaf39b28e9a0ee21d23f067bb72f12ce61f0a37e6b626a9c`.
Its bundle ID is `org.perpendicular.desktop.native-trial`; it was built with
`PERPENDICULAR_NATIVE_DISPLAY=1` and was not installed over the ordinary app.

Observed through the real app window:

- Windows desktop, then Edge opened by a double-click in the embedded console.
- The complete local HTTP address, including colon and punctuation, typed
  correctly through the existing RFB keyboard path.
- The compiled WebGL2 RGB triangle, visible during warm-up and near the end of
  the 30-second measurement, while the QEMU Cocoa window was in the background.
- After Guest Tools recovery, automatic selection of 1920×1200 in the library
  console, 1920×1440 in full screen, then 1920×1200 on return. Guest status and
  app framebuffer confirmation agreed, and the displayed image resized.

The last item selects among driver-enumerated modes. It does not establish
arbitrary-size modes, dynamic DPI or a successful manual border-drag test.

## Browser measurement

The same [owned WebGL2 probe](../experimental/windows-browser-probe/README.md)
used in the previous Cocoa baseline completed again through the native app.
Raw private report: `.tools/windows-browser-webgl2-native1.json`, SHA-256
`66fe2f2f9c1926a278ba9f95f7665b3a7ca37237a79910496051561db95a6d59`.

| Check | Result |
| --- | --- |
| Canvas / initial desktop | 800×450 / 1280×1024 |
| Warm-up draws / elapsed | 119 / 2014.6 ms |
| Measured draws / elapsed | 1742 / 30031.9 ms |
| rAF spacing median / p95 | 16.5 / 32.1 ms |
| Minimum / maximum spacing | 1.1 / 35.1 ms |
| Gaps greater than 50 ms | 0 |
| Shader compile / link | success |
| GL errors / context loss / visibility change | none / false / false |
| Verification pixel RGBA | 97, 78, 80, 255 |
| Renderer | ANGLE, VirtIO 1AF4:1050, Direct3D11 vs_5_0 ps_5_0 |

This measures guest browser callback spacing and one shader pixel. It does
not measure physical Mac display FPS, native presentation pacing, input latency
or prove host acceleration by itself. The full-path claim uses the separate
matched-backend evidence, FD/Metal fixtures and actual visible app output.
The previous Cocoa-only result was 1762 measured draws, median16.1/p9531.7ms;
these are individual observations, not a controlled performance comparison.

## Transport and presentation

[The publisher](../experimental/cocoa-native-display/README.md) adds a GPU blit
from the existing completed-console drawable to unique, immediately-unlinked
FD-backed storage in the same command buffer. Only GPU completion publishes
that frame. This adds one GPU snapshot copy. There is no CPU pixel readback or
CPU pixel copy in the production publisher/receiver path.

[The transport](../experimental/native-display-transport/README.md) passes two
FDs with each fixed-layout frame: immutable backing and actual readiness pipe.
The native client maps it into a Metal buffer/texture with bytesNoCopy. The
presenter keeps its current lease available for redraw and acknowledges only
on retirement after all consumer GPU reads. Two outstanding snapshots and a
replaceable pending delivery bound memory and backlog. Disconnect never grants
permission to overwrite an outstanding allocation.

RFB remains connected for input, layout and firmware/2D surfaces. Once native
output activates, RFB pixels cannot replace it or disguise a broken 3D stream.
The native feature is opt-in at build time; historical JSON without an endpoint
and ordinary builds retain the previous path.

This still depends on the separate Cocoa window/drawable and does not establish
correspondence with every Windows Present: the current native scanout ABI has
no per-resource producer fence. Removing that window dependency, reducing the
extra GPU copy and measuring actual presentation remain required work.

## Direct source candidate

The explicit `PERP_NATIVE_DISPLAY_DIRECT=1` branch in the copied QEMU backend
now encodes the selected renderer texture/crop directly into an immutable NDT
snapshot. It returns before acquiring or presenting a Cocoa drawable. This
removes the intermediate drawable copy/presentation from this branch while
retaining one GPU snapshot copy, source-read ownership through completion and
the existing native client's retirement/ACK contract. Cocoa context/window
construction and the upstream producer-fence limitation remain.

The final source passed the actual two-process Metal fixture: nonzero crops,
bottom-right edge, immutable held frame, GPU completion gate, twelve invalid
inputs, two-slot backpressure and ACK recovery, with all resources released.
Changing just the source crop origin to zero fails the pixel check. Legacy
full-frame and static-reconnect regressions also passed. These are host tests,
not guest/display performance measurements.

A fresh full private QEMU build and strict code-signature verification passed.
Candidate SHA-256:
`c631e4ffa1ab77888edbcbcd188bd0c147c8d76143926700ea3661f45eeb0383`.
Build receipt `.tools/cocoa-native-display-build/direct-source1/build.json`,
SHA-256 `fd967a4e76c58fd9ab7a54dda1ccb7929a99296cc189cdad86ed6df9a27a5dcd`,
records all 3,310 protected inputs unchanged, no installation/packaging and no
VM start. This uses the builder's original trace3 GPU profile; the later STP/HVF
diagnostic combination has not yet been relinked with this source change.

Next acceptance work: combine that known diagnostic profile, reuse the existing
VM for an actual direct-mode launch, verify static reconnect and resize, then
compare visible presentation and input latency under the same workload. No
fluidity improvement is claimed from the successful build or host fixture.

## Qualification and defects found

The full `PERPENDICULAR_METAL_TESTS=1 scripts/check.sh` passed after integration:
52 Rust checks, native console/client/window/sizing checks, packaging fixtures,
existing presenter checks, 50 external-lease checks and 11 real two-process
receiver/Metal checks. The latter verified 9344 GPU-read pixels and zero RFB
uploads. Separately, the bounded C transport passed 28 cases repeatedly with
ASan/UBSan, partial records and surplus-FD leak checks. These scopes do not
substitute for Windows integration.

The real tab-switch test exposed black output for a static scene after native
reconnect. A guest click/Ctrl+R immediately restored it. The source confirms
that accepting a client did not request the current Cocoa image. The publisher
now raises a generation-bound refresh demand on accept; the existing QEMU main
loop retries until a completed snapshot is queued. Diskless Metal tests cover
three connections, static-image replay without guest renders, reset with two
GPU completions withheld and full resource release. Removing only the accept
signal reproduces the regression. Windows acceptance of that correction is
recorded below after the fresh candidate run.

The same boot exposed a Guest Tools startup failure: owned task Ready/result1,
zero agent processes, healthy controller and accessible port. The current
health log recorded a channel reset with HRESULT8007022A followed by fatal
channel_request and stop. An exception from FileStream.Dispose escaped the
retry finally. The agent now catches only channel-port close failures, logs a
bounded channel_close event and retries; startup and final mutex failures
remain fatal. The exact production-loop fault fixture passes all58 checks
inside Windows PowerShell5.1.26100.9711/.NET4.0.30319.42000, including a causal
pre-fix failure and a successful second connection. Private report:
`.tools/windows-tools-native3-fixture.txt`. The replacement agent SHA-256 is
`beceef3d94607e884670c7716aa0ddebdd3b9f46ae1e0e4bb244699d9d0d224e`.

No driver, ACL, Secure Boot or signature policy change was needed for these
two fixes. Automatic startup, fresh candidate reconnect and sustained resize
acceptance are separate gates from the passing fault fixtures.

## Shutdown failure retained

After the first native session, the explicit Windows `shutdown.exe /s /t0`
request did not produce a clean host exit. QEMU aborted at
`hvf_vcpu_exec`, `hvf.c:2295`, `assert(isv)`. Its exit record retains
`success=false` and a null exit code; it has not been rewritten as a normal
shutdown. The crash report attributes SIGABRT to the vCPU thread. The launch
already used the explicit4KiB IPA option, so this separate invalid-syndrome
path remains unresolved. The preceding GPU command error is
RESOURCE_UNREF/INVALID_RESOURCE_ID; chronology alone does not establish it as
the cause of the hypervisor exception.

A read-only offline qcow2 structural check found no image errors. This does
not establish guest filesystem consistency. The exact reaped launch/PID and
three ledger hashes were retained before preparing another run of the same
VM. No disk, TPM, firmware or VM copy was replaced. Private evidence:
`.tools/native-output1-crash.json`, `.tools/native-output1-qemu.log` and
`.tools/native-output1-exit.json`.

The agent-only update did complete after waiting for the old task's process to
exit. Installed hash was verified, the exact owned task was restarted, one
agent process was reported and the real guest-status RPC connected. Supporting
sources, driver and permissions were unchanged. Update receipt:
`.tools/windows-tools-native5-update.txt`, SHA-256
`482f357ece8b54a6b1e193ddd7c81b5859dbb2169ce27dca7e5f66a7ac26e356`.

## Fresh corrected candidate acceptance

The next run used packaged QEMU SHA-256
`33741f762ec62490e27dbe021af8002a97378ccb0566be82741ca08b1ac2c2aa`
(private build3, source candidate
`521a110053529f251cc60cb0c2267b47ab771dbb16fb72a4c4478212e668974c`).
Launch identity:
`perpendicular-12755108-83c6-4790-b477-58ca87b1a00e-3fdfbb15405349c29ed204899c4df0c7`,
QEMU PID72915. This uses the refresh correction; no hypervisor behavior was
changed. Original source/build inputs remained unchanged in the private build.

With Windows on a static desktop, switching from Display to Guest Tools and
back now immediately restores the native image without any guest key, click
or redraw request. After the agent connected, Check Display again selected
1920×1200 and the native output adapted.

The updated agent also started automatically in this boot. No manual task
start or agent command was issued. The captured diagnostic reports the exact
installed updated hash, owned task Running and one owned agent process PID4776.
Crucially, it records the same actual `8007022A` reset followed by
`channel_close` at12:26:10UTC, then a successful `channel_request` at12:27:03UTC
instead of the previous fatal stop. Real guest-status and file-write RPCs then
succeeded. This validates recovery in addition to the fault fixture.

The guest's last boot was12:24:10UTC; agent starting was12:26:05UTC. The app's
old bounded startup polling had already given up before the agent was ready,
so automatic readiness admission still needs a longer bounded window. This
boot does not claim that sizing recovered automatically without Check Display.
Private acceptance: `.tools/native-output2-integration.json` and
`.tools/windows-tools-native6-boot.txt`, whose SHA-256 is
`c3a4a3f91733a79ca5c2ae0662f6ab959b93df24bc06e89c7c2fb5b3c34ea341`.

The hypervisor shutdown assertion, final runtime packaging, removal of the
separate Cocoa window, per-Present synchronization and measured host pacing
remain unresolved. Passing these new display/agent checks does not close them.

The same corrected run also changed the actual available display width by
collapsing the host sidebar: the guest and native framebuffer confirmed
2048×1152 automatically. Reopening the sidebar restored the ordinary layout.
This adds a real viewport-width change to the earlier full-screen transition;
it still does not claim a successful manual border-drag operation.

Startup admission has now been extended in source to an absolute180-second
window, at most12 capability observations, only for absent/timeout startup
transport responses. Terminal errors and mutation retry limits are unchanged.
The delayed-agent fixture with135 simulated seconds passes; restoring the old
60-second window fails the same fixture. Real cold-boot acceptance of this new
UI policy is pending the next private client build/run.

Final combined validation also passed with both opt-ins enabled:
`PERPENDICULAR_METAL_TESTS=1 PERPENDICULAR_POWERSHELL=<existing-host-pwsh> scripts/check.sh`.
This includes the final135-second startup fixture, Guest Tools reconnect checks,
the external/receiver Metal checks and both actual publisher GPU fixtures.
Private complete log: `.build/checks/native-integration3.log`.

## Subsequent window and shutdown checks

The private native client2 build includes the180-second admission policy and
passed strict bundle signature validation. On the already running guest, a
host window zoom selected1920×1440; restoring the window by double-clicking its
title bar automatically selected1920×1200. Both modes displayed actual native
Windows pixels. This is a real host window size change, separate from the
previous unsuccessful border-drag attempt.

An intervening black image was also present in the producer's Cocoa window;
one guest click restored both producer and native client. A read-only Windows
`powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE` then reported300 seconds
on AC and180 seconds on battery. This supports display inactivity as an
explanation; it does not establish an additional Metal resize defect or prove
that every black-frame case is inactivity. Power policy was unchanged.

A second full guest shutdown reproduced the existing `assert(isv)` abort at
12:51:41UTC in PID72915. The original failure ledger and private full log were
preserved. An offline qcow2 check again reported no image errors; that check
does not certify the guest filesystem. No new VM copy was made.

The diagnostic-only HVF insertion was separately compiled and linked into a
fresh native candidate while preserving the existing Cocoa/publisher/transport
objects and all3320 recorded protected inputs. Strict signing retains only the
Hypervisor entitlement. Packaged binary SHA-256:
`dc0782d1682c5c0c1d18a92362fb3fc0e21fb57d47ad09993dd29defc2af0d1b`.
It retains the abort and adds only bounded fault metadata, with no emulation,
PC adjustment, guest memory read or mapping change. The same existing VM was
started with this diagnostic candidate at12:52:43UTC, PID81708. The native client survived the stopped/running transition, automatically
reconnected to the new authenticated endpoint and displayed the boot/login
sequence. Cold-boot sizing then confirmed1920×1200 without Check Display,
console/tab switching, viewport changes or a manual agent start. An independent
read-only guest-status probe first returned unavailable/timeout; a later
read-only display-status query confirmed the actual3D adapter and1920×1200.
The successful UI observation preceded opening any diagnostic guest shell.
The next shutdown did reproduce the failure and captured the metadata below;
this candidate is diagnostic only, not a shutdown fix.
Private build/package receipts are in `.tools/cocoa-native-display-build/hvf1/`
and `.tools/cocoa-native-display-hvf1/`; prior failure evidence is under
`.tools/native-output2-*`.

The second guest boot report confirms the installed fixed agent autostarted as
one owned process PID4856 at12:55:15UTC, about144seconds after Windows boot.
Actual reset/close `8007022A` recurred and recovered to a successful request.
This further validates both the bounded longer startup admission and the close
exception correction. Private report `.tools/windows-tools-native7-boot.txt`,
SHA-256 `ed9945aa6d5107714d1bcbcfd1f81aaa28768c3a9636da6336180aba4cec69b2`.


The diagnostic run aborted at12:59:41UTC during the next full guest shutdown.
The new event reports ISV=0, a write, valid PC/FAR, FSC0x06 and a FlatView match
to `gpex_mmio_window`, with no RAM/ROM/ROMD backing and no dirty logging. Thus
this particular fault is not identified as a mapped RAM dirty-write trap. It
points to an unassigned PCI MMIO access at the captured instant; it does not
yet prove which resource previously occupied the address or whether a guest
reference outlived an unmap. Raw guest addresses remain in the private receipt
`.tools/native-hvf1-failure.json`, alongside the preserved launch/exit/log.
The original assertion remained and the failure ledger records the real abort.
A further offline qcow2 check reported no image errors. The VM is stopped;
no new copy, driver replacement, signature change or security exception was
introduced for this diagnostic run. Next work is to correlate the fault with
GPU BAR/resource map/unmap lifetime before choosing a correction.
