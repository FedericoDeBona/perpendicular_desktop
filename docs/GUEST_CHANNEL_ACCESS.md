# Proposed per-port Guest Tools access correction

Source prepared on 2026-10-15, **not applied or executed in Windows**.
Portable fixtures do not establish that Windows accepts the property, that
the current PDO changes policy, or that a limited user can open the channel.
The installed application, driver, VM, ACLs and privileges have not been
changed by preparing these files. A real application needs the user's final
decision after source review; packaging does not authorize or run it.

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
five named function declarations of the existing diagnostic ownership validator;
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
   that global target. Its class and sole hardware ID must be the published
   raw port `{6fde7547-1b65-48ae-b628-80be62016026}\VIOSerialPort`, and its
   instance ID must belong to that device ID.
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

No step below has been run by the implementation agent. First review source
and fixture results. A coordinator may separately perform an elevated **Inspect**
after the appropriate user decision; unsupported mapping/property/security query
is a stop condition. Use the reviewed mounted read-only Guest Tools disc:

```powershell
# Read-only metadata/descriptor inspection; may request UAC explicitly.
& 'D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1' -Mode Inspect -RequestElevation
```

Apply and rollback also require that helper's package be on a CD-ROM drive,
refusing user-writable staged paths. There is no autorun or installer button;
the normal agent installation never invokes this helper. Only after the user's
final approval of the concrete plan may the coordinator select **Apply**:

```powershell
& 'D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1' -Mode Apply -RequestElevation
```

`-WhatIf` is available for operations using `ShouldProcess`. When the parent
accepts a UAC operation, the fresh noninteractive child receives that explicit
choice rather than asking a second console confirmation. UAC cancellation or
different-account credentials does not report success. No credential is saved.

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
& 'D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1' -Mode Rollback `
  -ReceiptId 'PRINTED-RECEIPT-UUID' -RequestElevation
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
Portable PowerShell 7.6.7 on macOS passed **75 checks**, including a live-DACL
drift with the registry override still absent and independent property/instance/
parent drift rejection. The unchanged diagnostics suite also passed 191 checks.

The package list includes both source files and this test, but no current ISO,
runtime or installed package was regenerated by this subtask. Windows
PowerShell 5.1 native compilation, actual global-alias lookup, exact raw child
instance format, security query support, protected receipt constructors, API
write/delete acceptance, restart persistence and rollback remain unverified.
The first safe live checkpoint is elevated Inspect, not Apply. Any failure
stops the path; it does not justify an elevated agent, SYSTEM service, class-wide
permissions or changes to Windows signature/TPM/firmware policy.
