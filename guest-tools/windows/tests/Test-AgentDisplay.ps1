#Requires -Version 5.1
# Fixtures only: never call Windows display APIs, change modes, or read registry.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'PerpendicularAgent.Core.ps1')
$script:Checks = 0
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message }; $script:Checks++ }
function Assert-Error {
    param([scriptblock]$Action, [string]$Code)
    try { & $Action | Out-Null }
    catch { if ((Get-AgentErrorCode $_.Exception) -ceq $Code) { $script:Checks++; return }; throw }
    throw ('Expected error: ' + $Code)
}
function Request {
    param([string]$JSON)
    $bytes = Invoke-AgentRequest (ConvertFrom-AgentRequest ($script:StrictUTF8.GetBytes($JSON)))
    return ConvertFrom-Json -InputObject ($script:StrictUTF8.GetString($bytes))
}

# Compile the actual P/Invoke declarations without invoking them. Explicit
# Unicode layouts must be correct on ARM64 and under Windows PowerShell 5.1.
Initialize-AgentDisplayNative
$sizes = [Perpendicular.Guest.DisplayNative]::StructureSizes()
Assert-True ($sizes[0] -eq 220 -and $sizes[1] -eq 840) 'DEVMODEW/DISPLAY_DEVICEW layout changed.'
Assert-True ([Perpendicular.Guest.DisplayNative]::Allowed(3840, 2160)) 'The 4K budget boundary was rejected.'
foreach ($dimensions in @(@(0,600), @(639,600), @(800,479), @(3841,2160), @(1920,2161), @([int]::MaxValue,[int]::MaxValue))) {
    Assert-True (-not [Perpendicular.Guest.DisplayNative]::Allowed($dimensions[0], $dimensions[1])) 'Native pixel validation accepted an invalid dimension.'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    $unsupported = Get-AgentDisplayStatus
    Assert-True (-not $unsupported.can_resize -and $null -eq $unsupported.current) 'A non-Windows fixture must not load Windows display or registry APIs.'
}

$script:NativeCalls = 0; $script:StatusCalls = 0; $script:Tick = 10000; $script:NativeOutcome = 'success'
$script:Current = @{ width = 800; height = 600; dpi = $null; device_name = '\\.\DISPLAY1'; adapter = 'Fixture fixed RAM framebuffer' }
$script:Modes = @(@{width=800;height=600}); $script:CanResize = $false
function Get-AgentDisplayNativeStatus {
    $script:StatusCalls++
    return @{ can_resize = $script:CanResize; reason = 'Fixture driver modes'; current = $script:Current
        modes = $script:Modes; dpi_change_supported = $false }
}
function Get-AgentDisplayTick { return $script:Tick }
function Invoke-AgentDisplayNativeResize {
    param([int]$Width, [int]$Height)
    $script:NativeCalls++
    if ($script:NativeOutcome -eq 'throw') { throw 'Fixture native failure' }
    if ($script:NativeOutcome -eq 'mismatch') {
        return @{ applied=$true;changed=$true;code='resized';reason=$null;actual=$script:Current }
    }
    $script:Current = @{ width=$Width;height=$Height;dpi=144;device_name='\\.\DISPLAY1';adapter='Fixture variable-mode driver' }
    return @{ applied=$true;changed=$true;code='resized';reason=$null;actual=$script:Current }
}

$status = Request '{"id":1,"op":"display.status","params":{}}'
Assert-True ($status.ok -and -not $status.result.can_resize -and $status.result.current.width -eq 800) 'Fixed driver status lost the measured mode.'
$fixed = Set-AgentDisplay 1280 720 192
Assert-True (-not $fixed.applied -and $fixed.actual.width -eq 800 -and $script:NativeCalls -eq 0) 'Unsupported driver pretended to resize.'
$same = Set-AgentDisplay 800 600 192
Assert-True ($same.applied -and -not $same.changed -and $same.code -ceq 'already_current' -and -not $same.dpi_changed) 'An existing fixed mode should be a measured no-op, without DPI change.'
foreach ($values in @(@($true,600,96), @(800.5,600,96), @('800',600,96), @(800,600,95), @(800,600,289), @([long]::MaxValue,600,96))) {
    $before = $script:StatusCalls
    Assert-Error { Set-AgentDisplay $values[0] $values[1] $values[2] } 'invalid_display_request'
    Assert-True ($script:StatusCalls -eq $before) 'Invalid parameters contacted the display provider.'
}
$extra = Request '{"id":2,"op":"display.resize","params":{"width":1280,"height":720,"host_dpi":96,"device":"untrusted"}}'
Assert-True (-not $extra.ok -and $extra.error.code -ceq 'invalid_request') 'A host-provided adapter name was accepted.'

$script:CanResize = $true
$script:Modes = @(@{width=800;height=600},@{width=1280;height=720},@{width=1920;height=1080})
$unknown = Set-AgentDisplay 1366 768 192
Assert-True (-not $unknown.applied -and $script:NativeCalls -eq 0) 'A custom non-enumerated resolution reached mode setting.'
$good = Request '{"id":3,"op":"display.resize","params":{"width":1280,"height":720,"host_dpi":192}}'
Assert-True ($good.ok -and $good.result.applied -and $good.result.changed -and $good.result.actual.width -eq 1280) 'A supported measured resize was not acknowledged.'
Assert-True ($good.result.requested.host_dpi -eq 192 -and $good.result.actual.dpi -eq 144 -and -not $good.result.dpi_changed) 'Host DPI must not masquerade as a guest scaling change.'
$script:Tick = 10100
$throttled = Set-AgentDisplay 1920 1080 192
Assert-True (-not $throttled.applied -and $throttled.code -ceq 'display_resize_throttled' -and $throttled.retry_after_ms -eq 650 -and $script:NativeCalls -eq 1) 'Rapid resize bypassed the monotonic rate limit.'
$script:Tick = 10800; $script:NativeOutcome = 'mismatch'
$mismatch = Set-AgentDisplay 1920 1080 192
Assert-True (-not $mismatch.applied -and -not $mismatch.changed -and $mismatch.code -ceq 'display_not_applied' -and $mismatch.actual.width -eq 1280) 'A driver acknowledgement without the actual requested resolution was treated as success.'
$script:Tick = 11600; $script:NativeOutcome = 'throw'
$failure = Set-AgentDisplay 1920 1080 192
Assert-True (-not $failure.applied -and $failure.code -ceq 'display_change_failed' -and $failure.actual.width -eq 1280) 'Native failure hid the observed current mode.'
Write-Output ('PASS: ' + $script:Checks + ' display checks; real C# layout/validation compilation and fixture-only mode, DPI, throttle, mismatch and error handling. No Windows API, registry, guest port or live display accessed.')
