# Neptune signed driver wire compatibility

2026-10-16 checkpoint: the released ARM64 UMD requires **wire version 1**;
the current host research pin and its retained host fixture use **2**. This is
a concrete compatibility gate, not a completed Windows 3D result. The actual
Windows capset payload's first DWORD has **not** been captured in this review.

## Exact artifact and bounded branch proof

Target: released `neptune_umd_arm64.dll`, **1,375,392 bytes**, PE32+ ARM64
(Machine `0xAA64`), image base `0x180000000`, SHA-256:

`8fbb509b3b5e2a06b67392fe6b711832227e1ab802e096bf7d723ace6c66b437`

The reviewed copy is privately staged at
`.tools/windows-3d-media3/drivers/neptune_umd_arm64.dll`; its digest was checked
before and after inspection. “Signed” identifies the released package already
qualified in [the package report](GRAPHICS_DRIVER_PACKAGE.md); static
certificate metadata alone does not establish Windows signature acceptance,
device loading or successful execution.

| PE section | File offset | RVA | Preferred VA | Virtual size / raw size |
| --- | --- | --- | --- | --- |
| `.text` | `0x400` | `0x1000` | `0x180001000` | `0x10E404` / `0x10E600` |
| `.rdata` | `0x10EA00` | `0x110000` | `0x180110000` | `0x333BC` / `0x33400` |

Locations below use preferred static VAs, not observed ASLR runtime addresses.
For these sections, `file offset = section raw offset + RVA - section RVA`.

| Observation | File offset | RVA | Preferred VA |
| --- | --- | --- | --- |
| Load returned capset first DWORD | `0xD3970` | `0xD4570` | `0x1800D4570` |
| Compare it with literal **1** | `0xD3974` | `0xD4574` | `0x1800D4574` |
| Equal branch to subsequent initialization | `0xD3978` | `0xD4578` | `0x1800D4578` |
| Mismatch diagnostic string | `0x122330` | `0x123930` | `0x180123930` |
| Failure cleanup, then NULL return | `0xD3CD0` | `0xD48D0` | `0x1800D48D0` |

The relevant decoded instructions are:

```asm
1800d4570: ldr w8, [sp, #0x130]
1800d4574: cmp w8, #0x1
1800d4578: b.eq 0x1800d459c
; mismatch path: w2 = received value, w3 = required value 1
1800d458c: mov w3, #0x1
1800d4590: add x1, x8, #0x930
1800d4594: bl 0x180001a38
1800d4598: b 0x1800d48d0
1800d48d0: mov x0, x19
1800d48d4: bl 0x1800d49e0
1800d48d8: mov x0, #0x0
```

The diagnostic identifies a wire-format mismatch. Only the equal path proceeds
to the next escape/init request; its failure diagnostic is `CTX_INIT failed`.
Thus the binary rejects a non-1 capset wire word before that initialization.
This is static control-flow evidence, not an observed execution of this branch.

Inspection used `/usr/bin/objdump`, **Apple LLVM 21.0.0**, and a direct PE
section/ASCII-byte read. No Ghidra import, broad decompilation, driver execution
or VM action ran. The retained assembly contains three half-open VA windows:
`[0x1800D4430,0x1800D4614)`, `[0x1800D48B4,0x1800D48F8)` and
`[0x1800D49E0,0x1800D4AAC)`, **756 code bytes total**. Nearby string discovery
was limited to this 1.38 MB artifact; it does not recover all rejection paths.

## Host source, fixture and Windows trace are separate evidence

