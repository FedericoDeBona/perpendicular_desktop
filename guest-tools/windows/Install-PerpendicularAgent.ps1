#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-AgentTaskOwnership {
    param([string]$SourcePath = (Join-Path $PSScriptRoot 'Get-PerpendicularGuestToolsDiagnostics.ps1'))
    # Read only three reviewed identity declarations. Never dot-source or run
    # the diagnostic entry point, native initializer or arbitrary script body.
    $item = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -eq 0 -or $item.Length -gt 1048576 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The packaged ownership source is not a bounded regular file.' }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($item.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The packaged ownership validator did not parse.' }
    $imports = [ordered]@{}
    foreach ($name in @('Resolve-DiagnosticPrincipalSid', 'Test-DiagnosticCanonicalSid', 'Get-DiagnosticPrincipalIdentity')) {
        $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false))
        if ($definitions.Count -ne 1) { throw 'The packaged ownership validator is incomplete or ambiguous.' }
        $imports[$name] = $definitions[0].Body.GetScriptBlock()
    }
    foreach ($name in $imports.Keys) { Set-Item -Path ('Function:script:' + $name) -Value $imports[$name] }
}

function Test-AgentTaskOwnership {
    param($Task, [string]$OwnerSid, [string]$Description, [string]$Executable, [string]$Arguments, [scriptblock]$PrincipalResolver)
    try {
        $principal = Get-DiagnosticPrincipalIdentity -PrincipalUserId $Task.Principal.UserId -ExpectedSid $OwnerSid -Resolver $PrincipalResolver
        # Preserve the existing description/action guards. Only UserId now
        # requires successful OS resolution and the exact canonical owner SID.
        return ($Task.Description -ceq $Description -and $principal.PrincipalSidResolved -and $principal.PrincipalSidMatchesOwner -and
            @($Task.Actions).Count -eq 1 -and
            [string]::Equals($Task.Actions[0].Execute, $Executable, [StringComparison]::OrdinalIgnoreCase) -and
            $Task.Actions[0].Arguments -ceq $Arguments)
    } catch { return $false }
}

function Test-AgentManifestOwnership {
    param($Manifest, [string]$OwnerSid)
    # Older owned manifests legitimately omit the newly copied diagnostic
    # source in their files list. Product/SID ownership remains mandatory.
    try { return ($Manifest.product -ceq 'Perpendicular Desktop Guest Agent' -and $Manifest.owner_sid -ceq $OwnerSid) }
    catch { return $false }
}

function Get-AgentRuntimeFiles {
    return @('PerpendicularAgent.ps1', 'PerpendicularAgent.Core.ps1', 'PerpendicularAgent.Display.ps1', 'Uninstall-PerpendicularAgent.ps1', 'Get-PerpendicularGuestToolsDiagnostics.ps1')
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT -or
    [System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'Run this installer from the Windows desktop as the user who will use the VM.'
}
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$ownerSid = $identity.User.Value
$taskName = 'Perpendicular Desktop Guest Agent (' + $ownerSid + ')'
$description = 'PerpendicularDesktopGuestAgent/v1;sid=' + $ownerSid
$directory = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'Perpendicular Desktop\Guest Agent'
$manifestPath = Join-Path $directory 'install.json'
$agentPath = Join-Path $directory 'PerpendicularAgent.ps1'
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $agentPath + '"'
$runtimeFiles = @(Get-AgentRuntimeFiles)
foreach ($file in $runtimeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) {
        throw "The Guest Tools package is incomplete: $file"
    }
}
Initialize-AgentTaskOwnership

if (Test-Path -LiteralPath $directory) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'An existing Guest Agent directory has no ownership manifest; it was not changed.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not (Test-AgentManifestOwnership -Manifest $manifest -OwnerSid $ownerSid)) {
        throw 'The existing Guest Agent directory belongs to another installation; it was not changed.'
    }
    if (((Get-Item -LiteralPath $directory).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The Guest Agent directory must not be a reparse point.'
    }
}
$existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    if (-not (Test-AgentTaskOwnership -Task $existing -OwnerSid $ownerSid -Description $description -Executable $executable -Arguments $arguments)) {
        throw 'A task with this name is not the owned Guest Agent task; it was not changed.'
    }
    Stop-ScheduledTask -InputObject $existing -ErrorAction SilentlyContinue
}
[void][System.IO.Directory]::CreateDirectory($directory)
foreach ($file in $runtimeFiles) {
    $source = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $file))
    $target = [System.IO.Path]::GetFullPath((Join-Path $directory $file))
    if (-not [string]::Equals($source, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}
$manifest = @{
    product = 'Perpendicular Desktop Guest Agent'; protocol = 1; owner_sid = $ownerSid
    task_name = $taskName; files = $runtimeFiles; installed_at = [DateTime]::UtcNow.ToString('o')
}
$manifestJSON = ConvertTo-Json -InputObject $manifest -Depth 4
[System.IO.File]::WriteAllText($manifestPath, $manifestJSON, (New-Object System.Text.UTF8Encoding($false)))

$action = New-ScheduledTaskAction -Execute $executable -Argument $arguments -WorkingDirectory $directory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$principal = New-ScheduledTaskPrincipal -UserId $ownerSid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description
Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $task -Force | Out-Null
Start-ScheduledTask -TaskName $taskName -TaskPath '\'
Write-Output ('Guest Agent installed for ' + $identity.Name + '. It starts now and at this user''s next logon.')
Write-Output ('Install directory: ' + $directory)
Write-Output 'The signed ARM64 VirtIO serial driver must also be installed. Check Guest Tools in the Mac app for a real connection.'
