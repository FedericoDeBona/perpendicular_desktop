# First Windows ARM64 Direct3D checkpoint

2026-10-16: the signed Windows ARM64 driver now creates a hardware Direct3D11
Device on VirtIO and presents both the independent color-pattern scene and a
compiled-shader RGB triangle through the experimental Cocoa display.
Edge also selects that adapter for its ANGLE D3D11 path. This is a positive Windows checkpoint;
it is not application compatibility, Parallels performance parity or a
production-ready graphics package.

## Matched configuration

The existing trial VM/disk was reused throughout; no further VM copies were
created. Secure Boot and kernel signature enforcement were retained. The
ordinary installed app still uses its previously validated 2D runtime.

- Whole renderer/server: `utmapp/virglrenderer` commit
  `d3c970599eb0bfbfe417b86d87fc0e0641da9512`, internal wire version 1.
- Whole native backend: `utmapp/dxmt` commit
  `917b721c0f915c6524b416169fdce4427a39524f`, matching DMTX v2 texture ABI.
- Existing signed QEMU10 diagnostic candidate `0bc3e2c35b41af1fd4313729d37e490af357def0141a91eb02807f203c265339`.
- Public HVF option `-accel hvf,ipa-granule-size=4096`.
- Scoped loader order: Wire1 renderer library, matching backend library,
  original supporting libraries, ANGLE. All three `NPT_*_LIBRARY_PATH` settings
  name the matching backend; `RENDER_SERVER_EXEC_PATH` names the Wire1 server.
- PCI8 `virtio-gpu-gl-pci`, Neptune/BLOB enabled, 256 MiB host-visible memory;
  a separate firmware RAMFB console supplies a diagnostic fallback.

Actual dyld output from the Windows run verifies the intended renderer and
backend, including renderer workers. Environment variables or the renderer's
printed requested filename alone were not accepted as loading evidence.
Source/build/test recipes are in [renderer](../experimental/neptune-wire1/README.md),
[backend](../experimental/neptune-wire1-backend/README.md) and
[loader/IPA checks](../experimental/neptune-wire1-backend/LOADER_IPA.md).

## Problems identified before the positive run

The released signed UMD rejects wire2 before context initialization; see
[the binary analysis](NEPTUNE_DRIVER_WIRE_COMPATIBILITY.md). The old renderer
also needs the older shared-texture ABI. Merely changing a version constant
would not repair either boundary.

A diagnostic boot showed Code43/ProblemStatus0, oem5.inf and driver version
100.6.101.58000. Windows reported its kernel boot time from the earlier 11:26
session despite later VM launches, consistent with Fast Startup retaining the
failed state. A native `shutdown /s /t 0` completed before the next cold boot;
no global hibernation policy was changed.

That next boot created Neptune context7, then QEMU asserted at
`target/arm/hvf/hvf.c:2295` (`isv`) after rejecting 4 KiB-aligned blob mappings
under its default 16 KiB mapping guard. It also exposed an incorrect loader
order: the original DXMT loaded despite the requested new absolute filename.
That failed run is not attributed to the matching backend.

Separate paused-CPU fixtures verified both the corrected actual loader paths
and the public 4 KiB IPA mode. The latter accepted three distinct blob backings
that the default mode rejected. The subsequent Windows run has shown neither
those alignment warnings nor that assertion in the observed interval.
A read-only qcow2 structural check after the crash found no errors; that does
not establish a clean Windows filesystem.

## Windows Device result

The corrected independent [probe](../experimental/windows-3d-probe/README.md)
completed at `2026-10-16T10:38:43.7447425Z`:

| Check | Actual result |
| --- | --- |
| Device mode | success=true |
| Native ARM64 | true; native machine AA64 |
| D3D11CreateDevice HARDWARE | S_OK, feature level11_1 |
| Adapter | Red Hat VirtIO GPU3D controller |
| PCI vendor/device | 1AF4:1050 |
| Software adapter/fallback | false/false |
| Intended adapter verified | true |
| Own-process UMD inventory | complete |

The loaded ARM64 UMD's on-disk SHA-256 is
`8fbb509b3b5e2a06b67392fe6b711832227e1ab802e096bf7d723ace6c66b437`,
matching the reviewed release. The shim hash is
`bb181fe8c67c18b597ca9a34078195a6d506e282e72c18ed9da49c151c19257f`.
The report's `host_acceleration_verified` remains false by design: this probe
alone does not inspect host execution. Host loading/texture/visible-output
observations are separate evidence.

