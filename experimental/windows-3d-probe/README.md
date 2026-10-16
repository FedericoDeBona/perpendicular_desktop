# Independent Windows ARM64 D3D11 probe

Original MIT diagnostic, prepared on 2026-10-16. **Not run in Windows.** No
driver, VM, app, runtime, certificate, security policy or display setting was
changed while preparing this folder. See the separate
[driver-package gate](../../docs/GRAPHICS_DRIVER_PACKAGE.md) and
[host scanout limits](../neptune-live/README.md); this program does not authorize
installing that driver or qualify its source provenance.

## Device and scene are separate results

`Device` calls **D3D11CreateDevice exactly once**, with NULL adapter,
`D3D_DRIVER_TYPE_HARDWARE=1`, NULL software module, BGRA support, SDK version 7,
and feature levels 11_1/11_0/10_1/10_0. There is no WARP, reference, software,
alternate-adapter or debug-layer retry. Failure at these requested feature
levels is reported; it is not proof about unsupported lower levels.
[Microsoft creation contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-d3d11createdevice).

The actual returned device is queried for IDXGIDevice, its adapter and
IDXGIAdapter1::GetDesc1. The report includes description, vendor/device/subsystem/
revision, LUID, flags and actual selected feature level. A DXGI software flag
refuses the scene. `hardware_adapter_verified` means **the explicit hardware
creation call and DXGI non-software classification passed**; it does not prove
host Metal execution, driver binary identity or physical GPU acceleration.
[Adapter description](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/ns-dxgi-dxgi_adapter_desc1),
[software flag](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/ne-dxgi-dxgi_adapter_flag).

Native ARM64 is required: IsWow64Process2 must return process machine UNKNOWN
(native), native machine AA64, and an eight-byte pointer size. Emulated x86/x64
and non-Windows execution fail before D3D calls. The C# assembly is AnyCPU and
JIT-compiled in that validated ARM64 process; it is **not a cross-built native
PE executable**.
[Architecture API](https://learn.microsoft.com/en-us/windows/win32/api/wow64apiset/nf-wow64apiset-iswow64process2).

Device mode creates no HWND, swap chain or visible scene and calls no Present.
A successful device report must never be relabelled as a successful scene.

`Scene` uses that same device and its immediate context, queries Context1, and
creates one fixed 800×600 Win32 window and two-buffer BGRA8 FLIP_DISCARD swap
chain. ClearView commands draw red/green/blue/white quadrants, a changing primary
colour border and a sixteen-bit black/white counter along the bottom. Bit zero
is leftmost, white means one, and the intended first frame encodes 1. The title
counts only Present calls returning S_OK. The counter is in the GPU render
target, not just a native title or CPU-painted overlay.
[ClearView contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11_1/nf-d3d11_1-id3d11devicecontext1-clearview),
[swap-chain creation](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgifactory2-createswapchainforhwnd).

This is a clear/present scene, **not a triangle, shader, geometry or performance
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
folder. The following commands are for a later authorized interactive clone
trial; none was executed in a VM during this work:

```powershell
powershell.exe -NoProfile -STA -File .\Invoke-D3D11Probe.ps1 -Mode Device -ReportPath .\device.json
powershell.exe -NoProfile -STA -File .\Invoke-D3D11Probe.ps1 -Mode Scene -Frames 180 -Seconds 10 -ReportPath .\scene-windowed.json
# Explicitly changes this probe's swap-chain fullscreen state:
powershell.exe -NoProfile -STA -File .\Invoke-D3D11Probe.ps1 -Mode Scene -Exclusive -Frames 180 -Seconds 10 -ReportPath .\scene-exclusive.json
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
adapter flag offset; native-architecture and software-adapter guards; exact
feature/HRESULT formatting; bounds; Present S_OK versus occlusion/device loss/
other status classification; owned mock vtable/delegate dispatch of 21
bounded clear commands including counter bits; idempotent one-release COM
ownership; non-Windows fail-closed path; PowerShell launcher parse. The ABI
checker independently matches **15 vtable slots and five interface GUIDs**
against the existing pinned WIDL headers and prints their SHA-256 receipts.
That local DXMT tree is commit `2a7dd3e7d22541611433441b82894ec5bca75ca2`;
its fetch provenance belongs to the separate graphics experiment. No header or
third-party implementation is copied into this folder.

These host checks do not execute Windows PowerShell 5.1, the Windows CLR
marshaler, user32, DXGI, the Windows driver or any GPU API. They do not establish
that the window, fullscreen transition, Present or visible counter works on
the intended Windows build. Required next evidence is an actual native ARM64
Device report, then a separately observed Scene with its report and host
renderer/scanout trace. Do not infer signature acceptance, installed UMD
revision, driver provenance, acceleration, stability or FPS from a name or
from the host self-tests.

An earlier **Device-only** packaging checkpoint is frozen privately at
`.tools/windows-3d-probe-device/manifest.json`. It was provided so Device mode
could be staged while the canonical scene source was completed; it is not the
final scene build. Record its own source hashes if used, and do not mix its
earlier C# source with a report claimed to come from this final source.
