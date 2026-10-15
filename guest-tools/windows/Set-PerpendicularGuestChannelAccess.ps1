#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Inspect', 'Apply', 'Rollback')][string]$Mode = 'Inspect',
    [string]$ReceiptId,
    [switch]$RequestElevation,
    [Parameter(DontShow = $true)][switch]$UacChild
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-ChannelAccess {
    Add-Type -Path (Join-Path $PSScriptRoot 'PerpendicularChannelAccess.Native.cs') -ErrorAction Stop
    # Reuse only these reviewed ownership function declarations, never the
    # diagnostic entry point (which probes the port) or arbitrary script bodies.
    $path = Join-Path $PSScriptRoot 'Get-PerpendicularGuestToolsDiagnostics.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The packaged ownership validator did not parse.' }
    foreach ($name in @('ConvertTo-DiagnosticWindowsPath', 'Test-DiagnosticWindowsPath', 'Get-DiagnosticExpectedTask', 'Test-DiagnosticAgentArguments', 'Test-DiagnosticOwnedTask')) {
        $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false))
        if ($definitions.Count -ne 1) { throw 'The packaged ownership validator is incomplete.' }
        # Function definitions must survive this initializer's local scope.
        Set-Item -Path ('Function:script:' + $name) -Value ($definitions[0].Body.GetScriptBlock())
    }
}

function Assert-ChannelRegularPath {
    param([string]$Path, [switch]$Directory)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -ne $Directory.IsPresent -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Expected an ordinary owned package/receipt path.' }
    $parent = if ($Directory) { $item.Parent } else { $item.Directory }
    while ($null -ne $parent) {
        if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A reparse-point ancestor was refused.' }
        $parent = $parent.Parent
    }
    return $item
}