Private captured Device report:
`.tools/windows-3d-device-positive-ipa4k.json`, SHA-256
`5418cd5086cc4c00a322f4d77b1a6765d98bb746055f1a32cec1a6a71779b79e`.
C# source SHA-256: `28cb9b46f8e698506b2f850f563276de4e61164f59df3e5c215cf7507a7d1ecd`;
launcher SHA-256: `cf6af725a1aaa11ef00b82ed59ed1abb1d385d37a67f272e77666dc766a64a1e`.

## Scene and visible output

Two windowed 800×600, BGRA8, flip-discard scene reports were read in the native
Windows console. Each recorded 600 Present attempts, 600 S_OK results, zero
occluded presents and S_OK GetDeviceRemovedReason. Elapsed scene-loop times
were 10,883 ms and 10,300 ms. The second run was specifically repeated to close
the visual-evidence gap: the real Cocoa console showed the probe's colored
rectangles/barcode, with its window title reporting accepted Present533.
The second guest report is `Downloads/scene-ipa4k2.json`. Its raw contents were
captured privately at `.tools/windows-3d-scene-positive-ipa4k2.json`, SHA-256
`d0ea04ebabf0f3cec977ba3cdea7d56d01c45a35a9b243c583057a06df58415e`.
It confirms success=true, native ARM64, the intended VirtIO adapter, complete
UMD inventory and the same probe/launcher source hashes as the Device result.

These are small Clear/ClearView color-pattern presentation checks, not a
shader/geometry benchmark or a count of every physically displayed frame.
They do not measure input latency, frame pacing, browser acceleration, video,
games, long-run stability or comparison with Parallels. Renderer/backend builds
still use optimization0. The probe also printed a renderer-ready wire1 message;
this is a guest diagnostic, not a separately captured raw capset byte stream.

## Remaining work

1. Measure browser/application workloads, frame pacing and interaction beyond
   the bounded triangle check; WebGPU and accelerated rasterization remain gaps.
2. Qualify Guest Tools startup after a new cold boot in the experimental profile;
   manual recovery now responds, but automatic resolution/reconnect and clipboard
   still need end-to-end qualification here.
3. Package the coherent graphics profile into the app with simple driver setup
   and recovery, then validate cold boot, shutdown and repeated use.
4. Use optimized builds and measure frame pacing, input latency, copies,
   CPU/GPU/memory use and regression against the 2D baseline before tuning.

Private runtime receipts include `windows-3d-wire1-full-cold1.json` (failed
pre-4K/incorrect-backend run), `windows-3d-wire1-ipa4k-qmp1.json` and
`windows-3d-wire1-ipa4k-boot1.json`. The successful VM run is PID52762/launch
suffix `98af7b0c0e1d44f186b5ec93d4578b04`; historical PIDs do not select a live
process for future control.

## Geometry result and browser adapter qualification

A separate Geometry run compiled original HLSL using Windows System32
`d3dcompiler_47.dll`, created both `vs_4_0` and `ps_4_0` shaders, and submitted
`Draw(3,0)` before each Present. Native ARM64 PowerShell5.1, adapter1AF4:1050
and the same reviewed UMD hashes were recorded. Both shader compilations and
creations returned S_OK; 600 Draw calls returned, 1,800 vertices were submitted,
600/600 Presents returned S_OK, none were occluded, and
GetDeviceRemovedReason returned S_OK. The loop elapsed10,394ms. The real console
showed the interpolated RGB triangle at accepted Present203, beyond the
ClearView background. The report records success=true and geometry_completed=true.
This establishes a small shader/geometry workload and visible output, not
physical frame count, sustained FPS, input latency or broad application compatibility.

Private raw report `.tools/windows-3d-geometry-ipa4k1.json`, SHA-256
`94203df574ba3f896a9af51c733a84dfe51acf4122ea02808100c444e1208251`.
Its source SHA-256 is
`e67451db1f010e16617b60a7df4123722801ad833ba218648d4f3ce01312a2a2`;
launcher SHA-256
`70249dd0c677011fcd5fed98d1183e43feff9feca34e4f1665dab12cd91041fb`.
These are newer sources than the historical Device/Scene reports above.

Edge155.0.4283.45 exported its internal GPU report at
2026-10-16T11:03:48.544Z. It names active GPU0 as VirtIO1AF4:1050 and
`ANGLE_D3D11`, with renderer
`ANGLE (VirtIO, Red Hat VirtIO GPU 3D controller (0x00001050) Direct3D11 vs_5_0 ps_5_0, D3D11-0.0.0.0)`.
Compositing, canvas and WebGL are reported hardware accelerated. The browser
GPU sandbox is enabled. This is adapter/configuration evidence, not yet a
rendered WebGL benchmark or verified video decode/encode.

