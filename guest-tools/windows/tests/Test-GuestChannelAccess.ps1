#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windows = Split-Path $PSScriptRoot -Parent
$path = Join-Path $windows 'Set-PerpendicularGuestChannelAccess.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($function.Extent.Text)) }
# PSScriptRoot for production initializers must be the package, never this test.
$initialize = (Get-Command Initialize-ChannelAccess).ScriptBlock.ToString().Replace('$PSScriptRoot', '$windows')
. ([scriptblock]::Create('function Initialize-ChannelAccess {' + $initialize + '}'))
Initialize-ChannelAccess
Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class ChannelFixture {
    public static byte[] Sid(uint authority, params uint[] sub) { byte[] b = new byte[8 + 4 * sub.Length]; b[0] = 1; b[1] = (byte)sub.Length; b[7] = (byte)authority; for (int i = 0; i < sub.Length; i++) Buffer.BlockCopy(BitConverter.GetBytes(sub[i]), 0, b, 8 + i * 4, 4); return b; }
    public static byte[] Ace(byte type, byte flags, uint mask, byte[] sid) { byte[] b = new byte[8 + sid.Length]; b[0] = type; b[1] = flags; Buffer.BlockCopy(BitConverter.GetBytes((ushort)b.Length), 0, b, 2, 2); Buffer.BlockCopy(BitConverter.GetBytes(mask), 0, b, 4, 4); Buffer.BlockCopy(sid, 0, b, 8, sid.Length); return b; }
    public static byte[] Acl(params byte[][] entries) { int n = 8; foreach (byte[] e in entries) n += e.Length; byte[] b = new byte[n]; b[0] = 2; Buffer.BlockCopy(BitConverter.GetBytes((ushort)n), 0, b, 2, 2); Buffer.BlockCopy(BitConverter.GetBytes((ushort)entries.Length), 0, b, 4, 2); int p = 8; foreach (byte[] e in entries) { Buffer.BlockCopy(e, 0, b, p, e.Length); p += e.Length; } return b; }
    public static byte[] Sd(byte[] dacl, byte[] owner, byte[] group, byte[] sacl) { byte[][] parts = new byte[][] {owner, group, sacl, dacl}; int n = 20; foreach (byte[] e in parts) if (e != null) n += e.Length; byte[] b = new byte[n]; b[0] = 1; ushort control = (ushort)(0x9004 | (sacl == null ? 0 : 0x10)); Buffer.BlockCopy(BitConverter.GetBytes(control), 0, b, 2, 2); int p = 20; for (int i = 0; i < 4; i++) if (parts[i] != null) { Buffer.BlockCopy(BitConverter.GetBytes(p), 0, b, 4 + 4 * i, 4); Buffer.BlockCopy(parts[i], 0, b, p, parts[i].Length); p += parts[i].Length; } return b; }
    public static byte[] Section(byte[] sd, int index) { int p = BitConverter.ToInt32(sd, 4 + 4 * index); if (p == 0) return null; int n = index < 2 ? 8 + sd[p + 1] * 4 : BitConverter.ToUInt16(sd, p + 2); byte[] b = new byte[n]; Buffer.BlockCopy(sd, p, b, 0, n); return b; }
}
'@
$script:checks = 0
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
function Assert-Rejected { param([scriptblock]$Action, [string]$Message) $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $true }; Assert-True $rejected $Message }
$sid = 'S-1-5-21-123-456-789-1001'
$system = [ChannelFixture]::Sid(5, [uint32[]]@(18)); $admins = [ChannelFixture]::Sid(5, [uint32[]]@(32, 544))
$user = [Perpendicular.ChannelAccess.Descriptor]::UserSid($sid)
$systemAce = [ChannelFixture]::Ace(0, 0, [uint32]268435456, $system)
$adminAce = [ChannelFixture]::Ace(0, 0, [uint32]268435456, $admins)
$acl = [ChannelFixture]::Acl([byte[][]]@($systemAce, $adminAce))
$original = [ChannelFixture]::Sd($acl, $null, $null, $null)
$originalCopy = [byte[]]$original.Clone()
$next = [Perpendicular.ChannelAccess.Descriptor]::AddReadWrite($original, $sid)
Assert-True ([Perpendicular.ChannelAccess.Descriptor]::Equal($original, $originalCopy)) 'The original descriptor was mutated.'
Assert-True ($next.Length -eq $original.Length + 36) 'Only the one desktop SID ACE should be added.'
$nextAcl = [Perpendicular.ChannelAccess.Descriptor]::Dacl($next)
Assert-True ([BitConverter]::ToUInt16($nextAcl, 4) -eq 3) 'Existing ACL entries must be retained.'
Assert-True ([Perpendicular.ChannelAccess.Descriptor]::Equal($acl[8..($acl.Length - 1)], $nextAcl[8..($acl.Length - 1)])) 'Original ACE bytes/order changed.'
Assert-True ([BitConverter]::ToUInt32($nextAcl, $acl.Length + 4) -eq [uint32]3221225472) 'The new ACE must grant exactly GR/GW, with no GA/execute/ownership/DACL rights.'
Assert-True ($nextAcl[$acl.Length] -eq 0 -and $nextAcl[$acl.Length + 1] -eq 0) 'The new allow ACE must be explicit and uninherited.'
Assert-True ([Perpendicular.ChannelAccess.Descriptor]::Equal($user, $nextAcl[($acl.Length + 8)..($nextAcl.Length - 1)])) 'The exact desktop SID must be the only new trustee.'
Assert-True ([Perpendicular.ChannelAccess.Descriptor]::Equal($next, [Perpendicular.ChannelAccess.Descriptor]::AddReadWrite($next, $sid))) 'The one-SID permission addition must be idempotent.'
$audit = [ChannelFixture]::Acl([byte[][]]@([ChannelFixture]::Ace(2, 64, 1, $system)))
$rich = [ChannelFixture]::Sd($acl, $system, $admins, $audit)
$richNext = [Perpendicular.ChannelAccess.Descriptor]::AddReadWrite($rich, $sid)
foreach ($index in @(0, 1, 2)) { Assert-True ([Perpendicular.ChannelAccess.Descriptor]::Equal([ChannelFixture]::Section($rich, $index), [ChannelFixture]::Section($richNext, $index))) 'Owner/group/SACL section bytes changed.' }
Assert-True ($rich[2] -eq $richNext[2] -and $rich[3] -eq $richNext[3]) 'Descriptor control/inheritance flags changed.'
$inherited = [ChannelFixture]::Ace(0, 16, 1, $system)
$inheritSd = [ChannelFixture]::Sd([ChannelFixture]::Acl([byte[][]]@($systemAce, $inherited)), $null, $null, $null)
$inheritAcl = [Perpendicular.ChannelAccess.Descriptor]::Dacl([Perpendicular.ChannelAccess.Descriptor]::AddReadWrite($inheritSd, $sid))
Assert-True ($inheritAcl[8 + $systemAce.Length] -eq 0 -and $inheritAcl[8 + $systemAce.Length + 1] -eq 0 -and $inheritAcl[8 + $systemAce.Length + 36 + 1] -eq 16) 'New explicit ACE must precede inherited entries without reordering them.'
foreach ($bad in @('S-1-1-0', 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-21-1-2-3-4294967296', 'S-1-5-21-01-2-3-1001', ($sid + '(A;;GA;;;WD)'), '', "S-1-5-21-1-2-3-1001`n")) { Assert-Rejected { [Perpendicular.ChannelAccess.Descriptor]::AddReadWrite($original, $bad) } 'An invalid or broad trustee was accepted.' }
foreach ($case in @('truncated', 'absolute', 'null-dacl', 'empty-dacl', 'deny', 'unknown-ace', 'overlap', 'bad-ace-size', 'noncanonical', 'too-large')) {
    $bad = [byte[]]$original.Clone()
    switch ($case) {
        'truncated' { $bad = [byte[]]@(1, 2, 3) }
        'absolute' { $bad[3] = 16 }
        'null-dacl' { [Array]::Clear($bad, 16, 4) }
        'empty-dacl' { $bad = [ChannelFixture]::Sd([ChannelFixture]::Acl([byte[][]]@()), $null, $null, $null) }
        'deny' { $bad[28] = 1 }
        'unknown-ace' { $bad[28] = 5 }
        'overlap' { [Array]::Copy([BitConverter]::GetBytes([uint32]20), 0, $bad, 4, 4) }
        'bad-ace-size' { $bad[30] = 255 }
        'noncanonical' { $bad = [ChannelFixture]::Sd([ChannelFixture]::Acl([byte[][]]@($inherited, $systemAce)), $null, $null, $null) }
        'too-large' { $bad = New-Object byte[] 65537 }
    }
    Assert-Rejected { [Perpendicular.ChannelAccess.Descriptor]::AddReadWrite($bad, $sid) } ('Invalid DACL accepted: ' + $case)
}
function New-PortFixture {
    $port = New-Object Perpendicular.ChannelAccess.Port
    $port.InstanceId = [Perpendicular.ChannelAccess.Device]::Hardware + '\4&FIXTURE&0&00'
    $port.PdoName = '\Device\0000007a'; $port.ClassGuid = [guid]'6fde7547-1b65-48ae-b628-80be62016026'
    $port.HardwareIds = @([Perpendicular.ChannelAccess.Device]::Hardware)
    $port.ParentId = 'PCI\VEN_1AF4&DEV_1043&SUBSYS_11001AF4\4&FIXTURE&0&00'
    $port.ParentHardwareIds = @('PCI\VEN_1AF4&DEV_1043&SUBSYS_11001AF4')
    $port.ParentService = 'VirtioSerial'; $port.Status = 8; $port.ParentStatus = 8
    $port.LiveDaclDescriptor = $original
    return $port
}
$port = New-PortFixture
[Perpendicular.ChannelAccess.Device]::ValidatePort($port, $port.PdoName)
$plan = Get-ChannelPlan -Port $port -Sid $sid
Assert-True ($plan.Changed -and $null -eq $plan.Before) 'An absent override must be recorded as absent rather than invented.'
foreach ($case in @('class', 'hardware', 'duplicate-hardware', 'instance', 'instance-suffix', 'alias', 'service', 'pci', 'parent-hardware', 'mismatched-parent', 'problem', 'parent-problem', 'problem-flag', 'not-started', 'unreadable-dacl', 'pending-policy')) {
    $port = New-PortFixture
    switch ($case) {
        'class' { $port.ClassGuid = [guid]::Empty }
        'hardware' { $port.HardwareIds = @('OTHER') }
        'duplicate-hardware' { $port.HardwareIds = @($port.HardwareIds[0], $port.HardwareIds[0]) }
        'instance' { $port.InstanceId = 'OTHER' }
        'instance-suffix' { $port.InstanceId += "`n" }
        'alias' { $port.PdoName = '\Device\bad\path' }
        'service' { $port.ParentService = 'vioser' }
        'pci' { $port.ParentId = 'PCI\VEN_1234&DEV_1043\OTHER' }
        'parent-hardware' { $port.ParentHardwareIds = @('PCI\VEN_1234&DEV_1043') }
        'mismatched-parent' { $port.ParentHardwareIds = @('PCI\VEN_1AF4&DEV_1003') }
        'problem' { $port.Problem = 22 }
        'parent-problem' { $port.ParentProblem = 22 }
        'problem-flag' { $port.ParentStatus = 1032 }
        'not-started' { $port.ParentStatus = 0 }
        'unreadable-dacl' { $port.LiveDaclDescriptor = $null }
        'pending-policy' { $port.Property = $next }
    }
    Assert-Rejected { Get-ChannelPlan -Port $port -Sid $sid } ('Invalid PDO/parent/descriptor accepted: ' + $case)
}
$port = New-PortFixture
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($port, '\Device\0000009b') } 'A different DOS alias target must be refused.'
Assert-True ($null -ne [Perpendicular.ChannelAccess.Device]::AcceptMatch($null, $port, $port.PdoName)) 'One matching raw port must be accepted.'
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::AcceptMatch($port, (New-PortFixture), $port.PdoName) } 'Duplicate raw PDO matches must be refused.'
$liveDacl = [Perpendicular.ChannelAccess.Descriptor]::Dacl($original)
[Perpendicular.ChannelAccess.Device]::ValidateConditional($port, $port.InstanceId, $port.ParentId, $null, $liveDacl, $original)
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidateConditional($port, $port.InstanceId, $port.ParentId, $null, $liveDacl, $next) } 'A changed live DACL with an override still absent must block Apply.'
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidateConditional($port, $port.InstanceId, $port.ParentId, $null, $liveDacl, $null) } 'A failed live reread must block Apply.'
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidateConditional($port, 'OTHER', $port.ParentId, $null, $liveDacl, $original) } 'A different PDO instance must block Apply.'
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidateConditional($port, $port.InstanceId, 'OTHER', $null, $liveDacl, $original) } 'A different parent must block Apply.'
$port.Property = $next
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidateConditional($port, $port.InstanceId, $port.ParentId, $null, $liveDacl, $original) } 'A property added after inspection must block Apply.'
[Perpendicular.ChannelAccess.Device]::ValidateConditional($port, $port.InstanceId, $port.ParentId, $next, $null, $null)
$receiptId = '88195785-0ac9-466a-9f12-b8079cdd97d3'
$receipt = ConvertTo-ChannelReceipt -Plan $plan -Id $receiptId
$rollback = Get-ChannelRollback -Receipt $receipt -Sid $sid
Assert-True ($null -eq $rollback.Before -and [Perpendicular.ChannelAccess.Descriptor]::Equal($rollback.After, $next)) 'Absent-before rollback must delete only this exact override.'
$existingPort = New-PortFixture; $existingPort.Property = $rich; $existingPort.LiveDaclDescriptor = $rich
$existingPlan = Get-ChannelPlan -Port $existingPort -Sid $sid
$existingReceipt = ConvertTo-ChannelReceipt -Plan $existingPlan -Id $receiptId
$existingRollback = Get-ChannelRollback -Receipt $existingReceipt -Sid $sid
Assert-True ([Perpendicular.ChannelAccess.Descriptor]::Equal($existingRollback.Before, $rich)) 'Existing override rollback must retain its exact original bytes.'
foreach ($case in @('other-sid', 'other-alias', 'changed-after', 'changed-source', 'false-presence', 'extra-field', 'runtime-claim', 'missing-field')) {
    $bad = $receipt | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    switch ($case) {
        'other-sid' { $bad.owner_sid = 'S-1-5-21-1-2-3-1002' }
        'other-alias' { $bad.alias = 'other.port' }
        'changed-after' { $bad.after = [Convert]::ToBase64String($original) }
        'changed-source' { $bad.source_descriptor = [Convert]::ToBase64String($next) }
        'false-presence' { $bad.before = [Convert]::ToBase64String($original) }
        'extra-field' { $bad | Add-Member -NotePropertyName other -NotePropertyValue 1 }
        'runtime-claim' { $bad.runtime_access_verified = $true }
        'missing-field' { $bad.PSObject.Properties.Remove('before') }
    }
    Assert-Rejected { Get-ChannelRollback -Receipt $bad -Sid $sid } ('Altered rollback receipt accepted: ' + $case)
}
$expected = Get-DiagnosticExpectedTask -Sid $sid -Account 'FIXTURE' -Directory 'C:\Users\FIXTURE\AppData\Local\Perpendicular Desktop\Guest Agent' -WindowsDirectory 'C:\Windows'
Assert-True ($expected.Arguments.Contains('PerpendicularAgent.ps1') -and $expected.Execute.EndsWith('powershell.exe')) 'Only the reviewed diagnostic ownership functions should be imported; their bodies must execute.'
$native = [IO.File]::ReadAllText((Join-Path $windows 'PerpendicularChannelAccess.Native.cs'))
foreach ($forbidden in @('SetupDiSetClass', 'CM_Disable', 'CM_Enable', 'AdjustTokenPrivileges', 'SetKernelObjectSecurity', 'DeviceIoControl', 'GENERIC_ALL')) { Assert-True (-not $native.Contains($forbidden)) ('A broader mutation API appeared: ' + $forbidden) }
Assert-True ($native.Contains('CreateFileW(OpenName, 0x20000, 0') -and $native.Contains('Security = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 25)')) 'Only READ_CONTROL and the per-instance security property are allowed.'
Write-Output ('PASS: ' + $script:checks + ' channel-access checks. Real C# compiled; only synthetic descriptors/devnodes/receipts were evaluated. No WinAPI, device, task, ACL, privilege, guest channel or VM was accessed or changed.')
