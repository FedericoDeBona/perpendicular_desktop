# Per-port Guest Tools access correction

Checkpoint on 2026-10-15: **the reviewed per-instance permission change was
applied after the user's action-time approval**. Actual Windows Inspect
confirmed the exact classless raw child, read its live DACL and completed the
one-SID delta plan. Apply saved a protected rollback receipt and verified the
property readback. The receipt identifier remains private.

The helper reported `RuntimeAccessVerified=False` **before** the restart; it
does not itself test communication. After the same-account agent update and
Windows restart, the macOS app actually displayed **Guest Tools connected** and
**Perpendicular Guest Tools 0.2.0**. This is the separate observed post-restart
connection checkpoint. Clipboard/file actions were enabled, but their actual
operations and automatic resizing have not yet been demonstrated. Source
preparation and packaging did not execute Apply; the separately approved
coordinator action did.

## Why this is a candidate

The reviewed VirtIO serial source creates each child as an exclusive raw PDO,
assigns `SDDL_DEVOBJ_SYS_ALL_ADM_ALL`, and registers the port interface
`{6fde7521-1b65-48ae-b628-80be62016026}`. Its fixed host-supplied name is exposed
as a DOS symbolic link. A healthy PCI controller/installed signed driver does
not establish that the limited desktop user may open that child. The observed
Win32 error 5 is consistent with this descriptor; it is not proof that changing
an ACL will resolve every possible error 5.

