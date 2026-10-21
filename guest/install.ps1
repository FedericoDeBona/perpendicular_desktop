$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'Perpendicular Restart'
New-Item -ItemType Directory -Force -Path $root | Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not secure the guest installation directory.' }
Start-Transcript -Path (Join-Path $root 'installation.log') -Append | Out-Null
try {
    $removedTasks = @()
    foreach ($task in @(Get-ScheduledTask)) {
        if ($task.Description -like 'PerpendicularDesktopGuestAgent/*' -or
            ($task.TaskName -like 'Perpendicular*' -and $task.TaskName -notlike 'PerpendicularRestart*')) {
            $removedTasks += $task.TaskPath + $task.TaskName
            Stop-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false
        }
    }
    $legacyRoot = Join-Path $env:LOCALAPPDATA 'Perpendicular Desktop'
    foreach ($service in @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -like '*Perpendicular Desktop*' })) {
        Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $service.Name -StartupType Disabled
        & sc.exe delete $service.Name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'A previous guest service could not be removed.' }
    }
    foreach ($process in @(Get-CimInstance Win32_Process)) {
        if ($process.ProcessId -ne $PID -and $process.CommandLine -and
            $process.CommandLine.IndexOf($legacyRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    $legacyAgent = Join-Path $legacyRoot 'Guest Agent'
    if (Test-Path -LiteralPath $legacyAgent) {
        $quarantine = Join-Path $root ('removed-guest-agent-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
        Move-Item -LiteralPath $legacyAgent -Destination $quarantine
    }
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $runKey) {
        $run = Get-ItemProperty $runKey
        foreach ($property in $run.PSObject.Properties) {
            if ($property.Value -is [string] -and $property.Value.IndexOf($legacyRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Remove-ItemProperty -Path $runKey -Name $property.Name
            }
        }
    }
    $removedShares = @()
    if (Test-Path 'HKCU:\Network') {
        foreach ($mapping in @(Get-ChildItem 'HKCU:\Network')) {
            $remote = (Get-ItemProperty $mapping.PSPath).RemotePath
            if ($remote -like '\\10.0.2.2\*') {
                $removedShares += $remote
                & net.exe use ($mapping.PSChildName + ':') /delete /y 2>&1 | Out-Null
                Remove-Item -LiteralPath $mapping.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    & cmdkey.exe /delete:10.0.2.2 2>&1 | Out-Null
    # The previous sharing integration also redirected Windows known folders.
    # Restore only entries pointing at that integration, leaving other choices alone.
    $restoredFolders = @()
    $folderNames = @{
        'Desktop'='Desktop'; 'Personal'='Documents'; 'My Pictures'='Pictures'; 'My Music'='Music'; 'My Video'='Videos'
        '{374DE290-123F-4565-9164-39C4925E467B}'='Downloads'; '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'='Documents'
        '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}'='Desktop'; '{0DDD015D-B06C-45D5-8C4C-F59713854639}'='Pictures'
        '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}'='Videos'; '{A0C69A99-21C8-4671-8703-7934162FCF1D}'='Music'
        '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}'='Downloads'
    }
    foreach ($keyName in @('User Shell Folders','Shell Folders')) {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\' + $keyName
        if (!(Test-Path $key)) { continue }
        foreach ($property in (Get-ItemProperty $key).PSObject.Properties) {
            if ($property.Value -isnot [string] -or ($property.Value -notlike 'M:\*' -and $property.Value -notlike '\\10.0.2.2\*')) { continue }
            $folder = $folderNames[$property.Name]
            if (!$folder) { throw ('Unknown redirected folder: ' + $property.Name) }
            $local = Join-Path $env:USERPROFILE $folder
            New-Item -ItemType Directory -Force -Path $local | Out-Null
            if ($keyName -eq 'User Shell Folders') { Set-ItemProperty -Path $key -Name $property.Name -Type ExpandString -Value ('%USERPROFILE%\' + $folder) }
            else { Set-ItemProperty -Path $key -Name $property.Name -Type String -Value $local }
            $restoredFolders += $property.Name
        }
    }
    $remainingTasks = @(Get-ScheduledTask | Where-Object {
        $_.Description -like 'PerpendicularDesktopGuestAgent/*' -or
        ($_.TaskName -like 'Perpendicular*' -and $_.TaskName -notlike 'PerpendicularRestart*')
    })
    if ($remainingTasks.Count -ne 0) { throw 'A previous integration task remains installed.' }
    $display = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, AdapterCompatibility)
    @{ removedTasks = $removedTasks; removedShares = $removedShares; restoredFolders = $restoredFolders; remainingLegacyTasks = $remainingTasks.Count
       display = $display; completedAt = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path (Join-Path $root 'cleanup.json')
    & (Join-Path $PSScriptRoot 'perpendicular-guest.exe') install (Join-Path $PSScriptRoot 'connection.json')
    if ($LASTEXITCODE -ne 0) { throw 'The new guest service could not be installed.' }
    & sc.exe failure PerpendicularRestart reset= 86400 actions= restart/2000/restart/5000/restart/10000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure guest service recovery.' }
    Write-Host 'Perpendicular guest installed. Previous integration removed from this Windows copy.'
} finally {
    Stop-Transcript | Out-Null
}
