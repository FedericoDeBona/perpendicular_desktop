# Optional four-byte pre-abort instruction observation

This is a separate, default-off diagnostic header for the pinned private
AArch64 HVF translation unit. It does not decode, execute, emulate, advance,
skip or inject an exception for an instruction. The original ISV assertion
remains unchanged. No compile, VM operation or runtime environment change is
performed by adding this source.

Integration owner: the bounded map/BAR overlay prepares the single combined
HVF source. Copy `observation.h` into its isolated include directory, include
it after the existing HVF includes, and place this call at the end of the
existing `if (!isv)` diagnostic block, **after** its map/BAR dump, metadata
record and final `memory_region_unref`, immediately before the block closes
and the original `assert(isv)`:

```c
perp_hvf_observe_instruction(cpu, syndrome);
```

The helper independently requires ISV=0 and the exact environment value
`PERP_HVF_OBSERVE_INSN=1`. Missing, empty, `0` and other values return without
CPU synchronization, translation, memory access or logging. The coordinator
must opt in explicitly for a selected diagnostic candidate; this header does
not configure that environment or modify an application.

For an opted-in fault it synchronizes the existing HVF CPU state, requires
AArch64 and a four-byte-aligned current PC, then uses the established
`cpu_get_phys_page_attrs_debug` translation. It validates the resulting address
space and references the final four-byte FlatView overlap. Only ordinary RAM
and RAM-backed plain ROM are accepted; RAM devices, ROMD, missing/short regions,
missing backing and discard-managed backing are rejected. The final read is
one `memcpy` of exactly four instruction bytes from that RAM backing. Every
returned region reference is released. It logs only a fixed status and, on
success, the little-endian 32-bit instruction value. No PC, page-table entries,
TTBR/TCR/PSTATE values, memory block, data operand, general register or other
guest bytes are logged by this header.

## Explicit side-effect boundary

**This is a debugger-style code/page-table read, not zero-MMIO metadata.** In
the pinned implementation, `arm_cpu_get_phys_page_attrs_debug` sets `in_debug`;
`S1_ptw_translate` leaves `out_host=NULL`, and `arm_ldl_ptw`/`arm_ldq_ptw` perform
page-table reads through `address_space_ld*`. Malformed or unusual guest table
addresses can therefore dispatch MMIO callbacks during translation. Checking
the final code region happens later and cannot prevent those intermediate
callbacks. They may have device side effects or block; there is no hard native
I/O deadline. The `in_debug` walk avoids guest AF/dirty table updates, but it
does not turn device reads into metadata.

The header's final instruction read itself cannot dispatch MMIO, because it
requires ordinary RAM-backed memory and copies directly from its referenced
backing while the existing data-abort path holds the BQL. It uses no additional
memory transaction after that guard. This is narrower than a normal
`cpu_memory_rw_debug(..., 4, false)` final read, while retaining the same debug
translation side-effect boundary. Standard CPU synchronization and debugger
translation can still fail internally as they can for an ordinary debugger;
this helper does not install an error-recovery or signal handler around them.

Debug translation is appropriate only to observe this code word. It is **not**
an architectural emulation access: in particular the current ARM debug helper
requests `MMU_DATA_LOAD` with `in_debug=true`, even when a caller later intends
to emulate a store. It must not be reused as proof of store permission,
architectural fault routing or successful instruction completion.

## Source provenance and validation limit

- QEMU base pin: `88e5ee7ec6703662fec7b638cca74c4769e683d6`.
- Existing diagnostic `prepare2/source/hvf.c` SHA-256:
  `0c53b98aad106e793439e4523918c55bc7d537086c677fe0441311670ac3b11f`.
- Relevant exact paths under `.tools/graphics-experiment/src/qemu/`:
  `target/arm/ptw.c` (debug translation and PTE reads),
  `system/physmem.c:3701` (standard debugger access),
  `system/memory.c:2817` (FlatView lookup/reference),
  `system/memory.c:2442` (RAM pointer), and
  `accel/hvf/hvf-accel-ops.c:265` (CPU synchronization).

The combined preparer must pin this header's complete hash, copy it privately,
record the optional flag and the PTW side-effect boundary in its receipt,
preserve all pre-existing bytes except the include/call, and retain the exact
original assertion. The header compiled in the isolated combined diagnostic candidate. That VM
booted and exited cleanly after an orderly ACPI shutdown request; no ISV0
fault occurred, so the observer branch and its instruction output remain
unqualified at runtime. Actual code bytes, if captured later, remain private
debug evidence. Successful
observation would identify an instruction; it would not prove a shutdown fix.
The word is observed at that PC after the fault; concurrent guest writes could
change code between the exit and this read. It does not identify a module or
prove that self-modifying code still contains the originally executed word.

A later boot of that same candidate did reach ISV0 and emitted `status=observed`
with one four-byte code word, followed by the unchanged assertion. The map
journal contained all 99 events without overwrites. This qualifies the narrow
observer path in that run, not instruction emulation or fault recovery.
