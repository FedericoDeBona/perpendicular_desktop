param(
    [string]$PackagePath = (Join-Path $PSScriptRoot 'drivers'),
    [string]$OutputPath = (Join-Path $env:USERPROFILE ('Downloads\perpendicular-3d-baseline-' + [guid]::NewGuid().ToString() + '.json'))
)
$ErrorActionPreference = 'Stop'

# Read-only guest inspection. This never installs drivers or changes policy.
function Observe([scriptblock]$Read) {
    try { return [ordered]@{ observed = $true; value = (& $Read); error = $null } }
    catch { return [ordered]@{ observed = $false; value = $null; error = $_.Exception.Message } }
}
function Read-RegistryValue([string]$Path, [string]$Name) {
    try { $key = Get-Item -LiteralPath $Path -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] {
        return @{ key_exists = $false; exists = $false; value = $null; kind = $null }
    }
    $exists = @($key.GetValueNames()) -contains $Name
    return @{
        key_exists = $true; exists = $exists
        value = $(if ($exists) { $key.GetValue($Name) } else { $null })
        kind = $(if ($exists) { $key.GetValueKind($Name).ToString() } else { $null })
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package.json') -Raw | ConvertFrom-Json
if ($manifest.schema_version -ne 1) { throw 'Unsupported package manifest' }
$members = @($manifest.members.PSObject.Properties)
if ($members.Count -ne 11) { throw 'Expected the eleven reviewed release members' }
$packages = @()
foreach ($member in $members) {
    if ($member.Name -notmatch '^[A-Za-z0-9_.]+$') { throw 'Invalid package member name' }
    $path = Join-Path $PackagePath $member.Name
    $file = Get-Item -LiteralPath $path
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Ordinary package files required' }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $member.Value) { throw ('Reviewed package hash mismatch: ' + $member.Name) }
    $signature = $null
    if ($file.Extension -in @('.sys', '.dll', '.exe', '.cat')) {
        $signature = Observe {
            $sig = Get-AuthenticodeSignature -LiteralPath $path
            [ordered]@{
                status = $sig.Status.ToString(); message = $sig.StatusMessage
                signer = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null })
                signer_thumbprint = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { $null })
            }
        }
    }
    $packages += [ordered]@{ name = $member.Name; sha256 = $hash; authenticode = $signature }
}
$bcd = Observe {
    $lines = & "$env:SystemRoot\System32\bcdedit.exe" /enum '{current}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($lines -join "`n") }
    $lines -join "`n"
}
$report = [ordered]@{
    schema_version = 1; captured_at = [DateTime]::UtcNow.ToString('o')
    phase = 'before-driver-install'; read_only = $true
    os = Observe { Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture }
    administrator = Observe { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    secure_boot = Observe { Confirm-SecureBootUEFI }
    tpm = Observe { Get-Tpm | Select-Object TpmPresent, TpmReady, TpmEnabled, TpmActivated, TpmOwned, RestartPending }
    device_guard = Observe { Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard | Select-Object VirtualizationBasedSecurityStatus, SecurityServicesConfigured, SecurityServicesRunning, CodeIntegrityPolicyEnforcementStatus, UsermodeCodeIntegrityPolicyEnforcementStatus }
    bcd_current = $bcd
    graphics_registry = [ordered]@{
        TdrDebugMode = Observe { Read-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'TdrDebugMode' }
        EnablePreemption = Observe { Read-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler' 'EnablePreemption' }
    }
    video_controllers = Observe { @(Get-CimInstance Win32_VideoController | Select-Object Name, PNPDeviceID, Status, ConfigManagerErrorCode, DriverVersion, CurrentHorizontalResolution, CurrentVerticalResolution) }
    display_drivers = Observe { @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'" | Select-Object DeviceName, DeviceID, InfName, DriverVersion, IsSigned, Signer) }
    graphics_services = Observe { @(Get-CimInstance Win32_Service -Filter "Name='vgpusrv'" | Select-Object Name, State, StartMode, StartName, PathName) }
    package = $packages
    limitations = @(
        'Authenticode status is not kernel-mode catalog policy verification or driver-load proof.',
        'An unreadable field is unknown, never a verified disabled security feature.',
        'No driver installation, certificate import, BCD, registry or service mutation is performed.',
        'Installing the unchanged release requests automatic vgpusrv plus global TdrDebugMode=1 and EnablePreemption=0.'
    )
}
$bytes = [Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 12))
$stream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
Write-Output ('Baseline saved: ' + $OutputPath)
Write-Output ('Package hashes verified: ' + $packages.Count)
Write-Output ('Secure Boot observed: ' + $report.secure_boot.observed + '; value: ' + $report.secure_boot.value)
Write-Output 'No driver or security settings were changed.'