Reviewed local sources are in `.tools/vioserial-source-review/`, especially
`Port.c` (raw PDO creation around 299–306; named link around 954–964), `public.h`
(interface GUID), and `vioser.h` (raw hardware/class GUID). They are the upstream
[VirtIO Windows driver sources](https://github.com/virtio-win/kvm-guest-drivers-windows/tree/master/vioserial/sys),
not proof of the exact instructions in the installed signed binary. The helper
therefore requires observed Windows device identity and the actual descriptor;
it never manufactures the expected SY/BA descriptor from this source.

Local review file SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `Port.c` | `0dcad662e14e9d5d5ed43bf6f068e961afc08a018ce8002100571abca7f09c33` |
| `public.h` | `1719b2d0c1a5d1e885c565ad8a4fd114c8f63cad21eab5a7f8652f6b49a89201` |
| `vioser.h` | `de2f02c7f6d833265cbd732229e32600ecb58f1c439b6d06581fd21ba633bbc0` |

A focused static REA/Ghidra 12.1.4 inspection of the distributed
`Drivers/vioserial/w11/ARM64/vioser.sys` (SHA-256
`b7a4329b3ecacd3532365ee1c5f80a57e48f14e5f3bf111b22ae14178ab896e1`)
found the exact hardware-ID literal at image address `0x1400168c8`, the raw
class GUID bytes at `0x1400113c8` (file offset 64968) and port-interface GUID
bytes at `0x140011418` (file offset 65048). These agree with the reviewed source,
so there is no observed constant discrepancy in that artifact. Evidence IDs:
`ev_4443c4df0223d23112f1a9e9c381b77f5168c0e87ca8a1183886e138ecffa10c`,
`ev_1f466fde586360a4e6136a41ef2fe9bfaf304ef92ec9ca1b5469aa38487176a4`,
`ev_212f597ba6ede36250961593f68171e77e3052cd9272096b0575b81e57b1e53e`.
This is static literal/byte evidence, not execution or a claim that Windows
loaded that exact binary. Its accompanying INF reports controller class
`System`, service `VirtioSerial`, and DriverVer `01/13/2025,100.100.104.27100`;
the PCI controller's class is not evidence for its raw child PDO's class.

Important correction to the original class assumption:
[Microsoft's WdfPdoInitAssignRawDevice remarks](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdfpdo/nf-wdfpdo-wdfpdoinitassignrawdevice)
state that its `DeviceClassGuid` identifies the registry section for device
security overrides; it does **not** set the PnP device setup class. The latter
comes from an INF. The examined package has no separate raw-child INF.
Therefore the presence of that GUID in source/binary does not establish that
`SP_DEVINFO_DATA.ClassGuid` or the raw child's setup-class property must equal
it. The old class gate was retained through the explicit legacy/capability
checkpoint; the separately reviewed source correction below now admits only
a precisely confirmed classless raw child or an agreeing explicit expected
class. No class-wide registry setting is read or written.

Microsoft documents [per-instance DEVPKEY_Device_Security](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/devpkey-device-security)
as a binary security descriptor writable by installers through
[SetupDiSetDeviceProperty](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdisetdevicepropertyw).
Its SDK key is `{a45c254e-df1c-4efd-8020-67d146a850e0},25`, type `0x13`.
[WDF descriptor defaults can be overridden by registry policy](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdfdevice/nf-wdfdevice-wdfdeviceinitassignsddlstring),
and [WDM access rules describe registry overrides of bus-supplied PDO security](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/controlling-device-access).
This supports a narrowly scoped proposal; it does not prove this driver's
effective policy or an immediate effect on an already-created PDO.

## Identification and ownership gates

`GuestTools/Set-PerpendicularGuestChannelAccess.ps1` defaults to **Inspect**.
It loads the independent `PerpendicularChannelAccess.Native.cs` and only the
named function declarations of the existing diagnostic ownership validator;
it never executes the diagnostic entry point or Guest Agent. It accepts no
device path, instance ID, SID, SDDL or permission mask from the command line.

Before inspecting security or changing any property it requires:

1. Windows PowerShell 5.1 in an interactive desktop session. The current token
   user must equal the WTS account of that session. The installed ownership
   manifest and exact user task must agree with that SID. The task must remain
   limited, interactive, with the exact owned executable/script/options.
   Alternate administrator credentials and non-domain-style SIDs are currently
   refused; there is no SYSTEM service or elevated agent/task alternative.
2. The one explicit global DOS alias `Global\org.perpendicular.guest_agent.0`
   must resolve to exactly one target, without historical/ambiguous mappings.
   [Global names avoid a local DOS alias shadow](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/local-and-global-ms-dos-device-names);
   [QueryDosDevice](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-querydosdevicea)
   returns mappings rather than opening the channel.
3. Enumerate only present interfaces of the published VirtIO port GUID, at most
   256. Bind the interface directly to its `SP_DEVINFO_DATA` using
   [SetupDiGetDeviceInterfaceDetail](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetdeviceinterfacedetailw),
   without parsing an interface path. Exactly one child PDO name must equal
   that global target. Its sole hardware ID must be the published raw port
   `{6fde7547-1b65-48ae-b628-80be62016026}\VIOSerialPort`, and its instance ID
   must belong to that device ID. The raw capability must be observed. Setup
   class must satisfy exactly one of the two independently verified metadata
   branches below; an arbitrary absent/invalid/error value is not accepted.
4. [CM_Get_Parent](https://learn.microsoft.com/en-us/windows/win32/api/cfgmgr32/nf-cfgmgr32-cm_get_parent)
   must identify a started, healthy direct PCI parent with service
   `VirtioSerial`, vendor `1AF4` and serial device `1003` or `1043`. The parent's
   hardware IDs must agree with its instance ID. A filename `vioser.sys`, a
   friendly name, the first enumerated device, or the controller alone is
   insufficient. Unknown/missing properties, duplicate matches and device
   changes are failures.

This identifies a candidate using the installed driver's observed properties;
it is not a binary driver authenticity test. Existing signed-driver/catalog
acceptance remains a separate prerequisite. An administrator controlling the
guest can already modify driver/device configuration; this helper provides no
protection against a malicious administrator.

The diagnostic and this helper now share
`Get-DiagnosticTaskOwnershipChecks`. Before a failed task gate, the helper emits
`ScheduledTaskOwnershipChecks=` with ten independent bool/code clauses: Name,
Path, Description, UserId, LogonType, RunLevel, Actions, Execute, Arguments and
WorkingDirectory. It reports only fixed representation labels, known enum
tokens or bounded neutral numeric codes, the `@($Task.Actions).Count` result and
the first action's shape. It never serializes the source task, SID, account,
paths, command line or exception messages. All original comparisons remain:
integer `3`/`0` and numeric strings are diagnosed but not newly accepted as
Interactive/Limited. Unknown or missing properties remain failures. An early
mismatch cannot hide the remaining clauses.

The coordinator's next real Windows report matched every clause except
**UserId**. Task/principal/first-action were genuine CIM instances, LogonType and
RunLevel were named Interactive/Limited enums, and Actions was a one-item array.
There is no evidence of a numeric-enum or collection-count bug. A subsequent
read-only `PrincipalIdentity` report therefore resolves the **actual** principal
through Windows `NTAccount.Translate(SecurityIdentifier)` (or validates a literal
SID), compares the returned canonical SID exactly with the owner SID, and exposes
only `PrincipalSidResolved`, `PrincipalSidMatchesOwner`, identity kind
`qualified`/`unqualified`/`sid` and a fixed result code. It never strips a domain,
adds a guessed machine/domain prefix, logs either identity or changes a task.

The next actual Windows Inspect on the 293-fixture ISO reported
`PrincipalSidResolved=true`, `PrincipalSidMatchesOwner=true`, kind `unqualified`
and code `sid_match`, while the old textual UserId clause remained false. This
is OS identity evidence for the observed task, not a guessed account alias.
Based on that checkpoint, the separately reviewed source change makes only
**UserId** depend on successful canonical SID resolution and an exact owner SID
match. All nine other task clauses retain their original comparisons. There is
no name fallback: resolution failure or a different SID rejects even an account
string or SID spelling that the old predicate accepted. No task is rewritten.

Resolvers are injectable only as an internal test dependency; the script's CLI
offers no resolver/SID override. Fixtures replace OS resolution with pure data
and cover exact input forwarding, qualified/unqualified/SID shapes, mismatched
SID, lookup exception, invalid/array output and privacy. Causal fixtures show
that the proven normalized name is accepted only on the exact SID match and
that an old matching spelling is rejected if OS lookup fails or differs.
The actual subsequent Inspect on the 308-fixture ISO passed `Owned=true` and all
ten task clauses, with the same canonical unqualified `sid_match` evidence. It
then threw `Unexpected raw-port identity` during present-interface/PDO metadata
lookup, before the live descriptor open or any security-property write. Thus
the task-gate correction is observed; no port permission change is established.

The agent installer and uninstaller now reuse only the same three identity
function declarations, read through the parser from the diagnostic source.
They preserve their existing independent description/action and manifest
guards. The source is a required fixed runtime file, copied on upgrade and
removed only by the known-file uninstaller list; the disc provisioner already
declares it explicitly. Older owned manifests can upgrade without claiming
they already included that source, but product and exact owner SID are still
required. A missing source does not enable a textual ownership fallback.
The new 118-check portable suite verifies both scripts and uses only injected
resolvers; it neither runs an installer nor calls Windows identity/task APIs.

The initial per-clause source delta emits `GuestChannelPortIdentityChecks=` on the host
information stream when the existing native identity gate rejects its matched
candidate. It contains separate class equality, sole hardware-ID equality,
instance prefix/suffix, exact global alias, parent PCI/service/hardware and
health booleans. Its aggregate `FailureCode` follows the original gate order.
Class/hardware kinds use fixed labels only; counts use `-1` for unavailable,
0–64 for observed bounded lists and 65 for an oversized list. It does not print
raw device/instance paths, hardware IDs, GUID values, SIDs, task commands,
exception messages or security descriptors. Only the typed native report is
accepted from a bounded exception chain; arbitrary exception data is ignored.
At that checkpoint `ValidatePort` retained all original comparisons. A rejected candidate emits
the report before reading even the per-instance security property. Missing or
ambiguous alias/enumeration failures still stop without inventing a candidate.
The report is also available after a successful complete Inspect. Refreshed
source must run in a fresh Windows PowerShell process from the readonly ISO;
an existing Add-Type class must not be mistaken for the new native source.

The actual fresh Windows Inspect on the 158-helper/308-diagnostic ISO passed
task ownership and every PDO metadata clause except class equality. It reported
`ClassGuidKind=empty`, one exact hardware ID, valid instance prefix/suffix,
exact alias mapping, a matching healthy direct `VirtioSerial` PCI parent with
four hardware IDs, and no child/parent problem. This does not prove that the
NULL detail probe returned partial output: [Microsoft documents that it fills
SP_DEVINFO_DATA even with a NULL detail buffer](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetdeviceinterfacedetailw).
The setup class may actually be absent on this raw child.

The following read-only delta therefore observes
[SPDRP_CLASSGUID, a REG_SZ setup-class property](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetdeviceregistrypropertyw),
on that same matched devnode instead of assigning the detail-probe field.
`ClassGuidSource`, `ClassGuidReadCode` and the actual numeric API failure code
separate a valid observed property, unavailable API/property and malformed data.
`InterfaceDetailClassGuidKind` retains only the earlier field's fixed kind.
There is no fallback to a driver constant, the probe field or the parent's class.
An observed empty/different class still fails the unchanged gate.

The same report also reads the matched devnode's `SPDRP_CAPABILITIES` using a
fixed four-byte buffer and requires REG_DWORD/exact length. It exposes only
`CapabilitiesObserved`, `RawDeviceOk`, source/read codes and numeric API error,
not the whole flags value. `RawDeviceOk` is true only for an observed
`CM_DEVCAP_RAWDEVICEOK` bit, `0x40`, as defined in the
[Microsoft SDK header](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/cfgmgr32.h).
At that checkpoint both observations were collected even if the other was
unavailable, then missing or malformed properties stopped before any DACL
read. Raw capability added evidence only and did not change acceptance.

The actual fresh Windows Inspect using the 208-helper source then observed
legacy `SPDRP_CLASSGUID` error **13**, empty interface-detail class, and an
actually observed `SPDRP_CAPABILITIES` DWORD with **RawDeviceOk=true**, error
zero. Hardware/instance/alias/parent/health still passed. Legacy error 13 means
absent **or invalid** property and alone cannot establish classlessness.

The latest source therefore adds the exact SDK
[DEVPKEY_Device_ClassGuid key](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/shared/devpkey.h),
`{a45c254e-df1c-4efd-8020-67d146a850e0},10`, through the existing
`SetupDiGetDevicePropertyW` import with a fixed 16-byte buffer. A successful
value must be exactly `DEVPROP_TYPE_GUID=0x0d` and 16 bytes; malformed data
clears any previous observation. Only the API's exact
[ERROR_NOT_FOUND1168](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetdevicepropertyw)
means the requested property does not exist. Error 13, access denied,
insufficient buffer and every other failure remain unavailable, not absence.

The reviewable validator requires an observed error-free raw capability and
every existing exact hardware/instance/alias/direct-parent/health clause, plus
exactly one setup-class branch:

| Branch | Required observations |
| --- | --- |
| Explicit expected class | Legacy and unified queries both succeed, with the exact expected GUID and no error; the detail field is empty or agrees with that GUID. |
| Confirmed classless child | Unified query reports only 1168, legacy query reports only 13, both stored GUID values and the detail field are empty. |

The report adds `UnifiedClassGuidKind/Source/ReadCode/PropertyError`,
`ExpectedSetupClassConfirmed`, `ClasslessConfirmed`, `SetupClassAccepted` and
fixed `SetupClassIdentityCode`. A classless child keeps its observed GUID
values empty; it is never assigned the security-override GUID. There is no
fallback on matching hardware alone, arbitrary errors, stale values or raw
capability without the remaining identity checks. Duplicate alias/interface
matches still fail. Any present other/empty class, malformed type, inconsistent
metadata or unresolved API failure rejects the device before DACL access.
After review, the actual fresh Windows Inspect using the unified 355-check
source reported **ClasslessConfirmed=true**, unified error1168, legacy error13,
empty probe, **RawDeviceOk=true** and **Valid=true**. It then read the actual
PDO DACL and completed the exact delta plan. This validates the classless
branch on the observed device; the explicit-class branch remains fixture-only.
Source changes themselves did not authorize a write. The user subsequently
gave action-time approval, and the coordinator performed Apply as recorded below.

## Actual descriptor, exact delta and restart limit

Security inspection opens only the fixed endpoint, exclusively, with
`READ_CONTROL` and overlapped mode. It requests only the actual DACL through
[GetKernelObjectSecurity](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getkernelobjectsecurity),
then closes the handle. It performs no read/write/IOCTL/protocol transaction.
**Create/close can still change the driver's open/connected state briefly.**
An existing exclusive opener or unsupported security query causes a real error
and no property write. There is no fallback to assumed driver defaults.

If a per-instance override already exists, its DACL must match the observed live
DACL before it can be used as the source. The complete existing descriptor is
preserved, including owner/group/SACL bytes, control bits and ACE order. If no
override exists, the source is the returned DACL-only descriptor; the proposed
property specifies that DACL rather than supplying a replacement owner, group
or audit policy. Runtime owner/SACL are not read or modified by a live setter.
No audit privilege is enabled to read a SACL from the kernel object.

The only new ACE is an explicit allow for that one verified desktop user SID,
mask `0xC0000000` (**GR/GW**). It grants no generic-all, execute, ownership or
DACL-edit right. Existing ACEs stay byte-for-byte and in order; a new explicit
ACE precedes inherited entries. An existing matching grant is a no-op. Empty,
null, malformed, oversized, overlapping, noncanonical or unsupported DACLs and
any deny ACE require manual review and are refused, rather than rewritten.

Apply re-enumerates the port and compares its stable instance and parent IDs
and the exact current property bytes immediately before a conditional write.
It also reopens the fixed alias with READ_CONTROL, compares the **actual live
DACL** with the plan's observed DACL even when the override is still absent,
checks the alias still maps to that PDO, and retains that same handle through
write/readback. A changed or unreadable live policy cancels Apply. There is no
atomic cross-policy transaction with another administrator; these checks bound
and refuse observed drift rather than claiming a general race-free policy API.
It calls only the per-instance property API and verifies its readback. It never
writes a setup-class policy, service ACL, filesystem device ACL or controller
ACL; it does not change the driver, task privilege, TPM, firmware or Windows
signature/security settings. There is no automatic restart, disable/enable,
driver reinstallation or fallback access mechanism.

The configured property may affect the PDO only when it is recreated. The
helper therefore reports `RuntimeAccessVerified=False` even after successful
write/readback. Per-instance state can be lost or refer to a different instance
after driver reinstall, port ID/order/controller changes or device removal;
there is no automatic reapply or broader policy. A manual restart followed by
the original limited-user channel test and an actual `display.status` response
is required. Host window scaling, task state and a successful API write are not
acceptance evidence.

## Review, optional execution and rollback

The coordinator performed the Inspect and Apply checkpoints after source review
and the user's explicit action-time approval. The implementation agent only
prepared source, fixtures and documentation. **The approved Apply has completed;
do not repeat it.** Rollback has not run.

For the tested Windows PowerShell 5.1 route, use an interactive administrator
console under the same logged-in desktop account and the reviewed mounted
read-only disc. Replace `D:` with its actual letter. A fresh child avoids a
stale Add-Type class. Unsupported mapping/property/security queries still stop:

```powershell
# Read-only metadata and descriptor inspection from the same-account admin console.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1" -Mode Inspect
```

Apply and rollback also require that helper's package be on a CD-ROM drive,
refusing user-writable staged paths. There is no autorun or installer button;
the normal agent installation never invokes this helper. The successful Apply
used the following form after approval, then the normal interactive
`ShouldProcess` prompt. The coordinator selected localized **S** (yes):

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "E:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1" -Mode Apply
```

Passing `-Confirm:$false` through external `powershell.exe -File` failed Boolean
binding in Windows PowerShell 5.1. The tested command omits that option and
`-NonInteractive`, allowing the normal confirmation prompt. The helper's
earlier automatic `-RequestElevation` child used that affected command line;
the successful acceptance run used the same-account administrator console
above. No script was changed during that acceptance. `-WhatIf` remains available
for `ShouldProcess`. The completed approved operation does not need another
approval or repeat execution.

A later source-only fix replaces that child command line with fixed
`-EncodedCommand` syntax using strict UTF-16LE, as documented by
[Microsoft's PowerShell CLI reference](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1).
The fixed helper path is one single-quoted literal with apostrophes escaped;
only the existing Mode allowlist and a canonical receipt UUID for Rollback
can enter the payload. `-Confirm:$false` is now actual PowerShell Boolean syntax
inside the payload rather than a native `-File` argument. Parent ShouldProcess,
readonly-package verification, `RunAs`, `-NonInteractive`, STA, UacChild and all
owner/device/receipt guards remain in place. The payload builder is internal;
the helper's CLI has no new input or evaluation option.

The targeted portable suite passed **471 checks**, including syntax-tree
validation of adversarial quote/path data and a harmless child PowerShell
process that invoked only a temporary stub. All three modes bound UacChild
and Confirm:false correctly, completed noninteractive ShouldProcess and kept
the receipt restricted to Rollback; a stub failure produced a nonzero exit.
No real helper entry point, UAC, device or security operation ran. Portable
macOS pwsh omits only the unsupported STA host option for the harmless child;
the production option and exact payload are checked. Actual Windows PowerShell
5.1 elevation with this source fix remains unverified. No disc or installed
helper was updated, and the successful existing permission change was not
repeated.

Before writing any property the helper saves a create-new rollback receipt
under the known ProgramData folder's `Perpendicular Guest Channel Access\Receipts`.
Each newly created directory/file is protected, owned by the Administrators
group and permits only Administrators and SYSTEM full access. Existing stores
with different ownership/ACLs or reparse-point ancestors are refused without
alteration. This protects the receipt, not any additional device access. Its
printed UUID identifies the before/after bytes, whether the property was absent,
the one SID and stable instance/parent identities. No private credential or
clipboard data is recorded. It remains available if the subsequent write fails.

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1" -Mode Rollback -ReceiptId 'PRINTED-RECEIPT-UUID'
```

Rollback requires the same owned desktop installation and protected receipt,
recomputes the exact one-SID delta, re-identifies the fixed port and checks that
its configured property still equals the recorded **after** bytes. It then
restores the exact **before** bytes, or deletes only this one per-instance
property if it was originally absent. The ephemeral kernel PDO name may change
after restart; the stable instance/parent and global name must still match.
There is no arbitrary receipt path, supplied SDDL, blind overwrite or automatic
undo of a concurrent policy change. If the original write never happened, the
property already changed, or Windows normalizes the property bytes, this strict
comparison can refuse rollback; inspect and review rather than force it.
Rollback also requires manual restart/revalidation and should precede agent
uninstallation. Receipts are not automatically deleted.

## Verification and remaining limits

`guest-tools/windows/tests/Test-GuestChannelAccess.ps1` compiles the real C# on
portable PowerShell and evaluates only synthetic descriptors, devnodes and
receipts. It covers exact GR/GW and SID, original ACE/control/owner/group/SACL
preservation, inherited ordering, idempotence, deny/malformed/broad-SID rejection,
raw child/parent mismatches, absent/present rollback and altered receipts. It
loads only PS function definitions, never the Windows entry point. No WinAPI,
device handle, task, ACL or privilege is touched by the fixture.
Portable PowerShell 7.6.7 on macOS passed **471 checks**, including the original
355-check native/identity checkpoint and the later harmless payload fixtures.
Descriptor tests include a live-DACL
drift with the registry override still absent and independent property/instance/
parent drift rejection. The new checks isolate class/hardware/instance failures,
verify the actual PowerShell-wrapped native exception's sanitized report,
preserve rejection of all known alternative classes, bound counts and reject
untrusted exception data. New pure acquisition fixtures require a genuine
bounded GUID spelling, clear stale values after invalid acquisition, refuse
observed empty/different class even when the probe/raw flag matches, and verify
the exact capability bit, registry type and four-byte length. Unified fixtures
test exact GUID type/length, absence versus every other error, both complete
class branches, disagreement between APIs, each individual classless condition,
duplicate rejection, raw-capability requirements and every existing identity/
parent/health clause under both branches. No registry API is called by those
fixtures. The diagnostic suite now passed **308 checks**, including
named enum versus numeric enum values, scalar/CIM-like actions, nested arrays,
missing properties, failed getters, private injected SID resolution and parity
with the previous ownership predicate for all unaffected clauses. The earlier
293-check identity-report and 254-check structured-report checkpoints are
preserved. The latter also passed the coordinator's full check. These are synthetic
representation/resolver fixtures, not Windows CIM/account lookup calls.

The coordinator separately ran the previous readonly `E:` disc's
`tests/Test-GuestChannelAccess.ps1` in a fresh **Windows PowerShell 5.1** process
with STA and process-only execution-policy bypass: **75 pure fixture checks
passed**, including compilation of the actual unchanged C#. No device or ACL
API was exercised by that fixture. The separate real **Inspect** entry point
also compiled C# and validated desktop/package identity, then failed at
`The exact limited interactive Guest Agent task was not confirmed`. It did not
reach PDO enumeration/security inspection or any property write. Its earlier
WTS session-identity query is read-only. Subsequent readonly ISO reruns isolated
the UserId clause and then proved the exact OS SID match as documented above.
The later 308-fixture ISO passed the real task gate, then stopped at raw PDO
identity as recorded above; no PDO security result is inferred from that
checkpoint. The subsequent 158-check report isolated empty setup class as above;
the subsequent 208-check explicit legacy/capability Inspect observed error13
and raw capability as above. The fresh unified 355-check Inspect subsequently
passed actual classless identity, live DACL inspection and delta planning.

After the user's action-time approval, actual Apply saved the protected
rollback receipt and reported the per-instance property saved and read back,
with **RuntimeAccessVerified=False**. The private receipt identifier is not
published here. The coordinator then ran the updated agent installer
successfully for the same desktop account; its task remains declared Limited
and Interactive. After the completed Windows restart, the macOS Guest Tools
panel displayed **Guest Tools connected** and **Perpendicular Guest Tools 0.2.0**,
with clipboard/file controls enabled. Unlike task registration or the property
write alone, this is an actual post-restart agent-connection checkpoint.
The helper's earlier `RuntimeAccessVerified=False` output remains the accurate
pre-restart record, not a contradictory post-restart diagnostic.

The enabled controls reflect advertised capabilities, not successful clipboard
or file operations: neither has been exercised in this checkpoint. Automatic
resizing is still being checked. Its latest UI said **Windows will adjust after
you finish resizing the window**; that is pending status, not a measured mode
change or successful resize. No resize result is claimed here.

The coordinator also observed `Confirm-SecureBootUEFI=True` in the graphics
clone after installing the official DOD and testing display modes. That is a
separate guest checkpoint, not evidence that this access proposal worked.

The coordinator rebuilt the readonly disc and updated the guest agent; this
documentation subtask changed neither scripts nor the installed guest. Actual
Windows acceptance now covers exact observed raw-child identity/instance,
live DACL query, protected receipt creation and per-instance property
write/readback and a real agent connection after this Windows restart.
The exact post-restart property/live-DACL bytes were not reread here; persistence
across future device recreation is not established. Actual `display.status`/
resize outcomes, clipboard read/write, file transfer, property deletion and
rollback remain unverified.
Any subsequent failure stops that path; it does not justify an elevated agent,
SYSTEM service, class-wide permissions or changes to Windows signature/TPM/
firmware policy.
