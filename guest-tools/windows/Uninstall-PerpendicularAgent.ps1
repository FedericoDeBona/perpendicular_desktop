#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'This uninstaller runs only inside Windows.'
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
$task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ($task.Description -cne $description -or @($ownerSid, $identity.Name) -notcontains $task.Principal.UserId -or
        @($task.Actions).Count -ne 1 -or
        -not [string]::Equals($task.Actions[0].Execute, $executable, [System.StringComparison]::OrdinalIgnoreCase) -or
        $task.Actions[0].Arguments -cne $arguments) {
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
    if ($manifest.product -cne 'Perpendicular Desktop Guest Agent' -or $manifest.owner_sid -cne $ownerSid -or
        ((Get-Item -LiteralPath $directory).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The directory ownership check failed. The task was removed, but files were preserved.'
    }
    # Delete only known package files, never recursively remove a user directory.
    foreach ($file in @('PerpendicularAgent.ps1', 'PerpendicularAgent.Core.ps1', 'PerpendicularAgent.Display.ps1', 'Uninstall-PerpendicularAgent.ps1', 'install.json')) {
        $path = Join-Path $directory $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { Remove-Item -LiteralPath $directory }
}
Write-Output 'The current user''s Perpendicular Guest Agent task and owned package files were removed. Downloaded files and drivers were preserved.'
