#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-AgentHealthLog {
    param([string]$Directory)
    return @{ Directory = $Directory; MaximumBytes = 65536; Next = @{}; Suppressed = @{} }
}

function Get-AgentHealthFailure {
    param([System.Exception]$Exception)
    $code = 'operation_failed'; $win32 = $null; $hresult = $null
    # Never serialize exception text, Data, ErrorRecord, request or command line.
    for ($depth = 0; $null -ne $Exception -and $depth -lt 8; $depth++) {
        $hresult = $Exception.HResult.ToString('X8')
        if ($Exception -is [System.ComponentModel.Win32Exception]) { $code = 'win32_error'; $win32 = $Exception.NativeErrorCode; break }
        if ($Exception -is [System.IO.EndOfStreamException]) { $code = 'channel_eof' }
        elseif ($Exception -is [System.IO.InvalidDataException]) { $code = 'invalid_frame' }
        elseif ($Exception -is [System.Text.DecoderFallbackException]) { $code = 'invalid_utf8' }
        elseif ($Exception -is [System.UnauthorizedAccessException]) { $code = 'access_denied' }
        elseif ($Exception -is [System.IO.FileNotFoundException] -or $Exception -is [System.IO.DirectoryNotFoundException]) { $code = 'file_missing' }
        elseif ($Exception -is [System.IO.IOException]) { $code = 'io_error' }
        elseif ($Exception -is [System.Management.Automation.ParseException]) { $code = 'script_parse' }
        $Exception = $Exception.InnerException
    }
    return @{ code = $code; win32 = $win32; hresult = $hresult }
}

function Write-AgentHealthEvent {
    param($Log, [string]$Stage, [System.Exception]$Exception,
          [long]$Timestamp = [Diagnostics.Stopwatch]::GetTimestamp(), [switch]$Fatal)
    try {
        if ($null -eq $Log -or @('starting', 'core_load', 'platform_check', 'session_check', 'native_init', 'clipboard_init',
            'mutex_init', 'mutex_wait', 'duplicate_instance', 'channel_open', 'channel_request', 'channel_reset', 'cleanup', 'stopped') -cnotcontains $Stage) { return }
        $omitted = 0
        if (-not $Fatal -and @('channel_open', 'channel_request', 'channel_reset') -ccontains $Stage) {
            if ($Log.Next.ContainsKey($Stage) -and $Timestamp -lt $Log.Next[$Stage]) {
                $Log.Suppressed[$Stage] = [Math]::Min([long][int]::MaxValue, [long]$Log.Suppressed[$Stage] + 1)
                return
            }
            if ($Log.Suppressed.ContainsKey($Stage)) { $omitted = $Log.Suppressed[$Stage] }
            $Log.Suppressed[$Stage] = 0
            $Log.Next[$Stage] = $Timestamp + 60L * [Diagnostics.Stopwatch]::Frequency
        }
        $failure = if ($null -ne $Exception) { Get-AgentHealthFailure $Exception } else { @{ code = 'ok'; win32 = $null; hresult = $null } }
        $event = if ($Fatal) { 'fatal' } elseif ($null -ne $Exception) { 'error' } else { 'ok' }
        $record = [ordered]@{ schema = 1; utc = [DateTime]::UtcNow.ToString('o'); pid = $PID; stage = $Stage; event = $event
            code = $failure.code; win32 = $failure.win32; hresult = $failure.hresult; suppressed = $omitted }
        $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes((ConvertTo-Json -InputObject $record -Compress) + "`n")
        if ($bytes.Length -gt 1024) { return }
        [void][IO.Directory]::CreateDirectory($Log.Directory)
        $current = [IO.Path]::Combine($Log.Directory, 'agent-health.log')
        $previous = [IO.Path]::Combine($Log.Directory, 'agent-health.previous.log')
        foreach ($path in @($Log.Directory, $current, $previous)) {
            if (([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) -and
                (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return }
        }
        # Windows FileShare.Read excludes another writer during append/rotation.
        # Another writer's sharing error simply drops this record.
        $stream = New-Object IO.FileStream($current, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try {
            if ([IO.File]::Exists($previous) -and (New-Object IO.FileInfo($previous)).Length -gt $Log.MaximumBytes) {
                $old = New-Object IO.FileStream($previous, [IO.FileMode]::Truncate, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                $old.Dispose()
            }
            if ($stream.Length -gt $Log.MaximumBytes) { $stream.SetLength(0) }
            if ($stream.Length + $bytes.Length -gt $Log.MaximumBytes) {
                $old = New-Object IO.FileStream($previous, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                try { $stream.Position = 0; $stream.CopyTo($old, 4096); $old.Flush() } finally { $old.Dispose() }
                $stream.SetLength(0)
            }
            $stream.Position = $stream.Length
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        } finally { $stream.Dispose() }
    } catch {
        # Diagnostics are best-effort and must never stop or delay a reconnect
        # by throwing. No fallback path, permissions change or message dump.
    }
}

$health = $null; $stage = 'starting'; $mutex = $null; $ownsMutex = $false
try {
    $health = New-AgentHealthLog (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Perpendicular Desktop/Guest Agent')
    Write-AgentHealthEvent $health $stage
    $stage = 'core_load'
    . (Join-Path $PSScriptRoot 'PerpendicularAgent.Core.ps1')
    Write-AgentHealthEvent $health $stage
    $stage = 'platform_check'
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This guest agent runs only inside Windows.' }
    $stage = 'session_check'
    if ([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { throw 'Run the guest agent as an interactive logged-in user, not a Session 0 service.' }
    $stage = 'native_init'; Initialize-AgentNative; Write-AgentHealthEvent $health $stage
    $stage = 'clipboard_init'; Initialize-AgentClipboard; Write-AgentHealthEvent $health $stage
    # Task Scheduler also uses IgnoreNew. Preserve the per-session singleton.
    $stage = 'mutex_init'
    $mutex = New-Object System.Threading.Mutex($false, 'Local\PerpendicularDesktopGuestAgent')
    $stage = 'mutex_wait'
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { Write-AgentHealthEvent $health 'duplicate_instance'; return }
    Write-AgentHealthEvent $health $stage
    while ($true) {
        $port = $null
        try {
            $stage = 'channel_open'
            $port = [Perpendicular.Guest.Native]::OpenAgentPort()
            Write-AgentHealthEvent $health $stage
            $reader = New-Object Perpendicular.Guest.BoundedLineReader($port, ($script:MaximumRequestBytes - 1))
            while ($true) {
                # Decode/parse only after the raw-byte limit has been enforced.
                $stage = 'channel_request'
                $line = $reader.ReadLine()
                $request = ConvertFrom-AgentRequest $line
                $response = Invoke-AgentRequest $request
                $port.Write($response, 0, $response.Length); $port.WriteByte(10); $port.Flush()
                Write-AgentHealthEvent $health $stage
            }
        } catch {
            # No request/response data or exception messages are retained.
            Write-AgentHealthEvent $health 'channel_reset' $_.Exception
        } finally {
            if ($null -ne $port) { $port.Dispose() }
        }
        Start-Sleep -Seconds 1
    }
} catch {
    Write-AgentHealthEvent $health $stage $_.Exception -Fatal
    throw
} finally {
    try {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
        Write-AgentHealthEvent $health 'stopped'
    } catch { Write-AgentHealthEvent $health 'cleanup' $_.Exception; throw }
}
