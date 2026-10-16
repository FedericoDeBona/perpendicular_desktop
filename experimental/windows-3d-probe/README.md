# Independent Windows ARM64 D3D11 probe

Original MIT diagnostic, prepared on 2026-10-16. Historical native ARM64
Windows PowerShell 5.1 results below include correct rejection of Microsoft
Basic Render. The **Geometry** mode has now compiled and run on native ARM64 Windows
PowerShell 5.1 with a visible RGB triangle and 600 successful Presents. Results from earlier Device/Scene source revisions
must retain their own report hashes. Host acceleration remains a separate gate.
The separately retained [positive Device/Scene checkpoint](../../docs/NEPTUNE_WINDOWS_3D_CHECKPOINT.md)
now records native ARM64 VirtIO creation and visible clear/present output;
those earlier hashes do not establish a Geometry result.
No driver, VM, app, runtime, certificate,
security policy or display setting was changed by preparing this probe. The separate operator-led
driver trial is recorded below without a success claim. See the separate
[driver-package gate](../../docs/GRAPHICS_DRIVER_PACKAGE.md) and
[host scanout limits](../neptune-live/README.md); this program does not authorize
installing that driver or qualify its source provenance.

## Device, scene and geometry are separate results

`Device` calls **D3D11CreateDevice exactly once**, with NULL adapter,
`D3D_DRIVER_TYPE_HARDWARE=1`, NULL software module, BGRA support, SDK version 7,
and feature levels 11_1/11_0/10_1/10_0. There is no WARP, reference, software,
alternate-adapter or debug-layer retry. Failure at these requested feature
levels is reported; it is not proof about unsupported lower levels.
[Microsoft creation contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-d3d11createdevice).

The actual returned device is queried for IDXGIDevice, its adapter and
IDXGIAdapter1::GetDesc1. The report includes description, vendor/device/subsystem/
revision, LUID, flags and actual selected feature level. All three modes
require the expected VirtIO GPU identity **vendor 0x1AF4/device 0x1050** as well
as a clear DXGI software flag. Microsoft Basic Render **0x1414/0x008C** is
explicitly rejected even when DXGI returns flags zero, as observed in the real
baseline below. An unexpected adapter fails; no alternative adapter is tried.
`dxgi_software_flag` records the raw classification separately from
`software_adapter`, which also recognizes that Basic Render identity.
`expected_adapter_verified` records the target identity gate; the compatibility
field `hardware_adapter_verified` requires both that gate and successful device
creation. Neither field proves host Metal execution, driver binary identity or
physical GPU acceleration. `host_acceleration_verified` stays false: this
standalone program cannot measure the host renderer.
[Adapter description](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/ns-dxgi-dxgi_adapter_desc1),
[software flag](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/ne-dxgi-dxgi_adapter_flag).

Immediately after D3D11CreateDevice returns, including a failed HRESULT, the
probe inventories only its **own loaded modules** whose base names match
`neptune_umd*.dll` (case insensitive). `umd_modules` records their mapped file
paths and full SHA-256 hashes of the corresponding files on disk. Enumeration
accepts at most 1,024 own-process module entries, eight matching modules,
8 MiB per file and 32 MiB total file bytes; hashing streams through a 64 KiB
buffer. Errors/limits yield `unknown` or `partial`, never a fabricated hash or
GPU result. A complete empty list means no matching module was enumerated at
that instant. Paths identify loaded modules; the hashes measure the disk files
at collection time, **not executable memory, signature validation, provenance
or actual host execution**. A module loaded and unloaded inside the creation
call can be missed; this is a snapshot, not a loader trace. Inventory failure
does not replace the independent device/adapter outcome.