At host pin `e83b630ea14c9e8be33955462c80272f44927031`,
[`npt_protocol_defs.h`](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/src/neptune/neptune-protocol/npt_protocol_defs.h#L80)
defines `NPT_PROTOCOL_WIRE_VERSION 2u` and explicitly describes mismatch
rejection. [`npt_get_capset`](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/src/neptune/npt_renderer.c#L111)
writes that value to the first word of the zeroed
[`virgl_renderer_capset_neptune`](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/src/neptune_hw.h#L11),
whose size is 60 bytes. A capability-flags override changes the second word,
not the wire version.

The retained private `provenance/neptune-live-baseline.json` under
`.tools/graphics-experiment/` records `wire_format_version: 2`, four exact-pixel
frames through the real host decoder/QEMU boundary, `guest_cpu_executed: false`
and `guest_disks: false`. Receipt SHA-256:
`2ad4c3eb1e271d14a651cff67079e9fc08a47aed0092f80fc5d2ab3a5fa728a6`.
Its version field is obtained from the protocol header by the
[host fixture](../experimental/neptune-live/test-live.py), not from a Windows
capset-payload capture. The fixture proves its tested host path, not binary
compatibility with this signed UMD; see [its scope](../experimental/neptune-live/README.md).

Separately, the operator reported a bounded real Windows trace after
CONTEXT_INIT/VIRGL/BLOB feature negotiation: repeated GET_CAPSET **id 7,
version 0, size 60**, successful response type **0x1103**, and CTX_DESTROY
(`0x201`), with no CTX_CREATE (`0x200`) or worker within the 64-record window.
Those are metadata observations, **not the payload's first DWORD**. Capset
request version 0 is distinct from the embedded Neptune wire-format word:
successful delivery of 60 bytes does not establish acceptance of their version.
Concretely, [`virgl_renderer_get_cap_set`](https://github.com/utmapp/virglrenderer/blob/e83b630ea14c9e8be33955462c80272f44927031/src/virglrenderer.c#L590)
sets Neptune's outer `max_ver=0`; its `fill_caps` Neptune branch routes to the
proxy without using the outer version. Meanwhile
[`QEMU GET_CAPSET`](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/hw/display/virtio-gpu-virgl.c#L907)
passes the request version separately from the `capset_data` destination.
The observed sequence is consistent with this rejection, but does not prove
that the live response contained 2 or isolate every cause of the missing image.

The pinned [KMD context destructor](https://github.com/osy/kvm-guest-drivers-windows/blob/769e75cd645fc48f4aaae716ca8a74795fe5e241/viogpu/viogpu3d/viogpu_device.cpp#L54)
unconditionally sends DestroyCtx, even when the context was never initialized.
This explains why a destroy record need not imply an earlier create; it is a
source observation, not an additional signed-KMD execution trace.

## Provenance, receipts and next gate

The earlier public Mesa UMD research pin
[`bf536bba65454900d782fa7417bc95c1608d7483`](https://github.com/osy/virtio-win-mesa/blob/bf536bba65454900d782fa7417bc95c1608d7483/src/virtio/neptune/neptune-protocol/npt_protocol_defs.h)
also declares wire 2. It **does not describe the observed wire-1 requirement
of this signed DLL**. Its research source must not be presented as the source
of the release binary. Exact UMD source revision, reproducible binary match and
release-to-host compatibility mapping remain unknown; neither a release tag
nor matching names establishes them.

Full REA evidence IDs:

* Exact-target objdump identity/header observation:
  `ev_1d58e7fcacf6aa2eda03468b3deddde23b507fd4b8bd5e155fd3b02610099699`.
  The REA record labels its generic provider `gnu.objdump` and leaves the
  version unknown; the separate actual executable probe above reports Apple
  LLVM 21.0.0. This record proves identity/headers, not the branch analysis.
* Historical exact-member PE-resource inventory:
  `ev_6dd78d90ef668f628cc714bfc7aa6b5a34b5890c48c23ce06a4a47f613440ac3`.
* Historical safe package extraction:
  `ev_1c79435c0a3ddf26c707b217f57f1a6307583fce70696a551d748eedb3d3f46a`.

Private receipts under
`.tools/graphics-experiment/research/driver-release-v0.3/`:

| Receipt | SHA-256 |
| --- | --- |
| `wire1-arm64-bounded-assembly.json` (commands, decoded windows, layout, executable version/hash, unchanged target digest) | `fa58fe347fa6bcd4987d4126160742bd2b1e5ad9db92160526186b728e3f6b20` |
| `rea-wire-identity-evidence.json` (complete retained inline identity record) | `7b2fab7dc64170318f78ab2261f111f7062768b87cc1ac2442025a6479a02653` |

Next: capture the live capset payload's first word and qualify an independently
pinned host protocol compatible with the signed wire-1 guest. **Do not merely
change the advertised version**: incompatible command/reply layouts can remain
behind the gate. Compatible-host history/build qualification is separate work.
Positive VirtIO device creation, the intended loaded UMD, a visible Windows
scene and its host execution/scanout association remain unverified.
