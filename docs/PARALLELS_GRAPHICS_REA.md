# Parallels graphics: REA observations

Static inspection on 2026-10-15 with REA 6.5.0. Target: Parallels Desktop
26.3.0 (57392), `Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app`.
The application was not launched, attached to a debugger or modified for this
inspection. Extracted bytes and complete evidence stay in ignored private
research storage; this repository contains no proprietary implementation.

## Identity and scope

| Input | SHA-256 |
| --- | --- |
| Shipped universal executable | `808684be2837cdb2dc83003ff6dd554d6b4a1c513184ace0c9090cb5b8731f3e` |
| ARM64 slice extracted locally with Apple's lipo | `06df7e631e86f073860c184376f419ee4ca0178aa3590a6bd7e2437781d79502` |

The ARM64 Mach-O UUID is `E2100C5F-0131-3469-84E4-F975DFBC9B59`.
REA's complete Mach-O inspection is retained as
`ev_5a3583e267a30512a2f9e18e9193bbb99782d93a4c5ce323eced400bdd7e1d8f`;
the summary projection is
`ev_61fe130d06762ccbe290d22fd9e5c74c2cbec9bba9042a309a2dd38ae3c4dd3f`.
The returned import/export symbol coverage is explicitly nonexhaustive.

## Observed static imports

| Evidence in this executable | What it establishes |
| --- | --- |
| Metal, IOSurface, QuartzCore and OpenGL dependencies | These frameworks are linked by this artifact; their role on a particular running configuration is not established. |
| `MTLCopyAllDevices` and Metal descriptor/counter classes | The executable references Metal device discovery and rendering-related objects. |
| `IOSurfaceCreate`, `IOSurfaceLock`, `IOSurfaceUnlock`, `IOSurfaceGetID`, `IOSurfaceGetBytesPerRow`, `IOSurfaceGetBaseAddressOfPlane` | It references shareable surfaces and explicit layout/access operations. This does not recover the guest GPU or IPC protocol. |
| `CVDisplayLinkCreateWithCGDisplay`, `CVDisplayLinkSetOutputCallback`, `CVDisplayLinkStart`, `CVDisplayLinkRelease` | It references a display-linked callback lifecycle. Actual callback frequency and presentation scheduling remain unknown. |
| `CGDirectDisplayCopyCurrentMetalDevice` | It references the relationship between a host display and its Metal device. |
| `CGDisplayCopyAllDisplayModes` and logical/pixel mode dimensions | It references host display mode enumeration and distinct logical/pixel sizes. It does not prove how a Windows guest changes resolution. |
| `CGLTexImageIOSurface2D` | An OpenGL/IOSurface interoperability reference is present, alongside Metal references. Which path runs is unknown. |

## Consequences for the independent implementation

The imports motivate investigation of surfaces, device identity, display
cadence and physical-pixel geometry as separate concerns. This is an
architectural inference, not recovered Parallels control flow. They do not
establish that our QEMU transport or Windows driver matches Parallels.

The native app's original Metal presenter is in
[`VMDisplayPresenter.swift`](../macos/PerpendicularDesktop/VMDisplayPresenter.swift).
Its bounded pending frame, filtering, aspect ratio and resize behavior are
validated by our own GPU tests. Guest D3D11 rendering and its producer/consumer
ownership are separate experiments documented in [GRAPHICS.md](GRAPHICS.md).
Automatic resolution must be checked against Windows and received framebuffer
dimensions; host scaling alone is insufficient.

## Unknowns and analysis limits

Ghidra 12.1.4 refused explicit architecture selection on the universal carrier,
so deep analysis selected the extracted ARM64 slice. Full startup analysis
timed out at 330 seconds and again with a private 1,200-second startup budget.
A distinct profile with `Objective-C Message Analyzer` disabled also timed out
at 600 seconds; diagnostics still showed decompiler-switch analysis failures.
The owned analysis processes were closed, with no persistent client/provider
configuration change. No successful string search, function xref, decompilation,
runtime frame trace or full graphics protocol reconstruction is claimed here.
