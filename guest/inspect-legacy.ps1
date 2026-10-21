#Requires -Version 5.1
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$shell = New-Object -ComObject Shell.Application
$macFiles = @($shell.NameSpace(0).Items() | Where-Object Name -eq 'Mac Files' | ForEach-Object {
    $entry = [ordered]@{name=$_.Name; path=$_.Path}
    if ([IO.Path]::GetExtension($_.Path) -eq '.lnk' -and -not $_.Path.StartsWith('\\')) {
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($_.Path)
        $entry.target=$link.TargetPath; $entry.arguments=$link.Arguments
    }
    $entry
})
$packages = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object DisplayName -like '*Parallels*' |
    Select-Object DisplayName,Publisher,WindowsInstaller,PSChildName,UninstallString,QuietUninstallString,InstallLocation)
$services = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' |
    Where-Object PSChildName -match '^prl' | Get-ItemProperty |
    Select-Object PSChildName,Type,ImagePath,Start)
$cleanup = $null
$cleanupFile = Join-Path $env:ProgramData 'Perpendicular Restart\cleanup.json'
if (Test-Path -LiteralPath $cleanupFile) { $cleanup = Get-Content -Raw -LiteralPath $cleanupFile | ConvertFrom-Json }
$report = @{collectedAt=[DateTime]::UtcNow.ToString('o'); macFiles=$macFiles; parallelsPackages=$packages; parallelsServices=$services; cleanup=$cleanup}
$json = $report | ConvertTo-Json -Depth 6
$json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $env:ProgramData 'Perpendicular Restart\legacy-inventory.json')
@{collectedAt=$report.collectedAt; macFiles=$macFiles; parallelsPackages=$packages
  parallelsServiceCount=$services.Count
  cleanup=if ($cleanup) { $cleanup | Select-Object completed,error,remainingLegacyTasks,quarantinedHostApplicationLinks,parallelsTools } else { $null }} | ConvertTo-Json -Depth 6
