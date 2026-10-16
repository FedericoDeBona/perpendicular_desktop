# HVF invalid-syndrome failure diagnostic

Diagnostic preparation only. No fix, instruction emulation, exception injection,
assert removal, PC advance, guest read/write, MMIO dispatch or mapping change is
implemented. The original `assert(isv)` remains immediately after the inserted
`if (!isv)` block. This directory never builds, links, signs, installs or starts
QEMU. Raw event output contains guest addresses and belongs only in private
diagnostic receipts, not a public report.

The actual native-output shutdown crash was a vCPU-thread abort at the existing
`hvf.c:2295` assertion. It occurred with explicit 4 KiB IPA granules, so that
earlier alignment correction does not establish a remedy for this new failure.
The neighboring GPU command `0x102` / error `0x1203` means RESOURCE_UNREF /
INVALID_RESOURCE_ID; its adjacency does not prove a causal mapping error.
Stock QEMU 11.1.2 still has `assert(isv)` at line 2447, with an explicit TODO
for SIMD/SVE accesses. Its RAM dirty-write branch is not a verified fix for
this crash. An upstream RFC decoder exists, but is neither applied nor
qualified here: [QEMU RFC v8 04/10, 2026-09-16](https://patchew.org/QEMU/20260916100021.73825-1-mohamed%40unpredictable.fr/20260916100021.73825-5-mohamed%40unpredictable.fr/).
It depends on the instruction-emulation library from the preceding series;
removing the assert alone does not implement those semantics.

## Exact inputs

- QEMU base Git pin: `88e5ee7ec6703662fec7b638cca74c4769e683d6`.
- Full current private `target/arm/hvf/hvf.c` preimage:
  `004a3865590a1bb834b7bc8f20169cce3da872d6a7b5cc3184973fe8c0d5357e`.
  This includes existing private changes; it is not claimed to be pristine
  upstream merely because HEAD has the base pin.
- Existing `build.ninja`:
  `3d7c980892aab9b8f4a26018fc84fd58c0cfd41b7084762e23bc11c810b2bfe4`.
- Compile edge: `libqemu-aarch64-softmmu.a.p/target_arm_hvf_hvf.c.o`.

The helper rejects any preimage/pin/recipe change, duplicate/changed assert or
already inserted marker. A prepared copy includes the local `trace.h`, so the
exact existing C flags can be reused without adding include paths. Original
source, objects, Ninja state and all native-display files remain untouched.

## Fields and safety boundary

On ISV=0, one `perpendicular-hvf-isv0-v1` line precedes the original abort:

- exact exit syndrome (`esr`), its FSC/WnR/S1PTW/CM flags;
- `pc` read directly with public `hv_vcpu_get_reg(HV_REG_PC)`, plus
  `pc_valid` and the API return code; no assertion is added for a failed read;
- exit IPA and FAR, with `far_valid` derived from FnV;
- QEMU system-memory FlatView overlap metadata at exactly that IPA: found,
  region name capped at 96 sanitized ASCII bytes, region offset/size,
  RAM/ROM/ROMD, section readonly and the raw region dirty-log mask.

`memory_region_find()` performs a metadata lookup, internally acquires its RCU
read guard and returns a referenced region; the diagnostic balances that with
`memory_region_unref()`. It does not translate through an IOMMU or dispatch a
device read. The existing region name is read directly; the lazy name getter
is avoided. No host address, memory contents, instruction bytes, general
register file or renderer payload is logged. No extra metadata is printed for
ordinary ISV=1 exits. `region_found=0` is an absence observation, not permission
to ignore the fault. The raw dirty mask excludes global synthesized clients.

The existing trace's `env->pc` need not be synchronized with HVF; this new event
uses the public register read instead. The crash report's host thread registers
do not substitute for the guest exit's PC/ESR/IPA/FAR. A mapped region observation
also does not prove that its HVF mapping is installed or that a removed blob is
safe to access.

## Prepare, then separately compile/relink

Read-only gates and pure insertion tests:

```sh
python3 experimental/hvf-invalid-syndrome/prepare.py --self-test
```

Explicit preparation creates one fresh 0700 child with 0600 files:

```sh
python3 experimental/hvf-invalid-syndrome/prepare.py --self-test --prepare \
  --output "$PWD/.tools/hvf-invalid-syndrome/prepare1"
```

The helper does not run the compiler. For a separately authorized next private
build, the exact copied Ninja compile command is saved in
`compile-command.json` and safely quoted in `compile.sh`. It is the pinned rule
`cc $ARGS -MD -MQ $out -MF $DEPFILE -o $out -c $in`, with only input, output and
dependency-file paths replaced with private paths. Run it explicitly with:

```sh
/bin/sh .tools/hvf-invalid-syndrome/prepare1/compile.sh
```

In a **new** private native-display link graph, replace exactly one token:

```text
libqemu-aarch64-softmmu.a.p/target_arm_hvf_hvf.c.o
    → /ABS/REPO/.tools/hvf-invalid-syndrome/prepare1/hvf.c.o
```

The current native build3 graph contains that relative token exactly once.
Keep its Cocoa, publisher, NDT and trace3 GPU object substitutions, complete
link flags and all other inputs unchanged. Change only the new graph's output
target to a fresh private binary; never relink over build3 or an installed
app. Record final object/binary hashes, actual dependency closure, unchanged
protected inputs and existing hypervisor-only signing separately. This helper
deliberately provides no automatic native-builder edit or link operation.

The next failure's IPA/FSC and region fields discriminate an unassigned former
blob mapping from mapped RAM/readonly/dirty tracking or another device region.
Without them, adding an emulator or changing shutdown/mapping behavior would
be speculative. The diagnostic does not claim a successful shutdown or a fix.
