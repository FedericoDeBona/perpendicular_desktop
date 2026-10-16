# Parallels graphics: REA observations

Static inspection on 2026-10-15, followed by targeted decompilation on
2026-10-16, with REA 6.5.0. Target: Parallels Desktop
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

## Initial whole-program analysis limits

Ghidra 12.1.4 refused explicit architecture selection on the universal carrier,
so deep analysis selected the extracted ARM64 slice. Full startup analysis
timed out at 330 seconds and again with a private 1,200-second startup budget.
A distinct profile with `Objective-C Message Analyzer` disabled also timed out
at 600 seconds; diagnostics still showed decompiler-switch analysis failures.
The owned analysis processes were closed, with no persistent client/provider
configuration change. Those initial attempts recovered no graphics decompilation.

## Targeted recovery on 2026-10-16

Both original hashes above were rechecked against the current installed binary
and retained ARM64 slice. Instead of repeating whole-program startup, the
investigation used Mach-O metadata to select small, exact byte intervals and
opened each interval in REA as a generic little-endian ARM64 raw target at its
original preferred address. Ghidra 12.1.4 completed these analyses in seconds.
No provider installation, persistent configuration change, target modification,
Parallels launch, VM launch or live debugger attach was needed.

The selection step used Apple's LLVM tools and an independent local Mach-O
parser: Objective-C relative method lists, indirect symbol slots, stub
instructions, direct A64 BL instructions and `LC_FUNCTION_STARTS`. The direct
import scan examined 178,934 BL instructions; the 30,196 function starts agreed
with LLVM. These are bounded static findings, not runtime observations.

### Recovered evidence

| Address / original interval length | Observed behavior | REA evidence |
| --- | --- | --- |
| `0x100169c18` / 300 bytes | Calls the Objective-C stub for `presentDrawable:`, then `addScheduledHandler:` and a virtual call. Its normal return is recovered. The virtual method's meaning is unresolved; a scheduled handler is not GPU completion. | `ev_68829a10d8b58d729f96f17b05becda970e021cab42f96921eedc5421a128ae0` |
| `0x100166a34` / 284 bytes | Builds a texture descriptor and calls `newTextureWithDescriptor:iosurface:plane:` with plane zero. | `ev_1fbb5a2549d64053dc4adcb719d8fd3f92c4156446e7bc3ee30e09b0b1979aa4` |
| `0x100169498` / 308 bytes | A second IOSurface-to-Metal texture creation routine stores the resulting object and dimensions. | `ev_64eb756d2ec62293da2d94ba0c51a9ee4bb80af0bd9f7b2112dc7275f6f54bc4` |
| `0x1001695d4` / 448 bytes | A third texture import routine checks surface identity, dimensions and format before recreating the texture. | `ev_355d9046fdd4b9bddd0aaad632bbc79ba996a8d65d0d03ed85174a0eefde9af7` |
| `0x1006ec080` / 736 bytes | Collects image-queue state, conditionally registers a collectable callback and waits on a semaphore, unregisters it, then inserts an image with a callback. Its normal return is recovered. | `ev_a3600bab71a05da2b8b93733fce554a199a32724c22128b425b249a5f8789f03` |
| `0x1001cc094` / 4,196 bytes | Contains a conditional display-link lifecycle: creates a display link, installs callback `0x1001cd31c`, starts it, and releases it on other branches. | `ev_2cb0110542309a532cd3dcf4bf2f5499c926641cc1ea88e4f4512e1ab19d72dd` |
| `0x1001cd31c` / 60 bytes | The display-link callback checks an enabled bit, updates a state word and makes a virtual notification with argument four. Its normal return is recovered. | `ev_38870f8b0937d8bbb16439daa078b6c526272817cd93caadc44847b9143a8349` |

The raw texture-import decompilations contain bad-instruction/tail-flow warnings;
one also reports a possible PIC construction and an unreachable block. Their
external dependencies and exception paths are **not** recovered completely.
The table's narrower call/condition observations were checked against original
instruction bytes and selector stubs; these are not complete source listings.

