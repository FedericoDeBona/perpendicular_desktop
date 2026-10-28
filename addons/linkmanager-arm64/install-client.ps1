# Run after driver-stage Install, from the protected, local installed candidate.
[CmdletBinding()]
param([switch]$Launch)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if ($root.StartsWith('\\')) { throw 'Use a protected local installation directory.' }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if (!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated.' }
$m=Get-Content -LiteralPath (Join-Path $root 'candidate.json') -Raw|ConvertFrom-Json
$state=Get-Content -LiteralPath (Join-Path $root 'driver-state.json') -Raw|ConvertFrom-Json
if ($state.Machine -ne (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -or
    @($state.Devices).Count -ne 1) { throw 'Driver state does not identify one owned device on this host.' }
foreach($name in @('LinkManagerSvc.exe','LinkManagerTray.exe','tapmgr.exe')) {
    $expected=$m.files.PSObject.Properties['user-mode-x64/'+$name].Value.sha256
    if (!$expected -or (Get-FileHash -LiteralPath "$root\user-mode-x64\$name").Hash -ne $expected) {
        throw "Client hash mismatch: $name"
    }
}
$nic=@(Get-CimInstance Win32_NetworkAdapter | Where-Object {
    $_.PNPDeviceID -eq $state.Devices[0].PNPDeviceID -and $_.ServiceName -eq 'tap0901'
})
if ($nic.Count -ne 1 -or $nic[0].ConfigManagerErrorCode -ne 0) { throw 'Owned TAP adapter is not healthy.' }
$adapter=Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceGuid -eq $nic[0].GUID }
if ($adapter.Name -ne 'LinkManager Adapter') {
    $adapter | Rename-NetAdapter -NewName 'LinkManager Adapter'
}
$exe="$root\user-mode-x64\LinkManagerSvc.exe"
$service=Get-CimInstance Win32_Service -Filter "Name='LinkManagerSvc'"
if ($service -and $service.PathName -ne ('"'+$exe+'"')) {
    throw 'Another LinkManager service is installed; refusing replacement.'
}
if (!$service) {
    $p=Start-Process -FilePath $exe -ArgumentList '-install' -WorkingDirectory "$root\user-mode-x64" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Service registration failed: $($p.ExitCode)" }
}
Start-Service LinkManagerSvc
$shortcutPath=Join-Path ([Environment]::GetFolderPath('Programs')) 'LinkManager ARM64.lnk'
$wsh=New-Object -ComObject WScript.Shell
$link=$wsh.CreateShortcut($shortcutPath)
if ((Test-Path -LiteralPath $shortcutPath) -and $link.TargetPath -ne "$root\user-mode-x64\LinkManagerTray.exe") {
    throw 'Another LinkManager shortcut exists; refusing replacement.'
}
$link.TargetPath="$root\user-mode-x64\LinkManagerTray.exe"
$link.WorkingDirectory="$root\user-mode-x64"
$link.Save()
if ($Launch) {
    # The current interactive user can read binaries; only administrators/SYSTEM
    # should have write permission on the installed directory.
    & icacls.exe $root /grant:r "*$($identity.User.Value):(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Client read permission failed.' }
    $task='PerpendicularLinkManagerTray-QA'
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { throw 'Launch task already exists.' }
    $action=New-ScheduledTaskAction -Execute "$root\user-mode-x64\LinkManagerTray.exe" -WorkingDirectory "$root\user-mode-x64"
    $principal=New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal|Out-Null
    Start-ScheduledTask -TaskName $task
    Start-Sleep -Seconds 2
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
}
Get-Service LinkManagerSvc | Select-Object Name,Status
Write-Output 'Client staged. Validate browser Ready and the intended remote operation separately.'
