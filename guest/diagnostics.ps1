$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$legacy = Join-Path $env:LOCALAPPDATA 'Perpendicular Desktop'
$tasks = @(Get-ScheduledTask | Where-Object { $_.Description -like 'PerpendicularDesktopGuestAgent/*' -or ($_.TaskName -like 'Perpendicular*' -and $_.TaskName -notlike 'PerpendicularRestart*') } | Select-Object TaskName, State)
$processes = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($legacy, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object Name, ProcessId)
$services = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -like '*Perpendicular Desktop*' } | Select-Object Name, State, StartMode)
$shares = @()
if (Test-Path 'HKCU:\Network') { $shares = @(Get-ChildItem 'HKCU:\Network' | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.RemotePath -like '\\10.0.2.2\*' -or $_.RemotePath -like '\\10.0.2.4\*' } | Select-Object RemotePath) }
$startup = @()
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path $runKey) { $startup = @((Get-ItemProperty $runKey).PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value.IndexOf($legacy, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object Name) }
$cleanup = $null
$cleanupFile = Join-Path $env:ProgramData 'Perpendicular Restart\cleanup.json'
if (Test-Path -LiteralPath $cleanupFile) { $cleanup = Get-Content -Raw -LiteralPath $cleanupFile | ConvertFrom-Json }
$folders = @((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders').PSObject.Properties | Where-Object { $_.Value -is [string] -and ($_.Value -like 'M:\*' -or $_.Value -like '\\10.0.2.2\*' -or $_.Value -like '\\10.0.2.4\*') } | Select-Object Name)
$drivers = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' | Where-Object { $_.PSChildName -match '(perpendicular|viogpu)' } | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.Type -eq 1 -or $_.Type -eq 2 } | Select-Object PSChildName, Start, ImagePath)
$uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' | Select-Object EnableLUA,ConsentPromptBehaviorAdmin,PromptOnSecureDesktop
@{ legacyTasks=$tasks; legacyProcesses=$processes; legacyServices=$services; legacyShares=$shares; legacyStartup=$startup; legacyFolders=$folders; graphicsDrivers=$drivers
   uac=$uac
   oldAgentDirectoryExists=(Test-Path (Join-Path $legacy 'Guest Agent')); cleanup=$cleanup; bootTime=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') } | ConvertTo-Json -Depth 8 -Compress