Objective-C metadata also identifies an implemented `AsyncDrawable` class,
distinct from the `MTLDrawable` protocol's method declarations. Its instance
contains a private pointer, a presented semaphore, `vsync`, `canWait`, a callback
block, presented time and drawable ID. `present` is at `0x1006eb770`, `wait` at
`0x1006eb8e0`, and `cancel` at `0x1006eb8d0`. The 64-byte raw `present` query
(`ev_587862e623164b032a1c8e9a4630b3b5bbeff3138b64e1edb94383235fe02738`)
has a truncated tail; original assembly independently identifies its final
semaphore signal. Metadata alone does not establish when that class runs.

A separate original-instruction and vtable check links these observations:
the factory at `0x1006ebdc0` creates/caches an `AsyncDrawable`, passing its
private state to `initWithPriv:`. A caller forwards that returned object to
virtual offset `0xd0` of a screen object. The installed vtable address point
`0x100bac3b8` (RTTI name `CScreenMTL`) has `0x100169c18` in that slot. That
routine forwards the object to `presentDrawable:`. This is a static object-flow
path, not merely adjacent names in a binary. The factory's raw decompilation
has a recovered normal return:
`ev_86d9dfe80876147bca6259e516401c2fb133d10b2986570abf674861ada780cb`.

The registered block at `0x100169d44` checks the command buffer's `error` and
sends `cancel` to the captured drawable on that branch, as identified in
original assembly. Its raw decompilation
(`ev_b29a56297820566196ed1825671f7b16215f4839bf9326b978c36f5f2d7c294b`)
is truncated and reports PIC/unreachable-block warnings; it does not establish
that logic by itself. In particular, `addScheduledHandler:` must not be
substituted for producer GPU completion in our transport contract.

The four indirect calls in `0x1006ec080` were separately tied to initialization
in `0x1008cc3b8–0x1008ce800`. Exact Base64 strings are decoded before `dlsym`
and the results stored at these locations:

| Function-pointer location | Decoded lookup |
| --- | --- |
| `0x100cb2e28` | `CAImageQueueInsertImage` |
| `0x100cb2e40` | `CAImageQueueCollect` |
| `0x100cb2e60` | `CAImageQueueSetCollectableCallback` |
| `0x100cb2e68` | `CAImageQueueConsumeUnconsumedInRange` |

This identifies an image-queue branch; it does not make those calls Metal API
calls or establish that this branch runs in the user's current VM. Our product
does not adopt these private dynamically resolved interfaces.

### Interpretation and implementation boundary

There is now instruction-level evidence for IOSurface-backed Metal texture
import, a Metal drawable submission site, an image queue with collection
callbacks, and a display-link notification path. This is stronger than an
import inventory. It supports investigating texture ownership, completion and
presentation cadence separately instead of treating a screenshot as a frame.

For our independent implementation, the next concrete change is to export the
selected renderer texture directly into the native transport before acquiring
a Cocoa drawable. An immutable GPU snapshot can remove the intermediate
drawable copy/presentation while retaining the existing consumer contract.
Sharing mutable renderer memory without that snapshot additionally requires a
proven producer acquire/release and completion contract; retaining an object
or duplicating its FD only preserves lifetime, not pixel immutability.

Raw function bytes, pseudocode, metadata and provenance manifests remain under
ignored `research/private/parallels-graphics/targeted/`. No proprietary code is
published. Raw-target Evidence binds each extracted file's digest, not the
entire Mach-O: the private slice manifests preserve original hash, file offset,
preferred address, length and slice hash. Adjacent function-start intervals do
not prove complete noncontiguous function bodies. Unmapped data, external
calls, Objective-C dispatch types and exception edges remain limitations.

The guest GPU protocol, producer fences, complete buffer-reuse algorithm,
currently active Parallels backend, runtime frame cadence and mouse path remain
unresolved. No runtime frame trace or full graphics reconstruction is claimed.

A bounded input inventory selected a smaller next target:
`Contents/Frameworks/libPrlGui.3.dylib`, ARM64 slice 5,320,192 bytes, SHA-256
`bbd2f37d8319e7075c07b23633b0e96533cfacb5217dff8ea8ef04ee3cf77602`.
It defines native mouse-button/cursor wrappers and imports cursor association,
warping and mouse-event APIs. The larger `prl_client_app` also imports guest
mouse-event SDK operations and retains mouse sender/grabber/controller type
names. These are target-selection findings, not recovered input algorithms.
The two original carriers and extracted slices are hash-bound in the private
`input-two-image-inventory.json`; Qt frameworks were not scanned recursively.