The summary's WebGPU label is insufficient: Dawn specifically blocklists the
VirtIO D3D11 backend as not fully implemented, and lists software CPU backends
separately. WebGPU acceleration has not been established. Accelerated rasterization
is unavailable; the report attributes a GPU rasterization restriction to its
vendor/backend allowlist. No browser security setting, blocklist override or
experimental flag was changed to obtain this report.
Private raw report `.tools/windows-edge-gpu-ipa4k1.txt`, SHA-256
`ee87f3529c034313ec642bdad650468f504c8aa206f66ad67ff004ca3528c73c`.

## Guest Tools manual recovery in the same 3D run

The installed diagnostic confirmed the expected package and Limited/Interactive
scheduled-task ownership, an available VirtIO serial device with no PnP error,
successful native-source compilation and an allowed fixed-port open. The task
was Ready with LastTaskResult1 and no owned agent process. This distinguishes
the observed failure from a missing driver or denied port access, without
isolating the earlier startup error.

The installed Core/Display file hashes matched the current sources. After
preserving the previous agent script, only the project's agent entry script
was updated with bounded health logging; its source SHA-256 is
`54435a715018344e9374fe84caf2f5f43fadc1ab0798fede7a914f7dbae7943a`.
The verified existing task was started with unchanged action, principal,
privileges and port ACL. The log records successful native/clipboard/singleton
initialization and channel open. Its first read reset with HRESULT800705AA;
the retry loop remained active. Subsequent host requests returned connected=true,
protocol1/agent0.2.0, acknowledged a131-byte file transfer, and returned display
status for the VirtIO3D controller at1280×1024 with can_resize=true.

This establishes manual recovery and actual RPC/file-transfer functionality in
the live 3D profile. The logger/restart is not an isolated diagnosis or proof
that automatic startup is fixed after another boot. Clipboard capability
advertisement is not a clipboard-content exchange test. Raw private recovery
receipt `.tools/windows-tools-3d-health1.txt`, SHA-256
`f60b2ffadceeeba33ba03eaa3d1920aa6e92eefc8ea3a523a92869862804cd7f`.

Actual guest display requests subsequently changed1280×1024→1920×1200 and
restored1280×1024. The real Cocoa console remained visible at the larger size;
final guest status confirmed the restored dimensions. A1512×982 request was
rejected as display_mode_unsupported, with the1920×1200 mode unchanged. Thus
the current driver accepts enumerated modes; arbitrary window-size matching
has not been established in this 3D profile. Raw receipts are
`.tools/windows-tools-display-3d-resize1920.json`,
`windows-tools-display-3d-resize1512.json`,
`windows-tools-display-3d-resize1280.json` and final
`windows-tools-display-3d-status2.json`.

## Actual WebGL2 animation and pacing sample

The original [browser probe](../experimental/windows-browser-probe/README.md)
ran in Windows Edge with a fixed800×450 drawing buffer and1280×1024 desktop.
The real console showed the rotating RGB triangle during the run. Both GLSL
ES3.00 shaders compiled and linked. After2,012.9ms warm-up/120 draws, the
30,004.3ms measured interval submitted1,762 draws. Reported rAF callback spacing:

| Statistic | Actual value |
| --- | --- |
| Median | 16.1ms |
| 95th percentile | 31.7ms |
| Minimum / maximum | 1.3 / 34.5ms |
| Gaps greater than50ms | 0 |

The run had no visibility change, context loss or GL error. A single
post-timing readback at the triangle centre returned RGBA[97,78,80,255]. The
unmasked renderer names the VirtIO D3D11 ANGLE path. The report is completed,
valid=true; it deliberately does not infer host acceleration from renderer
names alone. Its raw SHA-256 is
`139703738f77a6cc8c0c2810222b439b04d21d56d141d1931d3b7ca3e206d3d2`
at `.tools/windows-browser-webgl2-ipa4k1.json`.

This is one small diagnostic workload, not a physical display FPS measurement,
an input-latency measurement or a comparison with Parallels. The p95 spacing
already shows that median timing alone would hide less regular callbacks.
Renderer/backend remain optimization0. Browser feature blocklists above remain
in force, and the production app has not yet adopted this graphics path.