function Get-ChannelOwner {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value
    [void][Perpendicular.ChannelAccess.Descriptor]::UserSid($sid)
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $desktopAccount = [Perpendicular.ChannelAccess.Device]::DesktopAccount($session)
    $desktopSid = (New-Object Security.Principal.NTAccount($desktopAccount)).Translate([Security.Principal.SecurityIdentifier]).Value
    if ($desktopSid -cne $sid) { throw 'Use administrator consent for the same logged-in desktop account; alternate credentials are refused.' }
    $directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Perpendicular Desktop\Guest Agent'
    [void](Assert-ChannelRegularPath -Path $directory -Directory)
    $manifestPath = Join-Path $directory 'install.json'
    $item = Assert-ChannelRegularPath -Path $manifestPath
    if ($item.Length -gt 1048576) { throw 'Installed ownership manifest exceeds the bound.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $expected = Get-DiagnosticExpectedTask -Sid $sid -Account $identity.Name -Directory $directory -WindowsDirectory ([Environment]::GetFolderPath('Windows'))
    if ($manifest.product -cne 'Perpendicular Desktop Guest Agent' -or $manifest.owner_sid -cne $sid -or $manifest.task_name -cne $expected.Name) { throw 'Installed package ownership was not confirmed.' }
    $task = Get-ScheduledTask -TaskPath '\' -TaskName $expected.Name -ErrorAction Stop
    if (-not (Test-DiagnosticOwnedTask -Task $task -Expected $expected)) { throw 'The exact limited interactive Guest Agent task was not confirmed.' }
    [pscustomobject]@{ Sid = $sid; Directory = $directory; Session = $session }
}

function Get-ChannelPlan {
    param($Port, [string]$Sid)
    [void][Perpendicular.ChannelAccess.Descriptor]::UserSid($Sid)
    [Perpendicular.ChannelAccess.Device]::ValidatePort($Port, $Port.PdoName)
    if ($null -eq $Port.LiveDaclDescriptor) { throw 'The actual PDO DACL could not be read; no replacement policy is inferred.' }
    $source = $Port.LiveDaclDescriptor
    if ($null -ne $Port.Property) {
        if (-not [Perpendicular.ChannelAccess.Descriptor]::Equal([Perpendicular.ChannelAccess.Descriptor]::Dacl($Port.Property), [Perpendicular.ChannelAccess.Descriptor]::Dacl($source))) {
            throw 'Configured and live DACLs differ; restart or review the pending policy before another change.'
        }
        $source = $Port.Property
    }
    $after = [Perpendicular.ChannelAccess.Descriptor]::AddReadWrite($source, $Sid)
    [pscustomobject]@{ Sid = $Sid; Port = $Port; SourceDescriptor = $source; Before = $Port.Property; After = $after
        Changed = (-not [Perpendicular.ChannelAccess.Descriptor]::Equal($source, $after)) }
}

function ConvertTo-ChannelReceipt {
    param($Plan, [string]$Id)
    $parsed = [guid]::Parse($Id)
    if ($parsed.ToString('D') -cne $Id) { throw 'A canonical receipt UUID is required.' }
    [pscustomobject]@{ format_version = 1; product = 'Perpendicular Guest Channel Access'; receipt_id = $Id
        created_at = [DateTime]::UtcNow.ToString('o'); owner_sid = $Plan.Sid; alias = 'org.perpendicular.guest_agent.0'
        instance_id = $Plan.Port.InstanceId; parent_id = $Plan.Port.ParentId; observed_pdo = $Plan.Port.PdoName
        before_present = ($null -ne $Plan.Before)
        before = $(if ($null -ne $Plan.Before) { [Convert]::ToBase64String($Plan.Before) } else { '' })
        source_descriptor = [Convert]::ToBase64String($Plan.SourceDescriptor); after = [Convert]::ToBase64String($Plan.After)
        runtime_access_verified = $false; requires_restart_verification = $true }
}

function Get-ChannelRollback {
    param($Receipt, [string]$Sid)
    [void][Perpendicular.ChannelAccess.Descriptor]::UserSid($Sid)
    $keys = @('format_version', 'product', 'receipt_id', 'created_at', 'owner_sid', 'alias', 'instance_id', 'parent_id', 'observed_pdo', 'before_present', 'before', 'source_descriptor', 'after', 'runtime_access_verified', 'requires_restart_verification')
    if (@($Receipt.PSObject.Properties).Count -ne $keys.Count -or @($Receipt.PSObject.Properties | Where-Object { $keys -cnotcontains $_.Name }).Count -ne 0 -or
        $Receipt.format_version -ne 1 -or $Receipt.product -cne 'Perpendicular Guest Channel Access' -or $Receipt.alias -cne 'org.perpendicular.guest_agent.0' -or
        $Receipt.owner_sid -cne $Sid -or $Receipt.before_present -isnot [bool] -or $Receipt.runtime_access_verified -isnot [bool] -or $Receipt.requires_restart_verification -isnot [bool] -or
        $Receipt.runtime_access_verified -cne $false -or $Receipt.requires_restart_verification -cne $true) { throw 'Invalid per-channel rollback receipt.' }
    $id = [guid]::Parse($Receipt.receipt_id)
    if ($id.ToString('D') -cne $Receipt.receipt_id -or $Receipt.instance_id.Length -gt 1024 -or $Receipt.parent_id.Length -gt 1024) { throw 'Invalid receipt identity.' }
    foreach ($value in @($Receipt.before, $Receipt.source_descriptor, $Receipt.after)) { if ($value -isnot [string] -or $value.Length -gt 87384) { throw 'Receipt descriptor exceeds the bound.' } }
    $source = [Convert]::FromBase64String($Receipt.source_descriptor)
    $after = [Convert]::FromBase64String($Receipt.after)
    $before = $null
    if ($Receipt.before_present) { $before = [Convert]::FromBase64String($Receipt.before) }
    elseif ($Receipt.before -cne '') { throw 'An absent original override cannot contain bytes.' }
    if (($null -ne $before -and -not [Perpendicular.ChannelAccess.Descriptor]::Equal($source, $before)) -or
        -not [Perpendicular.ChannelAccess.Descriptor]::Equal([Perpendicular.ChannelAccess.Descriptor]::AddReadWrite($source, $Sid), $after) -or
        [Perpendicular.ChannelAccess.Descriptor]::Equal($source, $after)) { throw 'Receipt is not the exact reviewed one-SID GR/GW delta.' }
    [pscustomobject]@{ InstanceId = $Receipt.instance_id; ParentId = $Receipt.parent_id; Before = $before; After = $after }
}

function New-ChannelReceiptSecurity {
    param([switch]$Directory)
    $security = if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        if ($Directory) { $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow') }
        else { $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow') }
        [void]$security.AddAccessRule($rule)
    }
    return $security
}

function Assert-ChannelReceiptProtected {
    param([string]$Path, [switch]$Directory)
    $item = Assert-ChannelRegularPath -Path $Path -Directory:$Directory
    $security = $item.GetAccessControl()
    if (-not $security.AreAccessRulesProtected -or $security.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544') { throw 'The rollback store is not protected for administrators.' }
    $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) { throw 'Unexpected rollback store permissions.' }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $matching = @($rules | Where-Object { $_.IdentityReference.Value -ceq $sid -and $_.AccessControlType -eq 'Allow' -and $_.FileSystemRights -eq 'FullControl' })
        if ($matching.Count -ne 1) { throw 'Unexpected rollback store permissions.' }
    }
    return $item
}

function Get-ChannelReceiptDirectory {
    param([switch]$Create)
    $path = [Environment]::GetFolderPath('CommonApplicationData')
    [void](Assert-ChannelRegularPath -Path $path -Directory)
    foreach ($part in @('Perpendicular Guest Channel Access', 'Receipts')) {
        $path = Join-Path $path $part
        if (-not (Test-Path -LiteralPath $path)) {
            if (-not $Create) { throw 'The protected rollback store is missing.' }
            [void][IO.Directory]::CreateDirectory($path, (New-ChannelReceiptSecurity -Directory))
        }
        [void](Assert-ChannelReceiptProtected -Path $path -Directory)
    }
    return $path
}

function Save-ChannelReceipt {
    param($Receipt)
    $path = Join-Path (Get-ChannelReceiptDirectory -Create) ($Receipt.receipt_id + '.json')
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Receipt | ConvertTo-Json -Depth 4))
    if ($bytes.Length -gt 1048576) { throw 'Rollback receipt exceeds the bound.' }
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::WriteData, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough, (New-ChannelReceiptSecurity))
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [void](Assert-ChannelReceiptProtected -Path $path)
    return $path
}

