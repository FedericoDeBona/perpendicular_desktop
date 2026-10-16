# Imported Windows boot diagnosis — 2026-10-16

These observations concern the imported Perpendicular copy of the user's
Windows 11 ARM64 installation. The original Parallels bundle and the verified
read-only source disk clone remain preserved. They do not concern the older
Windows 3D trial recorded on another checkout.

## Storage filter experiment

After the pending Desktop access request resolved, the existing owned QEMU
process answered QMP again, with the same launch identity and running state.
The diagnostic ISO was attached read-only from Application Support instead of
Desktop. Its digest matched the prepared image. No duplicate VM was launched.

The guarded WinRE script backed up the disk-class and `prl_strg` service keys,
then removed only `prl_strg` from disk-class LowerFilters, retaining
`EhStorClass`, and set `prl_strg.Start` to 4. The complete SYSTEM hive had
already been saved as `C:\PerpendicularCrashBackup.hiv`. Readback and hive
unload succeeded. An explicit normal Windows boot still stopped before the
desktop. Startup Settings option 9 disabled automatic restart for one boot,
allowing the visible stop code to be read: **0x139**.

This experiment did not resolve the failure and does not establish that the
storage filter caused the original crash.

## Held-kernel evidence

No Windows dump file was available from the earlier inspections. Read-only
QMP/HMP register and bounded virtual-memory reads were therefore taken while
Windows remained on its held stop screen. Every request checked the owned
launch identity; subsequent reads also checked the held CPU program counter.
Memory samples, raw monitor responses and digest receipts remain private.

An ARM64 PE header in kernel memory and its export directory identified
`ntoskrnl.exe` and the `KeBugCheckEx` and `PsLoadedModuleList` exports. REA
6.5.0 / Ghidra 12.1.4 analyzed a bounded capture of `KeBugCheckEx` and its
direct callee. Original instructions confirmed the stores of the bugcheck
code and four arguments to a contiguous global record. Its captured code
agreed with the visible 0x139 screen. These are **runtime-memory captures**,
not authenticated copies of the on-disk Microsoft binaries. Their REA raw
target classification does not change that provenance.

| Observation | Captured value |
| --- | --- |
| Bugcheck code | `0x139` |
| First argument | `0xe5368830` |
| Exception code | `0xc0000409` |
| Exception address | `0xfffff8029d57ccf8` |
| Exception information[0] | `0xfffff68fe5368830` |
| Containing loaded module | `prl_fs.sys` |
| Module base / SizeOfImage | `0xfffff8029d570000` / `0x31000` |
| Exception RVA | `0xccf8` |

Microsoft documents argument three as the exception-record address for
[bugcheck 0x139](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/bug-check-0x139--kernel-security-check-failure).
The captured first argument is not assigned a corruption category by that
page's table; it is retained without guessing its meaning.

The module-list walk checked forward/back link consistency and validated its
observed field layout against the already identified kernel's base,
SizeOfImage, exception directory and UTF-16 name. It reached the containing
module after 150 entries. The candidate module's resident PE header separately
confirmed ARM64 and matching SizeOfImage. These checks support fault-site
attribution to `prl_fs.sys`; they do not prove where corruption originated.
This is not a PDB-backed structure decode or a complete WinDbg crash analysis.
A larger outer-stack read encountered inaccessible memory; its partial output
was excluded from the conclusions.

REA receipts:

- Entry wrapper: `ev_83c07b0765024cfc95ff02a20f4445982e51d9ef476421bf978ae8c35c336e67`.
- Direct callee: `ev_c1dd5266edc8b23fd97ef6be9abbb92e91ca7248cdec2ccced240956e4888e6b`.

## Targeted filesystem-driver experiment

After preserving the held-crash evidence, QMP quit completed and the owned
process exited. The locally verified app candidate containing the control
availability fix was installed; the previous app was retained separately.
Deep strict signature verification passed before and after installation.
The same VM started from the updated installed app, using the existing 2D
QEMU runtime and unchanged CPU/memory/disk settings.

WinRE confirmed `prl_fs` is **Parallels Shared Folders**, Type 2,
Start 1, Group NetworkProvider, dependent on `prl_tg`. ControlSet001 remained
the selected set. A guarded script saved another complete SYSTEM hive as
`C:\PerpendicularBeforeFs.hiv` and exported the service key as
`C:\PerpendicularFsBefore.reg`, then changed only `prl_fs.Start` from 1 to 4.
All backup operations, readback and hive unload succeeded. This affects the
imported guest's Parallels shared-folder integration. No other Parallels
service was changed in this step.

The subsequent normal boot reached the Windows welcome screen and then the
user desktop in the updated installed app. A pointer click opened Start, and
typing `notepad` appeared correctly in Windows Search. This verifies one
desktop boot and basic pointer/keyboard input after the targeted change.
The earlier storage-filter change remains applied, so this is not an isolated
A/B test. Long-term stability, 3D acceleration, display resizing, Guest Tools
and input-to-image latency remain unverified. The imported VM remains running;
the original Parallels VM remains stopped and preserved.


## Guest Tools bootstrap on the imported installation

The pinned UTM driver source still matches SHA-256
`65b6a69b392ee01dd314c10f3dad9ebbf9c4160be43f5f0dd6bb715944d9095b`.
The provisioner can now use a read-only, hidden macOS ISO mount when SevenZip
is unavailable. The source mount is detached on success and on copy/content
failure. Downloads identify the application, verify the existing source pin
and publish their cache entry only after a complete verified download.
Native extraction prepared 113 ARM64 driver files. The remounted output disc's
134 manifest-listed files all matched their hashes; no autorun or unattended
Windows setup file was present. Simulated copy and missing-content failures
independently verified mount cleanup.

The disc was attached read-only to the owned running VM. Its explicit Windows
GUI installer accepted the network and serial packages; the visible network
result was 0 (`oem9.inf`) and serial output identified `oem10.inf` installed on
the expected VirtIO PCI device. The user-tools step reported installation and
requested task startup. The read-only diagnostic then confirmed the exact
owned package and limited interactive task, one agent in desktop session 1,
and a present VirtioSerial device with configuration error 0. Native source
compilation, the bounded-reader memory check and Windows Forms availability
passed. **Opening the fixed Guest Tools port failed with Win32 error 5.**
The host consequently still reports a guest-agent timeout; installation does
not establish a connected channel.

An administrator `Inspect` invocation confirmed the unique healthy raw port,
classless setup identity, exact desktop SID/task ownership and the need for
only that SID's read/write access on that PDO instance. It did not change any
permission. Applying the prepared per-instance correction remains pending
explicit user confirmation.

A Windows `Test-NetConnection www.microsoft.com -Port 443 -InformationLevel
Quiet` returned `True`, verifying name resolution and a TCP connection from
this guest. TLS/HTTP behavior, throughput and sustained network reliability
were not measured.

The VM subsequently completed a normal engine-requested shutdown, without
force. While stopped, the diagnostic installer medium was ejected and the
verified driver disc was saved as its Guest Tools ISO. The host-side keyboard
layout was changed from `en-us` to `it` to match this installation's observed
Italian Windows layout. CPU, memory, disk and display adapter were unchanged.

The updated normal app subsequently launched the same VM again and reached
the desktop. This adds a completed normal shutdown/restart after driver and
agent installation; it remains a bounded boot check, without proving sustained
stability or a working Guest Tools channel.
