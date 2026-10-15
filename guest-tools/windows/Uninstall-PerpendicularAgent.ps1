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

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'This uninstaller runs only inside Windows.'
}
Initialize-AgentTaskOwnership
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$ownerSid = $identity.User.Value
$taskName = 'Perpendicular Desktop Guest Agent (' + $ownerSid + ')'
$description = 'PerpendicularDesktopGuestAgent/v1;sid=' + $ownerSid
$directory = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'Perpendicular Desktop\Guest Agent'
$manifestPath = Join-Path $directory 'install.json'
$agentPath = Join-Path $directory 'PerpendicularAgent.ps1'
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $agentPath + '"'
$task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if (-not (Test-AgentTaskOwnership -Task $task -OwnerSid $ownerSid -Description $description -Executable $executable -Arguments $arguments)) {
        throw 'A task with this name is not the owned Guest Agent task; it was not changed.'
    }
    Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
}
if (Test-Path -LiteralPath $directory) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The directory has no ownership manifest. The task was removed, but files were preserved.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not (Test-AgentManifestOwnership -Manifest $manifest -OwnerSid $ownerSid) -or
        ((Get-Item -LiteralPath $directory).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The directory ownership check failed. The task was removed, but files were preserved.'
    }
    # Delete only known package files, never recursively remove a user directory.
    foreach ($file in (@(Get-AgentRuntimeFiles) + @('install.json'))) {
        $path = Join-Path $directory $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { Remove-Item -LiteralPath $directory }
}
Write-Output 'The current user''s Perpendicular Guest Agent task and owned package files were removed. Downloaded files and drivers were preserved.'
