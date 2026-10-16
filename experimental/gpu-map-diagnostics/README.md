# Bounded GPU mapping attribution (source preparation only)

This original diagnostic overlay prepares four copied QEMU translation units.
It changes no existing source, object, build graph, binary, VM, firmware or app.
It does not keep mappings alive, emulate a fault, ignore a write, advance a PC,
change teardown ordering or alter the original HVF assert. C fragments are
GPL-2.0-or-later; the Python preparer is Apache-2.0. QEMU retains its licenses.

The private failure receipt records an ISV0 write, FSC06, whose current FlatView
result is `gpex_mmio_window`.
That region is the fallback for holes in the PCI address space, not a resource
identity. Older independent QMP snapshots record a 256 MiB GPU BAR4 aperture.
The fault address falls within that historical range; those samples do not
prove BAR4's state in the failing launch. Captured guest addresses remain private.

## Source findings and hooks

The QEMU base pin is `88e5ee7ec6703662fec7b638cca74c4769e683d6`; preimages include
previous private changes. `prepare.py` rejects any full-file hash mismatch.

| Copied source | SHA256 of exact preimage | Existing object replaced |
| --- | --- | --- |
| trace3 `virtio-gpu-virgl.c` | `024ef0302c67ae1ca9ac8e06af54a3227b05b302d8c23fd4a5740da5bea7d9d6` | trace3 `virtio-gpu-virgl.c.o` |
| source `hw/pci/pci.c` | `ab42707b4ddaefacb96229aa7081e726ef7a0bc42ac7a96c05d773b0d2edbc0e` | `libcommon.a.p/hw_pci_pci.c.o` |
| source `hw/display/virtio-gpu.c` | `43cfda3265d99bf3bca1a11f7718c63af89e5b0acd544181a975f43ee2fc922a` | `libcommon.a.p/hw_display_virtio-gpu.c.o` |
| existing prepare2 `hvf.c` | `0c53b98aad106e793439e4523918c55bc7d537086c677fe0441311670ac3b11f` | existing diagnostic `hvf.c.o` |

The following are line anchors in those exact **preimages**:

- GPU map lines 265-303 calls renderer map, creates RAM with
  `memory_region_init_ram_ptr`, and adds it at the requested hostmem offset.
  The overlay records map request, add begin and add done, with offset/size.
- GPU unmap lines 319-346 immediately disables/detaches the guest subregion,
  then defers renderer unmap until MR finalization. Hooks bracket detach while
  the MR is still alive, before `object_unparent`. Completion at 158-201 records
  only resource ID; it never reads an already finalized MR.
- GPU UNREF at 540-590 can cause that same detach. Explicit UNMAP at 1128-1159
  is answered after detachment, without waiting for renderer cleanup. Separate
  request stages preserve opcode/context/fence and identify the initiating op.
  Resource destruction at 350-404 also records only resource ID, because its MR
  may already be finalized. Match these against earlier interval records.
- `virtio-gpu.c` reset BH at 1605-1633 destroys all resources. Two reset markers
  distinguish a virtio device/status reset from individual UNMAP/UNREF requests.
- PCI BAR4 is the 64-bit prefetch host-visible region in
  `hw/display/virtio-gpu-pci.c:35-46`. PCI core `pci_bar_address` at 1621-1684
  returns unmapped if PCI_COMMAND_MEMORY is clear; `pci_update_mappings` at
  1686-1727 also unmaps for disabled devices/non-D0 power. Hooks bracket BAR4
  mapping changes and capture config value/current address, command and PM.
- PCI config at 1764-1787 can trigger remap on BAR/command/PM changes. Device
  reset at 538-565 clears command/BARs and updates mappings. Config and reset
  markers make those causes distinguishable; generic PCI hooks are filtered
  to vendor/device `1af4:1050` and never query a destroyed GPU child.
- HVF prepare2 source reacquires BQL at 2212 before generic exit handling. The
  added dump is inside its existing `if (!isv)` block, before the original
  retained `assert(isv)`. No dump is added to the unlocked fast path.

The current HVF listener maps RAM into stage2 and removes a slot on a FlatView
region deletion (`accel/hvf/hvf-accel-ops.c:138-161,165-227,353-362`). Keeping
renderer memory alive for RCU readers therefore does not mean that the guest
IPA remains mapped. The fallback alone cannot distinguish an explicit resource
unmap from a whole-BAR disable, a reset, or an address never mapped there.

The available Windows KMD source at `osy/kvm-guest-drivers-windows` commit
`769e75cd645fc48f4aaae716ca8a74795fe5e241` has D3→`VioGpuAdapterClose`→
`virtio_device_reset` (`viogpu_adapter.cpp:797-800,3184-3212`), and an allocation
Close can issue `UnmapBlobLocked` (`viogpu_allocation.cpp:1881`). Explicit window
release/destruction attempts to remove process VAs before host UNMAP/UNREF
(`viogpu_allocation.cpp:432-508,1700-1730`). Its local file hashes match the
existing source ledger; correspondence to the installed signed binary is
unknown. Neither the source nor the recorded fault proves which path ran, or
that Windows had quiesced all users of the BAR-backed mappings at reset.

## Diagnostic behavior

