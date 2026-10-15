#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PerpendicularAgent.Core.ps1')

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'This guest agent runs only inside Windows.'
}
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'Run the guest agent as an interactive logged-in user, not a Session 0 service.'
}
Initialize-AgentNative
Initialize-AgentClipboard

# Task Scheduler also uses IgnoreNew. The mutex protects manual starts in this
# user session while allowing a different logged-in user to own their clipboard.
$mutex = New-Object System.Threading.Mutex($false, 'Local\PerpendicularDesktopGuestAgent')
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { return }
    while ($true) {
        $port = $null
        try {
            $port = [Perpendicular.Guest.Native]::OpenAgentPort()
            $reader = New-Object Perpendicular.Guest.BoundedLineReader($port, ($script:MaximumRequestBytes - 1))
            while ($true) {
                # Decode/parse only after the raw-byte limit has been enforced.
                $line = $reader.ReadLine()
                $request = ConvertFrom-AgentRequest $line
                $response = Invoke-AgentRequest $request
                $port.Write($response, 0, $response.Length)
                $port.WriteByte(10)
                $port.Flush()
            }
        } catch {
            # Invalid framing/UTF-8/JSON has no trustworthy integer ID. Drop the
            # stream rather than emit an uncorrelated response or execute it.
            # Do not log request text, clipboard data, or file contents.
            [System.Console]::Error.WriteLine('Guest channel reset: ' + (Get-AgentErrorCode $_.Exception))
        } finally {
            if ($null -ne $port) { $port.Dispose() }
        }
        Start-Sleep -Seconds 1
    }
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
