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
    $port.PdoName = '\Device\0000007a'
    [Perpendicular.ChannelAccess.Device]::ObserveClassGuid($port, '{6fde7547-1b65-48ae-b628-80be62016026}')
    [Perpendicular.ChannelAccess.Device]::ObserveUnifiedClassGuid($port, $true, 0, 13, ([guid]'6fde7547-1b65-48ae-b628-80be62016026').ToByteArray(), 16)
    [Perpendicular.ChannelAccess.Device]::ObserveCapabilities($port, 4, [BitConverter]::GetBytes([uint32]64), 4)
    $port.HardwareIds = @([Perpendicular.ChannelAccess.Device]::Hardware)
    $port.ParentId = 'PCI\VEN_1AF4&DEV_1043&SUBSYS_11001AF4\4&FIXTURE&0&00'
    $port.ParentHardwareIds = @('PCI\VEN_1AF4&DEV_1043&SUBSYS_11001AF4')
    $port.ParentService = 'VirtioSerial'; $port.Status = 8; $port.ParentStatus = 8
    $port.LiveDaclDescriptor = $original
    return $port
}
function New-ClasslessPortFixture {
    $port = New-PortFixture
    $port.ClassGuid = [guid]::Empty; $port.ClassGuidState = [Perpendicular.ChannelAccess.ClassGuidReadState]::Unavailable; $port.ClassGuidPropertyError = 13
    $port.InterfaceDetailClassGuid = [guid]::Empty
    [Perpendicular.ChannelAccess.Device]::ObserveUnifiedClassGuid($port, $false, 1168, 0, $null, 0)
    return $port
}
$port = New-PortFixture
[Perpendicular.ChannelAccess.Device]::ValidatePort($port, $port.PdoName)
$identity = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($port, $port.PdoName)
Assert-True ($identity.Valid -and $identity.FailureCode -ceq 'none' -and $identity.ClassGuidKind -ceq 'expected_raw_port' -and $identity.HardwareIdKind -ceq 'expected_single') 'An exact valid port must have a passing sanitized report.'
foreach ($field in @('CandidatePresent', 'ClassGuidMatches', 'HardwareIdsPresent', 'HardwareIdSingle', 'HardwareIdExact', 'InstancePrefixMatches', 'InstanceSuffixValid', 'AliasMatches', 'PdoNameSyntax', 'ParentServiceMatches', 'ParentPciIdentityValid', 'ParentHardwareIdsPresent', 'ParentHardwareMatchesInstance', 'ChildProblemZero', 'ParentProblemZero', 'ParentStarted', 'ChildNoProblemFlag', 'ParentNoProblemFlag')) {
    Assert-True $identity.$field ('A valid fixture failed the separate identity clause: ' + $field)
}
Assert-True ($identity.HardwareIdCount -eq 1 -and $identity.ParentHardwareIdCount -eq 1) 'Observed identity list counts must be exact inside the accepted bound.'
Assert-True ($identity.ClassGuidSource -ceq 'spdrp_classguid' -and $identity.ClassGuidReadCode -ceq 'observed' -and $identity.InterfaceDetailClassGuidKind -ceq 'empty') 'An explicitly observed setup class must be distinct from an empty interface-detail field.'
Assert-True ($identity.UnifiedClassGuidSource -ceq 'devpkey_device_classguid' -and $identity.UnifiedClassGuidReadCode -ceq 'observed' -and $identity.ExpectedSetupClassConfirmed -and $identity.SetupClassAccepted -and -not $identity.ClasslessConfirmed -and $identity.SetupClassIdentityCode -ceq 'expected_class') 'The expected-class branch must require matching independently observed setup-class GUIDs.'
Assert-True ($identity.CapabilitiesObserved -and $identity.RawDeviceOk -and $identity.CapabilitiesSource -ceq 'spdrp_capabilities' -and $identity.CapabilitiesReadCode -ceq 'observed') 'Raw capability must come only from an actually observed capabilities DWORD.'
$report = ConvertTo-ChannelPortIdentityReport $identity
Assert-True ($report.StartsWith('GuestChannelPortIdentityChecks=') -and $report -notmatch 'FIXTURE|Device\\|PCI\\|S-1-5|6fde7547') 'The public report must not contain raw identifiers, paths, SIDs or DACLs.'
$parsedReport = $report.Substring('GuestChannelPortIdentityChecks='.Length) | ConvertFrom-Json
Assert-True ($parsedReport.Valid -and $parsedReport.ClassGuidMatches -and $parsedReport.HardwareIdExact -and $parsedReport.InstancePrefixMatches) 'The fixed-schema report must survive PS JSON conversion.'
$absent = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($null, $null)
Assert-True (-not $absent.Valid -and -not $absent.CandidatePresent -and $absent.HardwareIdCount -eq -1 -and $absent.ParentHardwareIdCount -eq -1) 'Missing candidates must report unavailable rather than throw or pass.'
$observed = New-PortFixture
$observed.InterfaceDetailClassGuid = [guid]::Empty
[Perpendicular.ChannelAccess.Device]::ValidatePort($observed, $observed.PdoName)
Assert-True ([Perpendicular.ChannelAccess.Device]::GetIdentityChecks($observed, $observed.PdoName).Valid) 'The causal empty-detail case must pass only when the explicit class property actually contains the expected GUID.'
$observed.InterfaceDetailClassGuid = [guid]'6fde7547-1b65-48ae-b628-80be62016026'
[Perpendicular.ChannelAccess.Device]::ObserveClassGuid($observed, '{4d36e97d-e325-11ce-bfc1-08002be10318}')
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($observed, $observed.PdoName) } 'A matching probe GUID must never override a different observed setup class.'
foreach ($classText in @('6fde7547-1b65-48ae-b628-80be62016026', '{6FDE7547-1B65-48AE-B628-80BE62016026}')) {
    [Perpendicular.ChannelAccess.Device]::ObserveClassGuid($observed, $classText)
    Assert-True ($observed.ClassGuid -eq [guid]'6fde7547-1b65-48ae-b628-80be62016026' -and $observed.ClassGuidState -eq [Perpendicular.ChannelAccess.ClassGuidReadState]::Observed) 'Only ordinary GUID registry spellings may be parsed without inventing a value.'
}
foreach ($classText in @($null, '', 'OTHER', ' 6fde7547-1b65-48ae-b628-80be62016026', '{6fde7547-1b65-48ae-b628-80be62016026} ', "{6fde7547-1b65-48ae-b628-80be62016026}`n", '6fde75471b6548aeb62880be62016026')) {
    $observed = New-PortFixture
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ObserveClassGuid($observed, $classText) } 'Missing, ambiguous or malformed class property text must fail closed.'
    Assert-True ($observed.ClassGuid -eq [guid]::Empty -and $observed.ClassGuidState -eq [Perpendicular.ChannelAccess.ClassGuidReadState]::Invalid) 'A failed class observation must not retain an earlier matching GUID.'
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($observed, $observed.PdoName) } 'Invalid acquisition must not fall back to the driver constant or interface-detail GUID.'
}
$observed = New-PortFixture
[Perpendicular.ChannelAccess.Device]::ObserveClassGuid($observed, '{00000000-0000-0000-0000-000000000000}')
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($observed, $observed.PdoName) } 'An actually observed empty class GUID must remain refused.'
$unavailable = New-PortFixture; $unavailable.ClassGuid = [guid]::Empty; $unavailable.ClassGuidState = [Perpendicular.ChannelAccess.ClassGuidReadState]::Unavailable; $unavailable.ClassGuidPropertyError = 13
$unavailableChecks = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($unavailable, $unavailable.PdoName)
Assert-True (-not $unavailableChecks.Valid -and $unavailableChecks.ClassGuidSource -ceq 'unavailable' -and $unavailableChecks.ClassGuidReadCode -ceq 'api_unavailable' -and $unavailableChecks.ClassGuidPropertyError -eq 13) 'A missing/invalid registry property must report its real error without inferring a class.'
foreach ($bits in @([uint32]0, [uint32]1, [uint32]63, [uint32]64, [uint32]127, [uint32]4294967295)) {
    $observed = New-PortFixture
    [Perpendicular.ChannelAccess.Device]::ObserveCapabilities($observed, 4, [BitConverter]::GetBytes($bits), 4)
    $capabilityChecks = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($observed, $observed.PdoName)
    Assert-True ($capabilityChecks.RawDeviceOk -eq (($bits -band 64) -ne 0) -and $capabilityChecks.CapabilitiesObserved) 'Only the CM_DEVCAP_RAWDEVICEOK bit may establish the reported raw capability.'
}
foreach ($mode in @('wrong-type', 'null', 'short', 'long', 'wrong-required')) {
    $observed = New-PortFixture; $type = [uint32]4; $bytes = [BitConverter]::GetBytes([uint32]64); $required = [uint32]4
    switch ($mode) { 'wrong-type' { $type = 1 } 'null' { $bytes = $null } 'short' { $bytes = [byte[]]@(64, 0) } 'long' { $bytes = New-Object byte[] 8 } 'wrong-required' { $required = 8 } }
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ObserveCapabilities($observed, $type, $bytes, $required) } 'Malformed or incorrectly typed capability bytes must be refused.'
    $capabilityChecks = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($observed, $observed.PdoName)
    Assert-True (-not $capabilityChecks.RawDeviceOk -and -not $capabilityChecks.CapabilitiesObserved -and $capabilityChecks.CapabilitiesReadCode -ceq 'invalid_property') 'Invalid acquisition must clear an earlier observed raw capability rather than retain it.'
}
$unavailable.CapabilitiesState = [Perpendicular.ChannelAccess.CapabilitiesReadState]::Unavailable; $unavailable.CapabilitiesPropertyError = 13
$capabilityChecks = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($unavailable, $unavailable.PdoName)
Assert-True (-not $capabilityChecks.RawDeviceOk -and $capabilityChecks.CapabilitiesReadCode -ceq 'api_unavailable' -and $capabilityChecks.CapabilitiesPropertyError -eq 13) 'Unavailable raw capability must remain unknown/false with the actual bounded API result.'
$emptyRaw = New-PortFixture
[Perpendicular.ChannelAccess.Device]::ObserveClassGuid($emptyRaw, '{00000000-0000-0000-0000-000000000000}')
Assert-True ([Perpendicular.ChannelAccess.Device]::GetIdentityChecks($emptyRaw, $emptyRaw.PdoName).RawDeviceOk) 'The next evidence report must preserve raw capability independently of empty setup class.'
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($emptyRaw, $emptyRaw.PdoName) } 'A raw capability alone must not accept an observed empty setup class without the exact absent-property evidence.'
$classless = New-ClasslessPortFixture
$classlessChecks = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($classless, $classless.PdoName)
Assert-True ($classless.ClassGuid -eq [guid]::Empty -and -not $classlessChecks.ClassGuidMatches) 'The new branch must preserve the actual classlessness that failed the old GUID-equality predicate.'
Assert-True ($classlessChecks.ClasslessConfirmed -and -not $classlessChecks.ExpectedSetupClassConfirmed -and $classlessChecks.SetupClassAccepted -and $classlessChecks.SetupClassIdentityCode -ceq 'classless_confirmed' -and $classlessChecks.RawDeviceOk -and $classlessChecks.Valid) 'Only exact unified absence, legacy13, empty probe and observed raw capability may establish the classless branch.'
Assert-True ($classlessChecks.UnifiedClassGuidReadCode -ceq 'not_found' -and $classlessChecks.UnifiedClassGuidPropertyError -eq 1168 -and $classlessChecks.ClassGuidPropertyError -eq 13) 'The report must distinguish unified absence from legacy absent-or-invalid metadata.'
[Perpendicular.ChannelAccess.Device]::ValidatePort($classless, $classless.PdoName)
Assert-True ($null -ne [Perpendicular.ChannelAccess.Device]::AcceptMatch($null, $classless, $classless.PdoName)) 'A uniquely mapped classless raw child with every identity clause satisfied must pass the reviewed correction.'
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::AcceptMatch($classless, (New-ClasslessPortFixture), $classless.PdoName) } 'Classlessness must not weaken duplicate-interface rejection.'
$classlessReport = ConvertTo-ChannelPortIdentityReport $classlessChecks
Assert-True ($classlessReport -notmatch 'FIXTURE|Device\\|PCI\\|S-1-5|6fde7547' -and ($classlessReport.Substring('GuestChannelPortIdentityChecks='.Length) | ConvertFrom-Json).ClasslessConfirmed) 'The corrected branch must retain the same fixed-schema report privacy.'
foreach ($errorCode in @(0, 5, 13, 87, 122, 1167, 1169)) {
    $bad = New-ClasslessPortFixture
    [Perpendicular.ChannelAccess.Device]::ObserveUnifiedClassGuid($bad, $false, $errorCode, 0, $null, 0)
    Assert-True ($bad.UnifiedClassGuidState -eq [Perpendicular.ChannelAccess.ClassGuidReadState]::Unavailable) 'Only exact ERROR_NOT_FOUND1168 may mean unified property absence.'
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'Arbitrary unified errors must never become the classless branch.'
}
foreach ($errorCode in @(0, 5, 87, 122, 1168, 1169)) {
    $bad = New-ClasslessPortFixture; $bad.ClassGuidPropertyError = $errorCode
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'Classlessness still requires the exact legacy13 checkpoint, not another error.'
}
foreach ($state in @('NotRead', 'Observed', 'Invalid', 'Absent')) {
    $bad = New-ClasslessPortFixture; $bad.ClassGuidState = [Perpendicular.ChannelAccess.ClassGuidReadState]::$state
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'A forged legacy error number without the matching unavailable state must be refused.'
}
foreach ($state in @('NotRead', 'Observed', 'Invalid', 'Unavailable')) {
    $bad = New-ClasslessPortFixture; $bad.UnifiedClassGuidState = [Perpendicular.ChannelAccess.ClassGuidReadState]::$state
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'A forged unified1168 number without the matching absence state must be refused.'
}
foreach ($field in @('ClassGuid', 'UnifiedClassGuid', 'InterfaceDetailClassGuid')) {
    foreach ($guidText in @('6fde7547-1b65-48ae-b628-80be62016026', '4d36e97d-e325-11ce-bfc1-08002be10318')) {
        $bad = New-ClasslessPortFixture; $bad.$field = [guid]$guidText
        Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'Any nonempty class observation conflicts with the exact classless branch, including an expected-looking GUID.'
    }
}
foreach ($classText in @('00000000-0000-0000-0000-000000000000', '4d36e97d-e325-11ce-bfc1-08002be10318', '6fde7521-1b65-48ae-b628-80be62016026')) {
    $bad = New-ClasslessPortFixture
    [Perpendicular.ChannelAccess.Device]::ObserveUnifiedClassGuid($bad, $true, 0, 13, ([guid]$classText).ToByteArray(), 16)
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'Successful observed empty or other setup classes are not absent properties.'
}
foreach ($mode in @('wrong-type', 'null', 'short', 'long', 'wrong-required', 'success-with-error')) {
    $bad = New-ClasslessPortFixture; $type = [uint32]13; $bytes = ([guid]'6fde7547-1b65-48ae-b628-80be62016026').ToByteArray(); $required = [uint32]16; $errorCode = 0
    switch ($mode) { 'wrong-type' { $type = 18 } 'null' { $bytes = $null } 'short' { $bytes = New-Object byte[] 15 } 'long' { $bytes = New-Object byte[] 17 } 'wrong-required' { $required = 32 } 'success-with-error' { $errorCode = 13 } }
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ObserveUnifiedClassGuid($bad, $true, $errorCode, $type, $bytes, $required) } 'Unified GUID acquisition must require success, type GUID, exact16 bytes and no stale error.'
    Assert-True ($bad.UnifiedClassGuid -eq [guid]::Empty -and $bad.UnifiedClassGuidState -eq [Perpendicular.ChannelAccess.ClassGuidReadState]::Invalid -and $bad.UnifiedClassGuidPropertyError -eq 0) 'Malformed unified data must clear prior observations and absence state.'
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'Malformed unified data must never fall back to legacy metadata or capability.'
}
foreach ($fixture in @('expected', 'classless')) {
    foreach ($mode in @('raw-bit-missing', 'caps-not-read', 'caps-unavailable', 'caps-invalid', 'caps-stale-error', 'hardware', 'duplicate-hardware', 'instance', 'suffix', 'alias', 'service', 'pci', 'parent-hardware', 'mismatched-parent', 'child-problem', 'parent-problem', 'child-flag', 'parent-flag', 'parent-not-started')) {
        $bad = if ($fixture -eq 'classless') { New-ClasslessPortFixture } else { New-PortFixture }
        switch ($mode) {
            'raw-bit-missing' { [Perpendicular.ChannelAccess.Device]::ObserveCapabilities($bad, 4, [BitConverter]::GetBytes([uint32]63), 4) }
            'caps-not-read' { $bad.CapabilitiesState = [Perpendicular.ChannelAccess.CapabilitiesReadState]::NotRead }
            'caps-unavailable' { $bad.CapabilitiesState = [Perpendicular.ChannelAccess.CapabilitiesReadState]::Unavailable }
            'caps-invalid' { $bad.CapabilitiesState = [Perpendicular.ChannelAccess.CapabilitiesReadState]::Invalid }
            'caps-stale-error' { $bad.CapabilitiesPropertyError = 5 }
            'hardware' { $bad.HardwareIds = @('OTHER') }
            'duplicate-hardware' { $bad.HardwareIds = @($bad.HardwareIds[0], $bad.HardwareIds[0]) }
            'instance' { $bad.InstanceId = 'OTHER' }
            'suffix' { $bad.InstanceId += "`n" }
            'alias' { $bad.PdoName = '\Device\bad\path' }
            'service' { $bad.ParentService = 'OTHER' }
            'pci' { $bad.ParentId = 'PCI\VEN_1234&DEV_1043\OTHER' }
            'parent-hardware' { $bad.ParentHardwareIds = @('PCI\VEN_1234&DEV_1043') }
            'mismatched-parent' { $bad.ParentHardwareIds = @('PCI\VEN_1AF4&DEV_1003') }
            'child-problem' { $bad.Problem = 22 }
            'parent-problem' { $bad.ParentProblem = 22 }
            'child-flag' { $bad.Status = 1032 }
            'parent-flag' { $bad.ParentStatus = 1032 }
            'parent-not-started' { $bad.ParentStatus = 0 }
        }
        Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } ('Every identity/capability/health gate must remain mandatory for both class branches: ' + $fixture + '/' + $mode)
        Assert-True (-not [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($bad, $bad.PdoName).Valid) 'The complete sanitized report must agree with a rejected validator.'
    }
}
$bad = New-PortFixture; $bad.UnifiedClassGuidState = [Perpendicular.ChannelAccess.ClassGuidReadState]::NotRead
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'A matching legacy GUID alone must not bypass the independent unified observation.'
foreach ($mode in @('unified-other', 'unified-empty', 'unified-absent', 'legacy-error', 'unified-error')) {
    $bad = New-PortFixture
    switch ($mode) {
        'unified-other' { [Perpendicular.ChannelAccess.Device]::ObserveUnifiedClassGuid($bad, $true, 0, 13, ([guid]'4d36e97d-e325-11ce-bfc1-08002be10318').ToByteArray(), 16) }
        'unified-empty' { [Perpendicular.ChannelAccess.Device]::ObserveUnifiedClassGuid($bad, $true, 0, 13, ([guid]::Empty).ToByteArray(), 16) }
        'unified-absent' { [Perpendicular.ChannelAccess.Device]::ObserveUnifiedClassGuid($bad, $false, 1168, 0, $null, 0) }
        'legacy-error' { $bad.ClassGuidPropertyError = 5 }
        'unified-error' { $bad.UnifiedClassGuidPropertyError = 5 }
    }
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'The explicit-class branch must reject cross-API disagreement or a nonzero observation error.'
}
$bad = New-PortFixture; $bad.InterfaceDetailClassGuid = [guid]'4d36e97d-e325-11ce-bfc1-08002be10318'
Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName) } 'A conflicting nonempty probe class must fail even when both property APIs report the expected GUID.'
$bad = New-PortFixture; $bad.InterfaceDetailClassGuid = [guid]'6fde7547-1b65-48ae-b628-80be62016026'
[Perpendicular.ChannelAccess.Device]::ValidatePort($bad, $bad.PdoName)
Assert-True ([Perpendicular.ChannelAccess.Device]::GetIdentityChecks($bad, $bad.PdoName).ExpectedSetupClassConfirmed) 'A fully agreeing explicit expected setup class must remain supported.'
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
    $identity = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($port, $port.PdoName)
    if ($case -in @('unreadable-dacl', 'pending-policy')) {
        Assert-True $identity.Valid 'Descriptor state must not change identity-only reporting or bypass the later DACL gate.'
    } else {
        Assert-True (-not $identity.Valid -and $identity.FailureCode -cne 'none') ('A rejected identity was reported as valid: ' + $case)
        $caught = $null
        try { [Perpendicular.ChannelAccess.Device]::AcceptMatch($null, $port, $port.PdoName) | Out-Null } catch { $caught = $_.Exception }
        Assert-True ($null -ne $caught) 'The report must never replace rejection with acceptance.'
        $failureReport = Get-ChannelPortIdentityFailureReport $caught
        Assert-True ($null -ne $failureReport -and $failureReport -ceq (ConvertTo-ChannelPortIdentityReport $identity)) 'The actual wrapped PowerShell exception must retain exactly the safe report.'
    }
}
$port = New-PortFixture; $port.ClassGuid = [guid]::Empty
$identity = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($port, $port.PdoName)
Assert-True (-not $identity.ClassGuidMatches -and $identity.HardwareIdExact -and $identity.InstanceIdentity -and $identity.ClassGuidKind -ceq 'empty' -and $identity.FailureCode -ceq 'raw_port_identity') 'Class mismatch must be isolated from matching hardware and instance clauses.'
foreach ($class in @('6fde7521-1b65-48ae-b628-80be62016026', '4d36e97d-e325-11ce-bfc1-08002be10318', '4d36e978-e325-11ce-bfc1-08002be10318', '11111111-1111-1111-1111-111111111111')) {
    $port.ClassGuid = [guid]$class
    $identity = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($port, $port.PdoName)
    Assert-True (-not $identity.Valid -and -not $identity.ClassGuidMatches -and $identity.ClassGuidKind -in @('port_interface', 'system', 'ports', 'other')) 'Recognizing a class label must not accept that class.'
    Assert-Rejected { [Perpendicular.ChannelAccess.Device]::ValidatePort($port, $port.PdoName) } 'Alternative known or unknown class GUIDs must remain refused.'
}
$port = New-PortFixture; $port.HardwareIds = @('OTHER')
$identity = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($port, $port.PdoName)
Assert-True ($identity.ClassGuidMatches -and -not $identity.HardwareIdExact -and $identity.InstanceIdentity -and $identity.HardwareIdKind -ceq 'other_single') 'Hardware mismatch must be isolated from class and instance clauses.'
$port = New-PortFixture; $port.InstanceId = 'OTHER'
$identity = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($port, $port.PdoName)
Assert-True ($identity.RawPortIdentity -and -not $identity.InstancePrefixMatches -and -not $identity.InstanceSuffixValid -and $identity.FailureCode -ceq 'port_instance') 'Instance prefix rejection must be isolated from raw identity.'
$port = New-PortFixture; $port.InstanceId += "`n"
$identity = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($port, $port.PdoName)
Assert-True ($identity.InstancePrefixMatches -and -not $identity.InstanceSuffixValid -and $identity.FailureCode -ceq 'port_instance') 'Invalid instance suffix must remain a separate failed clause.'
foreach ($list in @('missing', 'empty', 'oversize')) {
    $port = New-PortFixture
    switch ($list) {
        'missing' { $port.HardwareIds = $null; $port.ParentHardwareIds = $null }
        'empty' { $port.HardwareIds = @(); $port.ParentHardwareIds = @() }
        'oversize' { $port.HardwareIds = @('OTHER') * 1000; $port.ParentHardwareIds = @('OTHER') * 1000 }
    }
    $identity = [Perpendicular.ChannelAccess.Device]::GetIdentityChecks($port, $port.PdoName)
    Assert-True (-not $identity.Valid -and $identity.HardwareIdCount -in @(-1, 0, 65) -and $identity.ParentHardwareIdCount -eq $identity.HardwareIdCount) 'Missing, empty and oversized lists must be bounded and fail closed.'
}
$unrelated = New-Object InvalidOperationException('PRIVATE_FIXTURE_DO_NOT_REPORT')
$unrelated.Data['PortIdentityChecks'] = 'PRIVATE_FIXTURE_DO_NOT_REPORT'
Assert-True ($null -eq (Get-ChannelPortIdentityFailureReport $unrelated)) 'Untrusted exception data or messages must not become reports.'
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
Assert-True ($native.Contains('One(set, ref info, ClassGuidRegistryProperty)') -and $native.Contains('ClassGuidRegistryProperty = 8') -and -not $native.Contains('port.ClassGuid = info.ClassGuid')) 'Runtime class acquisition must read SPDRP_CLASSGUID on the matched devnode rather than trust the detail-probe field.'
Assert-True ($native.Contains('CapabilitiesRegistryProperty = 15') -and $native.Contains('RawDeviceOkCapability = 0x40') -and $native.Contains('out type, bytes, 4, out required')) 'Capability acquisition must be a bounded SPDRP_CAPABILITIES DWORD on the same devnode.'
Assert-True ($native.Contains('DeviceClass = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 10)') -and $native.Contains('propertyType == 0x0d') -and $native.Contains('ref key, out type, bytes, 16, out required, 0')) 'The unified class query must use the exact SDK key, GUID type and bounded16-byte buffer.'
$elevationPrefix = '-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -EncodedCommand '
$encoding = [Text.UnicodeEncoding]::new($false, $false, $true)
function Get-FixtureElevationPayload {
    param([string]$Arguments)
    Assert-True ($Arguments.StartsWith($elevationPrefix, [StringComparison]::Ordinal) -and $Arguments.Substring($elevationPrefix.Length) -cmatch '\A[A-Za-z0-9+/]+={0,2}\z') 'Only fixed host options and one Base64 token may cross the process boundary.'
    return $encoding.GetString([Convert]::FromBase64String($Arguments.Substring($elevationPrefix.Length)))
}
foreach ($scriptPath in @('D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1', 'D:/Guest Tools/Set-PerpendicularGuestChannelAccess.ps1', 'D:\O''Brien;$(throw ''INJECTED'')\Set-PerpendicularGuestChannelAccess.ps1', 'D:\Unicode à Ω\tick`literal\Set-PerpendicularGuestChannelAccess.ps1')) {
    foreach ($mode in @('Inspect', 'Apply', 'Rollback')) {
        $receipt = if ($mode -eq 'Rollback') { $receiptId } else { '' }
        $arguments = Get-ChannelElevationArguments -ScriptPath $scriptPath -Mode $mode -ReceiptId $receipt
        $payload = Get-FixtureElevationPayload $arguments
        $payloadTokens = $null; $payloadErrors = $null
        $payloadAst = [Management.Automation.Language.Parser]::ParseInput($payload, [ref]$payloadTokens, [ref]$payloadErrors)
        Assert-True ($payloadErrors.Count -eq 0) 'The actual decoded UTF-16LE payload must parse.'
        $calls = @($payloadAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $false))
        Assert-True ($calls.Count -eq 1 -and $calls[0].InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand) 'The payload may invoke only the fixed literal script, never a shell or dynamically evaluated expression.'
        Assert-True ($calls[0].CommandElements[0] -is [Management.Automation.Language.StringConstantExpressionAst] -and $calls[0].CommandElements[0].Value -ceq (ConvertTo-DiagnosticWindowsPath $scriptPath)) 'Adversarial path punctuation must remain one exact literal, with no expression expansion.'
        $confirm = @($calls[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'Confirm' })
        Assert-True ($confirm.Count -eq 1 -and $confirm[0].Argument -is [Management.Automation.Language.VariableExpressionAst] -and $confirm[0].Argument.VariablePath.UserPath -ceq 'false') 'Confirm must receive real PowerShell $false syntax rather than a quoted Boolean string.'
        Assert-True (@($payloadAst.FindAll({ param($node) $node -is [Management.Automation.Language.SubExpressionAst] -or $node -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $false)).Count -eq 0) 'No part of a path or parameter may become an interpolated expression.'
        Assert-True ($payload.Contains(" -Mode '" + $mode + "' -UacChild -Confirm:`$false") -and ($payload.Contains(' -ReceiptId ') -eq ($mode -eq 'Rollback'))) 'Mode, non-recursive child marker and receipt presence must remain exact.'
    }
}
foreach ($badPath in @('', 'Set-PerpendicularGuestChannelAccess.ps1', '\\server\share\Set-PerpendicularGuestChannelAccess.ps1', '\\?\D:\Set-PerpendicularGuestChannelAccess.ps1', 'D:\..\Set-PerpendicularGuestChannelAccess.ps1', 'D:\a"b\Set-PerpendicularGuestChannelAccess.ps1', "D:\a`nb\Set-PerpendicularGuestChannelAccess.ps1", 'D:\CON\Set-PerpendicularGuestChannelAccess.ps1', 'D:\GuestTools\OTHER.ps1', ('D:\' + ('x' * 20000) + '\Set-PerpendicularGuestChannelAccess.ps1'))) {
    Assert-Rejected { Get-ChannelElevationArguments -ScriptPath $badPath -Mode Inspect } 'Invalid, ambiguous, different or oversized helper paths must fail before process launch.'
}
foreach ($badMode in @('', 'OTHER', "Apply';throw 'INJECTED'")) { Assert-Rejected { Get-ChannelElevationArguments -ScriptPath 'D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1' -Mode $badMode } 'Only the existing Mode enum may enter the payload.' }
foreach ($badReceipt in @('', 'not-a-uuid', $receiptId.ToUpperInvariant(), ('{' + $receiptId + '}'), ($receiptId + "';throw 'INJECTED'"))) { Assert-Rejected { Get-ChannelElevationArguments -ScriptPath 'D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1' -Mode Rollback -ReceiptId $badReceipt } 'Rollback accepts only the existing canonical receipt UUID.' }
foreach ($mode in @('Inspect', 'Apply')) { Assert-Rejected { Get-ChannelElevationArguments -ScriptPath 'D:\GuestTools\Set-PerpendicularGuestChannelAccess.ps1' -Mode $mode -ReceiptId $receiptId } 'No receipt parameter may be added to another operation.' }

# Exercise identical decoded call syntax in a harmless child, with a temporary
# filesystem PSDrive and a stub of the same basename. Never load the real helper
# entry point or request elevation. STA is asserted above but unsupported by
# portable pwsh on macOS, so omit only that host option for the portable child.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('perpendicular-elevation-fixture-' + [guid]::NewGuid().ToString('N'))
$fixtureDirectory = Join-Path $fixtureRoot 'O''Brien;$(throw ''INJECTED'')'
[void][IO.Directory]::CreateDirectory($fixtureDirectory)
try {
    $drive = @('Z', 'Y', 'X', 'W', 'V' | Where-Object { $null -eq (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) })[0]
    $fixturePath = $drive + ':\O''Brien;$(throw ''INJECTED'')\Set-PerpendicularGuestChannelAccess.ps1'
    $fixtureFile = Join-Path $fixtureDirectory 'Set-PerpendicularGuestChannelAccess.ps1'
    $fixtureBody = @'
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param([ValidateSet('Inspect','Apply','Rollback')][string]$Mode,[switch]$UacChild,[string]$ReceiptId)
[pscustomobject]@{mode=$Mode;receipt=$ReceiptId;child=$UacChild.IsPresent;confirm_bound=$PSBoundParameters.ContainsKey('Confirm');confirm_value=[bool]$PSBoundParameters['Confirm'];approved=$PSCmdlet.ShouldProcess('synthetic fixture','no operation')} | ConvertTo-Json -Compress
'@
    [IO.File]::WriteAllText($fixtureFile, $fixtureBody)
    $bootstrap = '$ErrorActionPreference = ''Stop''; New-PSDrive -Name ''' + $drive + ''' -PSProvider FileSystem -Root ''' + $fixtureRoot.Replace("'", "''") + "' | Out-Null; "
    $calls = @()
    foreach ($mode in @('Inspect', 'Apply', 'Rollback')) {
        $receipt = if ($mode -eq 'Rollback') { $receiptId } else { '' }
        $calls += Get-FixtureElevationPayload (Get-ChannelElevationArguments -ScriptPath $fixturePath -Mode $mode -ReceiptId $receipt)
    }
    function Invoke-HarmlessElevationFixture {
        param([string]$Payload)
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $hostPrefix = $elevationPrefix
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { $hostPrefix = $hostPrefix.Replace(' -STA ', ' ') }
        $info.Arguments = $hostPrefix + [Convert]::ToBase64String($encoding.GetBytes($Payload))
        $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            if (-not $process.WaitForExit(15000)) { $process.Kill(); $process.WaitForExit(); throw 'The owned harmless fixture child exceeded its timeout.' }
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $process.StandardOutput.ReadToEnd(); Errors = $process.StandardError.ReadToEnd() }
        } finally { $process.Dispose() }
    }
    $childResult = Invoke-HarmlessElevationFixture ($bootstrap + ($calls -join '; '))
    Assert-True ($childResult.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($childResult.Errors)) 'The real noninteractive fixture process must accept the literal path and actual Boolean without a confirmation prompt.'
    $records = @($childResult.Output -split '[\r\n]+' | Where-Object { $_.Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($records.Count -eq 3) 'Only the three intended fixture invocations may produce output; path injection must not execute.'
    for ($index = 0; $index -lt 3; $index++) {
        $mode = @('Inspect', 'Apply', 'Rollback')[$index]
        Assert-True ($records[$index].mode -ceq $mode -and $records[$index].child -and $records[$index].confirm_bound -and -not $records[$index].confirm_value -and $records[$index].approved) 'The harmless advanced script must bind UacChild and Confirm:false correctly and complete ShouldProcess noninteractively.'
        Assert-True ($records[$index].receipt -ceq $(if ($mode -eq 'Rollback') { $receiptId } else { '' })) 'Only the intended canonical receipt may reach the Rollback fixture.'
    }
    [IO.File]::WriteAllText($fixtureFile, ($fixtureBody + "`nthrow 'EXPECTED_FIXTURE_FAILURE'"))
    $failed = Invoke-HarmlessElevationFixture ($bootstrap + $calls[1])
    Assert-True ($failed.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($failed.Errors)) 'A terminating child-script error must remain a real unsuccessful process result.'
} finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
Write-Output ('PASS: ' + $script:checks + ' channel-access checks. Real C# compiled; synthetic descriptors/devnodes/receipts and harmless PowerShell payload fixtures only. No WinAPI, UAC, device, task, ACL, privilege, guest channel or VM was accessed or changed.')