Only the exact startup environment value
`PERPENDICULAR_GPU_MAP_DIAGNOSTICS=1` enables recording. No output is emitted
until the first HVF ISV0 dump; ordinary startup/shutdown logs remain unchanged.
One process-global 512-entry overwrite ring lives inside the replaced GPU object,
so it requires no new separately linked object. Entries contain only scalar
metadata: sequence, host monotonic nanoseconds, fixed stage, resource ID,
opcode/context/fence, guest offset/size, BDF, BAR4 config/address/size/mapped,
old/new BAR values, PCI command/PM, optional virtio status and PCI config write.
The generic PCI hook uses `vstatus=UINT32_MAX` for unknown status.

All hooks and the dump require BQL. The helper refuses to record/query object
state if it is absent; it never acquires BQL or changes scheduling. There is no
MR-finalizer/RCU hook and no diagnostic allocation. The first fatal dump prints
at most 512 entries plus begin/end. Its header gives the total last sequence,
first retained sequence and overwritten count; an overwritten interval remains
unknown, not inferred. A per-row contains_ipa field matches the recorded interval
at that event; its lifetime at the fault must be deduced from later transitions.
Zero-size request/finish/reset records are not interval claims.
No object pointer, host backing address, guest bytes or credentials are logged.

Interpret the event order with the original HVF record:

1. A containing map followed by matching UNMAP/UNREF detach, with BAR still
   mapped, identifies removal of a blob subregion.
2. A GPU-reset begin followed by resource destruction identifies resource
   teardown caused by device reset, even if BAR4 remains enabled.
3. BAR/config/PM or PCI-reset markers removing BAR4 identify whole-aperture
   removal. A configured BAR address alone does not mean it is mapped.
4. Missing/overwritten evidence, a different BAR or no containing earlier map
   leaves attribution unknown. Event order alone does not identify the guest
   instruction/process or prove why it wrote after teardown.

## Preparation and review

Run the preparer with `--self-test` to check exact preimages, unique anchors,
byte-for-byte restoration after removing insertions, rejection of an already
instrumented source, retained HVF assert and bounded helper properties.

For a private source output, use:

```sh
python3 experimental/gpu-map-diagnostics/prepare.py --self-test --prepare \
  --output .tools/gpu-map-diagnostics/prepare-new
```

The output must be a fresh immediate child of an owned 0700 private directory.
`prepare.json` records protected input hashes, copied source hashes, complete
compiler argument vectors and four link substitutions. `compile.sh` is only a
plan: four sequential compiler invocations using the existing pinned Ninja
recipes plus isolated include directories. Neither this command nor self-test
compiles, links, signs or runs a binary. The root reviewer performs compilation
and any isolated candidate link; replace every indicated object exactly once,
including the prior trace3 GPU and HVF diagnostic object. Do not link duplicate
old/new GPU objects or change the installed runtime.

Source checks and all four C compilations passed in an isolated candidate; the
candidate linked and passed strict hypervisor-only code signing. Windows booted,
rendered the WebGL2 triangle, and exited with code 0 after an orderly ACPI
shutdown request on 2026-10-16. The earlier fault did not recur in that run, so
no ring or instruction dump was emitted. This does not resolve the intermittent
failure, qualify a dump, or establish a shutdown fix. No fix is claimed.

### Separate optional instruction observation

The preparer can also copy an independently reviewed header using
`--instruction-header PATH --instruction-sha256 SHA256`. Both arguments are
required together; a hash mismatch or symlink is rejected. Its include follows
the existing HVF includes, and its call is at the end of the existing ISV0
diagnostic block, after the map dump, metadata report and MR unref, before the
unchanged assert. Omitting these options produces the ring-only overlay.

The reviewed header is
`experimental/hvf-instruction-observation/observation.h`, SHA256
`ade878db283a17c93242097831fd86b4c58f22f061e96a3f2939cf9ba74761d5`.
It separately requires the exact environment `PERP_HVF_OBSERVE_INSN=1`, observes
only an AArch64 aligned instruction, and restricts the final four-byte code
copy to ordinary RAM/plain ROM. **The preceding debugger page-table walk can
dispatch MMIO and has no deadline.** This optional observation is not a
zero-side-effects operation, unlike the ring's scalar metadata collection.
The manifest records that distinction. It does not emulate/advance an
instruction or change the fatal path. This header remains separately owned;
the preparer copies its exact bytes rather than rewriting it.

### Later fault captured during a boot comparison

A subsequent boot on 2026-10-16 emitted a complete 99-entry ring with no
overwritten events, an ISV0 lower-EL write into the GPEX fallback, and a
successfully observed instruction word. BAR4 was enabled at the fault. No blob
map/add events occurred during that launch; three UNREF requests and GPU reset
markers were recorded. Therefore this capture does not establish a live blob
being detached, and must not be described as proof of that race. It occurred
before a usable desktop in the attempted O2 renderer/backend comparison; no
O2 performance measurement or improvement is established. Raw addresses and
the captured code word remain in the private fault receipt.

A fast-startup/resume path is a hypothesis, not an observed cause. Microsoft
explains that [fast startup restores kernel/driver state but devices must be
configured as after cold boot](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/distinguishing-fast-startup-from-wake-from-hibernation).
The guest boot mode has not been queried for this failed launch.
