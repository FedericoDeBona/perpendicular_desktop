# Narrow AArch64 STP Q handling in the GPEX PCI hole

This is an **opt-in experimental execution change**, not a general ARM emulator
or a driver fix. It addresses one decoded form observed at an actual HVF ISV0
abort: `STP Qt, Qt2, [Xn, #imm]` (two 16-byte stores, signed-offset addressing,
no writeback). The signed 7-bit immediate is scaled by 16 and ranges from
−1024 through 1008 bytes. Raw guest addresses remain private. The decoded word was also
checked using Apple's `llvm-objdump`; a matching sequence in a signed DLL was
only a decoder fixture, not attribution of the fault PC to that DLL.

The unchanged QEMU handler asserts for an unknown ISV0 data access. An isolated
candidate includes `emulate.h` and calls `perp_hvf_stp_q_pci_hole` before that
assert. Only a true return sets the existing `advance_pc` flag; the original
assert remains for rejected accesses. The default-off switch is exactly
`PERP_HVF_STP_Q_PCI_HOLE=1`. This is not enabled in the installed application.

## Accepted operation

All these conditions are required before dispatch:

- Lower-EL AArch64 data abort, IL=1, ISV=0, write, translation FSC4..7;
  no cache maintenance, stage1 table-walk, invalid FAR or external abort flag.
- Actual synchronized CPU state is EL0 and little-endian. Explicit SCTLR_A
  alignment rules remain checked. SP-based instructions are excluded.
- The current code word decodes to the exact signed-offset, no-writeback STP Q
  form. Checked addition/subtraction computes `Xn + sign_extend(imm7) * 16`;
  overflow/underflow is rejected, and FAR must equal this effective address.
  Xn is not modified. Both negative and positive offsets are allowed; no other
  addressing form is admitted.
- The entire 32-byte VA/IPA interval fits within one minimum 4K page, without
  wrapping; both page offsets agree. Operand addresses are not translated with
  debugger permissions. A cross-page access remains unsupported.
- `memory_region_find` covers all 32 bytes with the exact GPEX fallback name
  **and** the exact `unassigned_io_ops` pointer, under BQL. RAM, ROMD, real
  devices and partial overlaps are rejected.
- Both SIMD registers are successfully read on the owning vCPU thread using
  the Hypervisor API. Their 32 bytes are dispatched through
  `address_space_write`; PC advances only on `MEMTX_OK`.

The pinned `hw/pci-host/gpex.c` explicitly assigns ignored-write semantics to
PCI holes through `system/ioport.c`'s `unassigned_io_write`. The ordinary scalar
ISV handler already dispatches accesses through this bus. This candidate follows
that same bus behavior for the qualified pair store, rather than advancing a PC
without decoding or dispatch. It does not retain/recreate a GPU resource or
pretend a store reached memory that is no longer mapped.

The captured address was only 8-byte aligned; imposing an unconditional 16-byte
alignment would reject a permitted normal-memory store. Stage1 device alignment
and permissions precede the observed stage2 translation fault; see
[Arm fault prioritization](https://support.arm.com/documentation/ddi0487/md/-Part-D-The-AArch64-System-Level-Architecture/-Chapter-D8-The-AArch64-Virtual-Memory-System-Architecture/-D8-15-Memory-aborts/-D8-15-5-MMU-fault-prioritization-from-a-single-address-translation-stage?lang=en)
and pinned `target/arm/ptw.c`. The runtime SCTLR_A guard remains mandatory.

## Boundaries and validation

Instruction observation uses debugger page translation, then copies exactly
four code bytes from plain referenced RAM/ROM. Intermediate page-table reads
can dispatch MMIO and have no hard deadline. This has the same explicit side
boundary as the separate instruction observer; it is not a side-effect-free
metadata probe. The code observed at the current PC may have changed after the
fault. The final operand write uses the hardware fault IPA, not debugger data
translation. No general-register or operand payload is logged; successful
handling emits at most 64 fixed metadata lines.

MTE and other CPU profiles, other instructions, reads, writeback,
EL1/BE, multi-page accesses and device side effects are not qualified. A correct
PCI-hole write does not identify why Windows or a driver reached that hole.
The 99-entry boot journal contained no blob maps, so it cannot establish an
UNMAP lifetime race. Fast startup is an unconfirmed hypothesis.

`check.c` exhausts all 128 immediates × 32768 register combinations, including SP
rejection, and checks the observed opcodes, signed endpoints, arithmetic
overflow/underflow, invalid offsets, adjacent addressing/type bits,
loads/integer stores, unsupported abort classes/flags and page/wrap mismatches.
These are decoder/range checks, not a synthetic proof of the complete HVF path.
The former zero-offset candidate compiled, linked and passed strict signing
with only the hypervisor entitlement. Its actual private Windows boot logged
one successful 32-byte dispatch for `0xad000400` (`stp q0, q1, [x0]`), then
asserted at PC+4 for `0xad011404` (`stp q4, q5, [x0, #32]`) with FAR+32.
Both opcodes were independently decoded with Apple's LLVM tool using an
existing byte-identical fixture; no module attribution is inferred.
That checkpoint motivates only the signed-immediate extension here; it does
not qualify full execution, successful boot or shutdown of the new candidate.

```sh
cc -std=c11 -Wall -Wextra -Werror experimental/hvf-stp-pci-hole/check.c -o /tmp/perpendicular-stp-check
/tmp/perpendicular-stp-check
python3 experimental/hvf-stp-pci-hole/prepare.py --output "$PWD/.tools/hvf-stp-hole/prepare-new"
```

The preparer pins the exact prior combined diagnostic manifest/source and
protected inputs, proves insertion-only restoration, copies the two local
headers, and writes one compiler recipe to a fresh private output. It performs
no compilation, signing, VM start, disk copy or installed-runtime replacement.
The existing isolated native build procedure replaces only the prepared HVF
object; other GPU/PCI/reset objects remain identical to the map candidate.