Native ARM64 is required: IsWow64Process2 must return process machine UNKNOWN
(native), native machine AA64, and an eight-byte pointer size. Emulated x86/x64
and non-Windows execution fail before D3D calls. The C# assembly is AnyCPU and
JIT-compiled in that validated ARM64 process; it is **not a cross-built native
PE executable**.
[Architecture API](https://learn.microsoft.com/en-us/windows/win32/api/wow64apiset/nf-wow64apiset-iswow64process2).

Device mode creates no HWND, swap chain or visible scene and calls no Present.
A successful device report must never be relabelled as a successful scene.
`software_fallback=false` means the program made no fallback/retry call; it
does not independently classify the implementation returned by Windows.

`Scene` uses that same device and its immediate context, queries Context1, and
creates one fixed 800×600 Win32 window and two-buffer BGRA8 FLIP_DISCARD swap
chain. ClearView commands draw red/green/blue/white quadrants, a changing primary
colour border and a sixteen-bit black/white counter along the bottom. Bit zero
is leftmost, white means one, and the intended first frame encodes 1. The title
counts only Present calls returning S_OK. The counter is in the GPU render
target, not just a native title or CPU-painted overlay.
[ClearView contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11_1/nf-d3d11_1-id3d11devicecontext1-clearview),
[swap-chain creation](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgifactory2-createswapchainforhwnd).

Scene is a clear/present mode, **not a triangle, shader, geometry or performance
benchmark**. Occlusion is counted separately, other non-S_OK statuses fail, and
device removal is reported. S_OK is an API observation; externally visible
console pixels still require observation. Frame count and duration are bounds
checked between native calls. A hung driver can block inside Present, creation,
release or a fullscreen transition; there is no pretend hard GPU watchdog and no
TDR-policy change. An operator must be able to terminate this owned probe
process independently in a future trial.
[Present semantics](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiswapchain-present).

Default scene mode is windowed and may involve DWM/shared imports. It does not
satisfy the frozen headless overlay's exclusive/no-import acceptance gate.
`-Exclusive` explicitly requests fullscreen, checks DXGI state at entry and end,
and restores windowed state in cleanup. The required flip-model ResizeBuffers
call runs **before** acquiring the backbuffer/RTV and before the first Present.
There are no subsequent resizes during rendering. Restoration HRESULT is
reported, and a non-S_OK restoration prevents a successful scene result.
Exclusive state can change between observations and does not prove absence of
DWM imports, extra writers or fences. Those require actual host wire evidence.
[Fullscreen transition](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiswapchain-setfullscreenstate),
[ResizeBuffers ownership requirements](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiswapchain-resizebuffers).

The program adds no explicit fences, shared textures or deferred contexts. It
does not guess that a fence observed elsewhere belongs to its Present. The
Windows driver's own allocations, rings, fences and present sequence remain
unverified. One-to-one association with the QEMU scanout is still the separate
gate described in the host overlay README.

## Geometry: compiled shaders and submitted Draw calls

`-Mode Geometry` uses the same single HARDWARE device, native ARM64 admission,
mandatory non-software VirtIO `1AF4:1050` adapter check, UMD inventory and
swap-chain lifecycle. It adds a real RGB gradient triangle over the existing
clear/counter pattern. There is no WARP retry, alternate adapter, shader
replacement or clear-only fallback if shader compilation or creation fails.
Device and Scene do not load the shader compiler or call this geometry path.

The original inline HLSL is compiled twice by Windows System32
`d3dcompiler_47.dll`: `VSMain/vs_4_0` and `PSMain/ps_4_0`, with strictness
enabled, NULL macro/include handlers and no external source files. The vertex
shader generates three positions and colours from `SV_VertexID`; the pixel
shader interpolates colour. Shader model 4.0 covers the requested 10_0..11_1
feature levels. Creation uses returned bytecode and NULL class linkage;
blobs and shader interfaces are released on success and failure. Bytecode is
limited to 1 MiB and compiler messages to 4 KiB.
[Compiler contract](https://learn.microsoft.com/en-us/windows/win32/api/d3dcompiler/nf-d3dcompiler-d3dcompile),
[vertex shader creation](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11device-createvertexshader).

Every Geometry frame explicitly binds its render target, viewport, NULL input
layout, TRIANGLELIST topology, vertex and pixel shaders, then invokes
`Draw(3, 0)` before Present. No vertex/index/constant buffer, depth buffer,
texture sample or geometry-shader stage is required. The clockwise triangle
uses the fresh immediate context's default rasterizer. The bottom counter
remains outside the triangle. The default 180 frames/10 seconds and limits of
1..600 frames/1..30 seconds also apply to Geometry; bounds are checked between
calls, not as a hard watchdog for a stalled compiler or driver.
[Draw and SV_VertexID](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-draw),
[viewport contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-rssetviewports).

The report adds `geometry_attempted/completed`, `rendering_technique`, compiler
module path, profiles and inline-HLSL SHA-256, compile/create attempt and S_OK
counters, last shader HRESULTs, bounded compiler errors, `draw_attempts`,
`draw_calls_returned`, and `vertices_submitted`. Draw returns **void**:
`draw_calls_returned=1` means the API call returned after submission, not that a
GPU finished three vertices. Geometry completion additionally requires both
created shaders, a returned Draw, a successful Present, no user closure,
successful device-removal check and any requested fullscreen restoration.
Neither that result nor the counters measure pixels, host Metal execution,
shader correctness, FPS or sustained stability; `host_acceleration_verified`
remains false. The actual Windows Geometry run is recorded below; its visible triangle
is a separate observation from the API counters.

## Actual Windows Geometry checkpoint

The native Windows run completed at `2026-10-16T11:05:54.7052778Z` using C#
SHA-256 `e67451db1f010e16617b60a7df4123722801ad833ba218648d4f3ce01312a2a2`
and launcher `70249dd0c677011fcd5fed98d1183e43feff9feca34e4f1665dab12cd91041fb`.
System32 compiler, both shader compilations/creations, 600 Draw calls and
600 Presents completed; the real console showed the RGB gradient triangle.
There was no device removal or occlusion. Raw report SHA-256
`94203df574ba3f896a9af51c733a84dfe51acf4122ea02808100c444e1208251`.
See the [full checkpoint](../../docs/NEPTUNE_WINDOWS_3D_CHECKPOINT.md) for
configuration, UMD hashes and the distinction between API/visual evidence and
unmeasured sustained performance. Earlier Device/Scene reports retain their
older source hashes.

## Actual Windows baseline and corrections

The orchestrator ran source
`651a1243df369c240ddf981d0db43ce65d7e287a80349d7621cebcb12642178f`
with launcher
`dfde02989d38d9f5612737210459dd1317c73f8c4605ef66802136dd94e6cec1`
in Windows PowerShell **5.1.26100.9711**, OS build **26300**. Compilation
completed. `-Mode device` then failed at `arguments`, before the architecture
or graphics calls (reported process 8060, default 180 frames/10 seconds).
PowerShell ValidateSet accepts case variations; the old C# comparison did not.
The launcher and C# entry point now canonicalize Device/Scene independently,
using case-insensitive comparisons. Other labels still fail before native
calls. This arguments failure provides no negative evidence about 3D.

A subsequent default-Device run on the **DOD-only baseline before the 3D
driver** reached native ARM64 and D3D11CreateDevice(HARDWARE): S_OK, feature
level 11_1, adapter **Microsoft Basic Render Driver**, vendor **0x1414**, device
**0x008C**, flags **0**. The old report consequently set
`software_adapter=false` and `hardware_adapter_verified=true`. That is a
concrete counterexample to treating the creation request and DXGI flag as
sufficient hardware evidence; it is **not a successful 3D/acceleration result**.
The new mandatory VirtIO identity gate and Basic Render rejection cover this
exact tuple. Host tests call the same production classification routine with
the observed report values; the corrected Windows rerun below now verifies
that rejection on the actual baseline too. Earlier trial media retains the
earlier source.

The operator subsequently delivered the corrected source/launcher to the
clone's Downloads through the guest-file channel and received its file-write
acknowledgements. The corrected source SHA-256 is
`28cb9b46f8e698506b2f850f563276de4e61164f59df3e5c215cf7507a7d1ecd`;
the launcher SHA-256 is
`cf6af725a1aaa11ef00b82ed59ed1abb1d385d37a67f272e77666dc766a64a1e`.
Those acknowledgements establish transfer, not compilation, execution or
device/scene results. Reports from the earlier media remain earlier reports;
their embedded source hashes must not be attributed to this correction.

In a separate experimental-driver attempt, the operator observed pnputil add
the original package as `oem5.inf`, followed by a disabled/stalled GPU PnP
device and a black display after reboot. That attempt yielded no corrected
Windows probe report at the time. Package addition does not establish a working
device, loaded UMD or successful D3D11 call. The observations do not isolate
the cause of the stall/black display.

**Corrected Windows negative baseline, 2026-10-16 09:21:04 UTC:** the report
records the corrected source/launcher hashes above, Windows PowerShell
**5.1.26100.9711**, OS **10.0.26300.0**, and native ARM64
(`process_machine=0x0000`, `native_machine=0xAA64`). Lowercase `-Mode device`
produced canonical `mode=Device`. D3D11CreateDevice(HARDWARE) returned S_OK,
feature level 11_1, but the actual adapter was again **Microsoft Basic Render
Driver, 1414:008C, flags zero**. The corrected report returned
`success=false`, `error_stage=adapter`, `dxgi_software_flag=false`, and
`software_adapter=true`; `expected_adapter_verified`,
`hardware_adapter_verified` and `host_acceleration_verified` were all false.
Own-process UMD inventory completed with an empty list. Scene was not attempted
and both Present counters were zero. This verifies compilation/execution,
case normalization and Basic Render rejection on Windows; it does not verify
a Neptune UMD, a working VirtIO 3D device, a scene or host acceleration.

For future authorized trials, these remain the report expectations:

| Observation | Expected interpretation |
| --- | --- |
| Basic Render `1414:008C`, even S_OK/11_1/flags zero | `adapter` rejection; no scene; no acceleration result |
| Any other unexpected vendor/device with flags zero | `adapter_target` rejection; no alternate-adapter retry |
| Native ARM64 + successful creation + non-software `1AF4:1050` | Device gate only; `expected_adapter_verified=true`, `host_acceleration_verified=false` |
| Empty list or `umd_inventory_status=unknown/partial` | Missing entries/failed hashes do not establish module identity; available entries keep their limited scope and the device outcome remains separate |
| Neptune module path and matching full disk hash | Own-process loaded-path/file identity observation; no signature, memory or host-execution proof |
| Scene success with one or more S_OK Present calls | API-level scene completion; not proof of all requested frames, a hard elapsed-time limit, visible pixels or acceleration |
| No report after stall/reboot/black display | Incomplete trial; no device/scene pass or isolated graphics-failure diagnosis |

Any later device or scene result must name the report's source/launcher hashes.
A visible scene still needs independent observation and its host renderer/
scanout trace before claiming the intended accelerated path.

## Positive Device/Scene checkpoint from the previous source

The separate checkpoint now records a successful native ARM64 VirtIO Device
report and two successful Scene runs; the repeated scene was also observed in
the Cocoa console. Those used C# source
`28cb9b46f8e698506b2f850f563276de4e61164f59df3e5c215cf7507a7d1ecd`
and launcher `cf6af725a1aaa11ef00b82ed59ed1abb1d385d37a67f272e77666dc766a64a1e`.
The retained Device report SHA-256 is
`5418cd5086cc4c00a322f4d77b1a6765d98bb746055f1a32cec1a6a71779b79e`;
the repeated Scene report SHA-256 is
`d0ea04ebabf0f3cec977ba3cdea7d56d01c45a35a9b243c583057a06df58415e`.
See [the full scope and matched runtime](../../docs/NEPTUNE_WINDOWS_3D_CHECKPOINT.md).
They qualify the preceding Device/clear-scene revision only. They did not
compile these new shaders or execute Geometry and are not a geometry/FPS result.

## Build and future execution

The existing Mac inventory found Apple clang and the pinned DXMT native/WIDL
Direct3D headers, but no usable Windows ARM64 SDK/import-library/PE-linker stack
on PATH or in the private graphics prefix. The existing DXMT `libd3d11.a` is a
host library, not a Windows import library. No toolchain was downloaded.

Use native ARM64 Windows PowerShell 5.1 or native ARM64 PowerShell 7 in a **new,
independent process**. Add-Type compiles the original C# source with language
version 5; only framework interop types are needed. No Windows SDK, Visual
Studio, WinForms assembly, NuGet package or compiler installation is required.
The launcher selects Windows PowerShell 5.1's CodeDom CompilerParameters or
PowerShell 7's CompilerOptions parameter by inspecting the actual cmdlet.
P/Invoke imports use System32-only DLL search.
[PowerShell Add-Type](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/add-type?view=powershell-5.1).

Copy `D3D11Probe.cs` and `Invoke-D3D11Probe.ps1` together into a trusted trial
folder. The following commands require an authorized interactive clone trial;
the earlier source produced the negative baseline and later positive
Device/Scene checkpoint above. Geometry still requires its own Windows trial:

```powershell
powershell.exe -NoProfile -STA -File .\Invoke-D3D11Probe.ps1 -Mode Device -ReportPath .\device.json
powershell.exe -NoProfile -STA -File .\Invoke-D3D11Probe.ps1 -Mode Scene -Frames 180 -Seconds 10 -ReportPath .\scene-windowed.json
# Explicitly changes this probe's swap-chain fullscreen state:
powershell.exe -NoProfile -STA -File .\Invoke-D3D11Probe.ps1 -Mode Scene -Exclusive -Frames 180 -Seconds 10 -ReportPath .\scene-exclusive.json
# Real shaders and Draw; use a fresh report name and interactive native ARM64 process:
powershell.exe -NoProfile -STA -File .\Invoke-D3D11Probe.ps1 -Mode Geometry -Frames 60 -Seconds 10 -ReportPath .\geometry-windowed.json
```

Use the actual native executable path if PATH selects an emulated PowerShell;
the runtime check refuses to proceed otherwise. Existing PowerShell execution
policy still applies. These instructions do not bypass it or alter it. Device
mode is suitable for the first probe; Scene requires the interactive user
desktop, not Session 0. Do not run it through the guest agent as an arbitrary
command; that channel deliberately provides no such capability.

The launcher writes a new UTF-8 JSON file with CreateNew (never overwrites),
source/launcher SHA-256, timestamp, PowerShell version and report. Exit code 1
means the requested probe failed. Device-creation success can coexist with
scene failure; inspect both fields. Existing report files are rejected before
compilation/device creation. Run each invocation in a fresh process so an
already loaded C# type cannot masquerade as a new source revision. Runtime DLL
binding/driver failure may terminate the process before any report is produced;
absence of output is not success.

## Host verification and remaining gaps

Already available portable PowerShell:
`.tools/powershell-tests/7.6.7/pwsh` (macOS ARM64). Repeat without any download,
Windows graphics call or VM:

```sh
.tools/powershell-tests/7.6.7/pwsh -NoProfile -File experimental/windows-3d-probe/Test-D3D11Probe.ps1
python3 experimental/windows-3d-probe/check-abi.py
```

Observed PASS: C# language-version-5 compilation; Win64-sized struct layout and
adapter flag offset; native-architecture and software-adapter guards; eight
Device/Scene/Geometry case variations and invalid-mode rejection; the real Basic Render
S_OK/11_1/flags-zero counterexample; expected VirtIO identity admission and
unexpected-adapter rejection; exact feature/HRESULT formatting; bounds;
Neptune module-name filter, known full SHA-256 and aggregate/per-file byte
limits, with unavailable files reported unknown;
Present S_OK versus occlusion/device loss/
other status classification; owned mock vtable/delegate dispatch of 21
bounded clear commands including counter bits; idempotent one-release COM
ownership; compiler binding/SIZE_T/ANSI signatures; bounded original shader
source/profile/no-include dispatch; mocked VS/PS creation and compile, null,
oversized-bytecode and creation failures; RTV/viewport/topology/shader bindings
followed by exactly Draw(3,0), with incomplete pipelines denied and no false
completion; non-Windows fail-closed path; PowerShell launcher parse and three real
fresh-process lowercase/mixed-case launches that write canonical-mode reports
at the platform guard without Windows DLL calls. The ABI
checker independently matches **26 vtable slots and five interface GUIDs**
against the existing pinned WIDL headers and prints their SHA-256 receipts.
That local DXMT tree is commit `2a7dd3e7d22541611433441b82894ec5bca75ca2`;
its fetch provenance belongs to the separate graphics experiment. No header or
third-party implementation is copied into this folder.

These host checks do not execute Windows PowerShell 5.1, the Windows CLR
marshaler, user32, DXGI, the Windows driver or any GPU API. They do not establish
that the window, fullscreen transition, Present or visible counter works on
the intended Windows build. The separate Windows reports above verify the
negative Basic Render gate and the previous source's positive Device/Scene
checkpoint. Geometry requires its own native Windows report, visible triangle
and host renderer/scanout evidence. Do not infer signature acceptance, installed UMD
revision, driver provenance, acceleration, stability or FPS from a name or
from the host self-tests.

An earlier **Device-only** packaging checkpoint is frozen privately at
`.tools/windows-3d-probe-device/manifest.json`. It was provided so Device mode
could be staged while the canonical scene source was completed; it is not the
final scene build. Record its own source hashes if used, and do not mix its
earlier C# source with a report claimed to come from this final source.