function Assert-ChannelReadonlyPackage {
    [void](Assert-ChannelRegularPath -Path $PSScriptRoot -Directory)
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($PSScriptRoot))
    if ($drive.DriveType -ne [IO.DriveType]::CDRom) { throw 'Run the reviewed helper from the mounted read-only Guest Tools disc.' }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1 inside the logged-in guest desktop.' }
if ($Mode -ne 'Rollback' -and -not [string]::IsNullOrEmpty($ReceiptId)) { throw 'A receipt is accepted only for rollback.' }
if ($Mode -eq 'Rollback') { $id = [guid]::Parse($ReceiptId); if ($id.ToString('D') -cne $ReceiptId) { throw 'Use the exact canonical receipt UUID.' } }
Initialize-ChannelAccess
$owner = Get-ChannelOwner
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if (-not $RequestElevation -or $UacChild) { throw 'Administrator consent is required to inspect the actual PDO DACL or prepare its per-instance override. Nothing was changed.' }
    Assert-ChannelReadonlyPackage
    $scriptPath = Join-Path $PSScriptRoot 'Set-PerpendicularGuestChannelAccess.ps1'
    if ($scriptPath -match '["\r\n]') { throw 'Invalid helper path.' }
    if (-not $PSCmdlet.ShouldProcess('Only the fixed Guest Tools port', 'Request administrator consent for ' + $Mode)) { return }
    # Parent ShouldProcess has already accepted this explicit operation. The
    # fresh child is noninteractive; it must not ask the same console question.
    $arguments = '-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Mode ' + $Mode + ' -UacChild -Confirm:$false'
    if ($Mode -eq 'Rollback') { $arguments += ' -ReceiptId ' + $ReceiptId }
    $process = Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -PassThru -Wait
    exit $process.ExitCode
}
if ($Mode -ne 'Inspect') { Assert-ChannelReadonlyPackage }
if ($Mode -eq 'Rollback') {
    $path = Join-Path (Get-ChannelReceiptDirectory) ($ReceiptId + '.json')
    $item = Assert-ChannelReceiptProtected -Path $path
    if ($item.Length -gt 1048576) { throw 'Rollback receipt exceeds the bound.' }
    $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($receipt.receipt_id -cne $ReceiptId) { throw 'Receipt filename and identity do not match.' }
    $rollback = Get-ChannelRollback -Receipt $receipt -Sid $owner.Sid
    if ($PSCmdlet.ShouldProcess('Only the fixed Guest Tools PDO instance', 'Restore its exact previous override, or delete this override if originally absent')) {
        [Perpendicular.ChannelAccess.Device]::WriteConditional($rollback.InstanceId, $rollback.ParentId, $rollback.After, $rollback.Before, $null)
        Write-Output 'Previous per-instance property restored. Runtime access is unverified; restart Windows manually when appropriate and rerun the diagnostic.'
    }
    return
}
$port = [Perpendicular.ChannelAccess.Device]::Inspect()
$plan = Get-ChannelPlan -Port $port -Sid $owner.Sid
Write-Output ('FixedGuestChannelIdentified=True; ExactDesktopPackageAndLimitedTaskOwned=True; AdditionalOneSidReadWriteNeeded=' + $plan.Changed)
Write-Output 'This is a per-instance property proposal. It does not prove live access or persistence after device recreation. No device is restarted automatically.'
if ($Mode -eq 'Inspect' -or -not $plan.Changed) { return }
if ($PSCmdlet.ShouldProcess('Only the uniquely identified Guest Tools PDO instance', 'Save protected rollback receipt, then add only GR/GW for the verified desktop account')) {
    $receipt = ConvertTo-ChannelReceipt -Plan $plan -Id ([guid]::NewGuid().ToString('D'))
    $receiptPath = Save-ChannelReceipt -Receipt $receipt
    # Report the ID before mutation so a genuine write/readback failure retains
    # a usable receipt. No automatic rollback can overwrite a concurrent policy.
    Write-Output ('RollbackReceiptId=' + $receipt.receipt_id)
    [Perpendicular.ChannelAccess.Device]::WriteConditional($port.InstanceId, $port.ParentId, $plan.Before, $plan.After, [Perpendicular.ChannelAccess.Descriptor]::Dacl($port.LiveDaclDescriptor))
    Write-Output 'Per-instance override saved and read back. RuntimeAccessVerified=False. A manual Windows restart and the limited-user connection test are still required.'
}
