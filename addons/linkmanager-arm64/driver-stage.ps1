# Experimental driver-only stage. No LinkManager setup, login, route/DNS edits or reboot.
[CmdletBinding()]
param([ValidateSet('Inspect','Install','Remove')][string]$Mode = 'Inspect')
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'candidate.json') -Raw | ConvertFrom-Json
$driver = Join-Path $PSScriptRoot 'driver-arm64'
$statePath = Join-Path $PSScriptRoot 'driver-state.json'
foreach ($name in @('OemVista.inf','tap0901.cat','tap0901.sys','devcon.exe')) {
    $path = Join-Path $driver $name
    $expected = $manifest.files.PSObject.Properties['driver-arm64/' + $name].Value.sha256
    if (!$expected -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) {
        throw "Candidate file hash mismatch: $name"
    }
}
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64' -or
    [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'Arm64') {
    throw 'Use native ARM64 PowerShell on Windows ARM64.'
}
function Get-TapDevices {
    @(Get-CimInstance Win32_PnPEntity | Where-Object {
        @($_.HardwareID) -contains 'tap0901' -or @($_.HardwareID) -contains 'root\tap0901'
    } | Select-Object PNPDeviceID, Name, ConfigManagerErrorCode)
}
# This trust check is still not proof that the kernel accepted the package.
foreach ($name in @('tap0901.cat','tap0901.sys')) {
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $driver $name)
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Windows Hardware Compatibility Publisher') {
        throw "Windows signature validation failed: $name ($($signature.Status))"
    }
}
$devices = @(Get-TapDevices)
if ($Mode -eq 'Inspect') {
    $devices | Format-Table
    Write-Output 'Pinned ARM64 files and Windows Authenticode trust passed. No changes made.'
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated.' }
if (!(Confirm-SecureBootUEFI)) { throw 'Secure Boot must remain enabled.' }
if (-not ('LMCodeIntegrity' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LMCodeIntegrity {
    [StructLayout(LayoutKind.Sequential)] public struct Info { public uint Length; public uint Options; }
    [DllImport("ntdll.dll")] public static extern int NtQuerySystemInformation(
        int cls, ref Info info, int size, out int returned);
    public static uint Options() {
        var i = new Info { Length = 8 }; int n;
        int status = NtQuerySystemInformation(103, ref i, 8, out n);
        if (status != 0) throw new Exception("Code Integrity query: " + status);
        return i.Options;
    }
}
'@
}
$ci = [LMCodeIntegrity]::Options()
if (($ci -band 1) -eq 0 -or ($ci -band 2) -ne 0) {
    throw 'Code Integrity must be enabled and TestSigning disabled.'
}
$devcon = Join-Path $driver 'devcon.exe'
$machine = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
if ($Mode -eq 'Install') {
    if (Test-Path -LiteralPath $statePath) { throw 'Existing stage state: inspect/recover it before installing.' }
    if ($devices.Count -ne 0) { throw 'Existing TAP0901 adapter: refusing to affect another VPN.' }
    # Also refuse phantom TAP devices, which DevCon update could otherwise touch.
    $phantoms = @(Get-PnpDevice -Class Net | Where-Object {
        $ids = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data
        $ids -contains 'tap0901' -or $ids -contains 'root\tap0901'
    })
    if ($phantoms.Count -ne 0) { throw 'Existing/phantom TAP0901 device: refusing installation.' }
    $state = [ordered]@{ Machine = $machine; Phase = 'install-started'; Devices = @();
        SecureBoot = $true; CodeIntegrity = $ci; DriverHash = $manifest.files.'driver-arm64/tap0901.sys'.sha256;
        RoutesBefore = @(Get-NetRoute | Select-Object DestinationPrefix, NextHop, InterfaceIndex, RouteMetric);
        DnsBefore = @(Get-DnsClientServerAddress | Select-Object InterfaceIndex, AddressFamily, ServerAddresses) }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    $code = -1
    try {
        & $devcon install (Join-Path $driver 'OemVista.inf') 'tap0901'
        $code = $LASTEXITCODE
    } finally {
        $state.Devices = @(Get-TapDevices)
        $state.Phase = 'install-returned'
        $state['ExitCode'] = $code
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    }
    if ($code -notin @(0,1)) { throw "DevCon failed ($code). State saved for recovery; no automatic reboot." }
    if ($state.Devices.Count -ne 1) { throw 'Expected one new TAP adapter. Inspect saved state.' }
    if ($code -eq 1) { throw 'Driver requests reboot. No reboot performed; runtime verification remains pending.' }
    if ($state.Devices[0].ConfigManagerErrorCode -ne 0) { throw 'Adapter reports a PnP problem; inspect state.' }
    Write-Output 'Driver installed, one healthy adapter observed. TAP I/O and LinkManager remain unverified.'
} else {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.Machine -ne $machine -or $state.DriverHash -ne $manifest.files.'driver-arm64/tap0901.sys'.sha256) {
        throw 'State does not belong to this host/candidate.'
    }
    if (@($state.Devices).Count -ne 1) { throw 'Ambiguous recovery state: manual inspection required.' }
    $instance = $state.Devices[0].PNPDeviceID
    if ($instance -notmatch '^ROOT\\[A-Z0-9_]+\\[A-Z0-9_]+$') { throw 'Invalid device instance ID in state.' }
    $found = @($devices | Where-Object { $_.PNPDeviceID -eq $instance })
    if ($found.Count -ne 1) { throw 'Recorded TAP device absent or changed; refusing removal.' }
    & $devcon remove ('@' + $instance)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Remove result $code. State preserved; no automatic reboot." }
    if (@(Get-TapDevices | Where-Object { $_.PNPDeviceID -eq $instance }).Count -ne 0) {
        throw 'Device still present. State preserved.'
    }
    $state.Phase = 'device-removed'
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Output 'Recorded adapter removed. Driver Store package retained; verify ordinary network separately.'
}
