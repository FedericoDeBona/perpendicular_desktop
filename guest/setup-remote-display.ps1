param([switch]$Undo)
$ErrorActionPreference = 'Stop'
# Local setup only. No account, password, UAC, certificate or VM hardware changes.
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$admin) {
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($Undo) { $arguments += ' -Undo' }
    $process = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

$root = Join-Path $env:ProgramData 'Perpendicular Restart\Remote Display Setup'
$backup = Join-Path $root 'original-state.json'
$terminal = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$listener = Join-Path $terminal 'WinStations\RDP-Tcp'
$serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService'
$settings = @(
    @{ Path=$terminal; Name='fDenyTSConnections'; Value=0 },
    @{ Path=$listener; Name='UserAuthentication'; Value=1 },
    @{ Path=$listener; Name='SecurityLayer'; Value=2 }
)
function Read-RegistryValue([string]$Path, [string]$Name) {
    $key = Get-Item -LiteralPath $Path
    $exists = $key.GetValueNames() -contains $Name
    if ($exists) {
        return @{ Path=$Path; Name=$Name; Exists=$true; Kind=[string]$key.GetValueKind($Name); Value=$key.GetValue($Name) }
    }
    return @{ Path=$Path; Name=$Name; Exists=$false; Kind=$null; Value=$null }
}
function Restore-RegistryValue($Entry) {
    if ($Entry.Exists) {
        New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -PropertyType $Entry.Kind -Value $Entry.Value -Force | Out-Null
    } else {
        $key = Get-Item -LiteralPath $Entry.Path
        if ($key.GetValueNames() -contains $Entry.Name) {
            Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name
        }
    }
}
function Restore-Setup($State) {
    if ($State.schemaVersion -ne 1 -or $State.ruleName -notmatch '^Perpendicular-RemoteDisplay-[0-9a-f-]{36}$') {
        throw 'Invalid remote-display backup; no settings were restored.'
    }
    # Remove only the rule created by this setup; leave existing rules untouched.
    $rule = Get-NetFirewallRule -PolicyStore PersistentStore -Name $State.ruleName -ErrorAction SilentlyContinue
    if ($rule) { $rule | Remove-NetFirewallRule }
    foreach ($entry in $State.settings) { Restore-RegistryValue $entry }
    $service = Get-Service -Name TermService
    if ($State.serviceStatus -eq 'Stopped' -and $service.Status -ne 'Stopped') {
        Stop-Service -Name TermService
        (Get-Service -Name TermService).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    }
    $start = [int]$State.serviceStart.Value
    switch ($start) {
        2 { Set-Service -Name TermService -StartupType Automatic }
        3 { Set-Service -Name TermService -StartupType Manual }
        4 { Set-Service -Name TermService -StartupType Disabled }
        default { throw 'Unsupported original TermService start type.' }
    }
    Restore-RegistryValue $State.serviceDelayedStart
    if ($State.serviceStatus -eq 'Running' -and (Get-Service -Name TermService).Status -ne 'Running') {
        Start-Service -Name TermService
        (Get-Service -Name TermService).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    }
}

if ($Undo) {
    if (!(Test-Path -LiteralPath $backup)) { throw 'No Perpendicular remote-display setup backup exists.' }
    $state = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
    Restore-Setup $state
    Remove-Item -LiteralPath $backup
    Write-Host 'Previous RDP settings and TermService state restored. The Perpendicular firewall rule was removed.'
    exit 0
}
if (Test-Path -LiteralPath $backup) {
    throw 'A saved setup already exists. Run this script with -Undo before applying it again.'
}
if ((Get-ItemProperty -LiteralPath $listener -Name PortNumber).PortNumber -ne 3389) {
    throw 'The RDP listener does not use TCP 3389. No listener port will be changed.'
}
# Do not override organization policy or silently weaken authentication.
$policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
if (Test-Path -LiteralPath $policyPath) {
    foreach ($setting in $settings) {
        $entry = Read-RegistryValue $policyPath $setting.Name
        if ($entry.Exists -and [int]$entry.Value -ne $setting.Value) {
            throw ('An existing policy conflicts with the remote-display setup: ' + $setting.Name)
        }
    }
}
$service = Get-Service -Name TermService
if ([string]$service.Status -notin @('Running','Stopped')) { throw 'Wait until TermService is running or stopped, then retry.' }
$originalSettings = @($settings | ForEach-Object { Read-RegistryValue $_.Path $_.Name })
foreach ($entry in $originalSettings) {
    if ($entry.Exists -and $entry.Kind -ne 'DWord') { throw ('Unexpected registry value type: ' + $entry.Name) }
}
$state = @{
    schemaVersion=1; savedAt=[DateTime]::UtcNow.ToString('o')
    settings=$originalSettings; serviceStatus=[string]$service.Status
    serviceStart=(Read-RegistryValue $serviceKey 'Start')
    serviceDelayedStart=(Read-RegistryValue $serviceKey 'DelayedAutoStart')
    ruleName=('Perpendicular-RemoteDisplay-' + [Guid]::NewGuid().ToString())
}
if (!$state.serviceStart.Exists -or [int]$state.serviceStart.Value -notin @(2,3,4)) {
    throw 'Unsupported TermService start type. No settings were changed.'
}
New-Item -ItemType Directory -Path $root -Force | Out-Null
if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The private setup directory cannot be a reparse point.' }
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $root -AclObject $acl
# Persist the original state before modifying any RDP setting, service or firewall rule.
$temporary = Join-Path $root ('state-' + [Guid]::NewGuid().ToString() + '.tmp')
$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
Move-Item -LiteralPath $temporary -Destination $backup
try {
    # Keep the listener's security requirements strict before allowing connections.
    foreach ($setting in @($settings[1], $settings[2])) {
        New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -PropertyType DWord -Value $setting.Value -Force | Out-Null
    }
    New-NetFirewallRule -PolicyStore PersistentStore -Name $state.ruleName -DisplayName 'Perpendicular remote display (local Mac only)' `
        -Description 'Perpendicular one-time RDP experiment; undo using setup-remote-display.ps1 -Undo.' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress '10.0.2.2' -Profile Any `
        -Service TermService -Program (Join-Path $env:WINDIR 'System32\svchost.exe') | Out-Null
    New-ItemProperty -LiteralPath $terminal -Name fDenyTSConnections -PropertyType DWord -Value 0 -Force | Out-Null
    if ([int]$state.serviceStart.Value -eq 4) { Set-Service -Name TermService -StartupType Manual }
    Start-Service -Name TermService
    (Get-Service -Name TermService).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    foreach ($setting in $settings) {
        if ((Get-ItemPropertyValue -LiteralPath $setting.Path -Name $setting.Name) -ne $setting.Value) {
            throw ('RDP setting was not applied: ' + $setting.Name)
        }
    }
    Write-Host 'RDP enabled with NLA and TLS. The new firewall rule allows only 10.0.2.2 on TCP 3389.'
    Write-Host 'No credentials or user permissions were changed. Existing firewall rules remain unchanged.'
    Write-Host 'The Mac client must verify the certificate pin and NLA/TLS negotiation. Run this script with -Undo to restore the previous state.'
} catch {
    $failure = $_
    try {
        Restore-Setup $state
        Remove-Item -LiteralPath $backup
    } catch {
        Write-Warning ('Automatic rollback could not finish. Keep the backup and run -Undo locally: ' + $_.Exception.Message)
    }
    throw $failure
}
