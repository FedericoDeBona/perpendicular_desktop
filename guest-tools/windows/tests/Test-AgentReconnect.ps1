#Requires -Version 5.1
# Execute the production retry/final-cleanup blocks with in-memory fault streams.
# No agent entry point, native device, task, clipboard or Windows identity API.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'PerpendicularAgent.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ($errors | Out-String) }
foreach ($name in @('New-AgentHealthLog', 'Get-AgentHealthFailure', 'Write-AgentHealthEvent', 'Close-AgentPort')) {
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false))
    if ($definitions.Count -ne 1) { throw ('Missing or ambiguous production declaration: ' + $name) }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$loops = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.WhileStatementAst] -and $node.Extent.Text.Contains('Close-AgentPort -Port $port -Health $health') }, $false))
if ($loops.Count -ne 1) { throw 'The unique production channel retry loop was not found.' }
$loopSource = $loops[0].Extent.Text
$retry = [scriptblock]::Create($loopSource)
$legacySource = $loopSource.Replace('Close-AgentPort -Port $port -Health $health', 'if ($null -ne $port) { $port.Dispose() }')
if ($legacySource -ceq $loopSource) { throw 'The causal pre-fix close path was not reconstructed.' }
$legacy = [scriptblock]::Create($legacySource)
$outer = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
if ($outer.Count -ne 1 -or $null -eq $outer[0].Finally) { throw 'The production final cleanup was not found.' }
$finalCleanup = [scriptblock]::Create((@($outer[0].Finally.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"))

# C# 5 syntax and the Stream surface available in Windows PowerShell 5.1/.NET4.
# These are inert fixture types, not the production P/Invoke initializer.
Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace Perpendicular.Guest {
    public static class Native {
        public static int Opens, Reads, Closes, Writes, Flushes;
        public static bool FailRead, FailClose, FailOpen;
        public static void Reset(bool read, bool close, bool open) {
            Opens = Reads = Closes = Writes = Flushes = 0;
            FailRead = read; FailClose = close; FailOpen = open;
        }
        public static Stream OpenAgentPort() {
            int attempt = ++Opens;
            if (attempt == 1 && FailOpen) throw Failure();
            return new FaultStream(attempt);
        }
        public static IOException Failure() {
            return new IOException("PRIVATE_CHANNEL_EXCEPTION_DO_NOT_LOG", unchecked((int)0x8007022A));
        }
    }
    public sealed class FaultStream : Stream {
        private readonly int attempt;
        private bool read, disposed;
        public FaultStream(int attempt) { this.attempt = attempt; }
        public override bool CanRead { get { return !disposed; } }
        public override bool CanWrite { get { return !disposed; } }
        public override bool CanSeek { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override int Read(byte[] buffer, int offset, int count) {
            Native.Reads++;
            if (disposed) throw new ObjectDisposedException("fixture");
            if (read) return 0;
            read = true;
            if (attempt == 1 && Native.FailRead) throw Native.Failure();
            buffer[offset] = 123; buffer[offset + 1] = 125;
            return 2;
        }
        public override void Write(byte[] buffer, int offset, int count) { Native.Writes++; }
        public override void Flush() { Native.Flushes++; }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        protected override void Dispose(bool disposing) {
            if (!disposed) {
                disposed = true; Native.Closes++;
                base.Dispose(disposing);
                if (attempt == 1 && Native.FailClose) throw Native.Failure();
            }
        }
    }
    public sealed class BoundedLineReader {
        private readonly Stream stream;
        public BoundedLineReader(Stream stream, int maximum) { this.stream = stream; }
        public byte[] ReadLine() {
            byte[] buffer = new byte[4096];
            int count = stream.Read(buffer, 0, buffer.Length);
            if (count == 0) throw new EndOfStreamException("fixture disconnected");
            Array.Resize(ref buffer, count); return buffer;
        }
    }
    public sealed class FaultMutex : IDisposable {
        public void ReleaseMutex() { throw Native.Failure(); }
        public void Dispose() { throw new InvalidOperationException("Unexpected fixture mutex disposal"); }
    }
}
'@

$script:checks = 0
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
function ConvertFrom-AgentRequest { param([byte[]]$Bytes) return [pscustomobject]@{ id = 1; op = 'status'; params = @{} } }
function Invoke-AgentRequest { param($Request) $script:responses++; return ,([byte[]]@(123, 125)) }
function Start-Sleep {
    param([int]$Seconds)
    Assert-True ($Seconds -eq 1) 'The production one-second retry interval changed.'
    $script:sleeps++
    if ($script:sleeps -ge 2) { throw [InvalidOperationException]::new('FIXTURE_COMPLETED_TWO_ITERATIONS') }
}
function Get-Records {
    param([string]$Directory)
    $file = Join-Path $Directory 'agent-health.log'
    if (-not [IO.File]::Exists($file)) { return @() }
    return @([IO.File]::ReadAllLines($file) | ForEach-Object { $_ | ConvertFrom-Json })
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('perpendicular-reconnect-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $script:MaximumRequestBytes = 1572864
    foreach ($case in @('read-and-close', 'close-only', 'read-only', 'open-only', 'healthy')) {
        [Perpendicular.Guest.Native]::Reset(($case -cin @('read-and-close', 'read-only')), ($case -cin @('read-and-close', 'close-only')), ($case -ceq 'open-only'))
        $health = New-AgentHealthLog (Join-Path $temporary $case)
        $script:sleeps = 0; $script:responses = 0
        $observed = $null
        try { . $retry } catch { $observed = $_.Exception.GetBaseException() }
        Assert-True ($null -ne $observed -and $observed.Message -ceq 'FIXTURE_COMPLETED_TWO_ITERATIONS') ('The retry loop escaped before the fixture stop: ' + $case)
        Assert-True ([Perpendicular.Guest.Native]::Opens -eq 2 -and $script:sleeps -eq 2) ('The second connection was not attempted: ' + $case)
        Assert-True ($script:responses -ge 1 -and [Perpendicular.Guest.Native]::Writes -ge 2 -and [Perpendicular.Guest.Native]::Flushes -ge 1) ('No response completed on the recovered stream: ' + $case)
        $expectedCloses = if ($case -ceq 'open-only') { 1 } else { 2 }
        Assert-True ([Perpendicular.Guest.Native]::Closes -eq $expectedCloses) ('A port was not disposed exactly once: ' + $case)
        $records = @(Get-Records $health.Directory)
        Assert-True (@($records | Where-Object { $_.event -ceq 'fatal' }).Count -eq 0) 'A recoverable channel failure was marked fatal.'
        $close = @($records | Where-Object { $_.stage -ceq 'channel_close' })
        $expectedCloseErrors = if ($case -cin @('read-and-close', 'close-only')) { 1 } else { 0 }
        Assert-True ($close.Count -eq $expectedCloseErrors) ('The close failure was not separately reported: ' + $case)
        if ($close.Count -eq 1) {
            Assert-True ($close[0].event -ceq 'error' -and $close[0].code -ceq 'io_error' -and $close[0].hresult -ceq '8007022A') 'Close error classification changed.'
        }
        $text = [IO.File]::ReadAllText((Join-Path $health.Directory 'agent-health.log'))
        Assert-True (-not $text.Contains('PRIVATE_CHANNEL_EXCEPTION_DO_NOT_LOG')) 'A private channel exception message leaked.'
        Assert-True ($null -eq $port) 'The failed stream reference survived into the retry boundary.'
    }

    # Causal regression: the same source loop and injected failures, with only
    # its old unguarded disposal restored, must terminate before reconnect.
    [Perpendicular.Guest.Native]::Reset($true, $true, $false)
    $health = New-AgentHealthLog (Join-Path $temporary 'legacy')
    $script:sleeps = 0; $script:responses = 0; $observed = $null
    try { . $legacy } catch { $observed = $_.Exception.GetBaseException() }
    Assert-True ($observed -is [IO.IOException] -and $observed.HResult.ToString('X8') -ceq '8007022A') 'The old close path did not reproduce the observed fatal I/O error.'
    Assert-True ([Perpendicular.Guest.Native]::Opens -eq 1 -and $script:sleeps -eq 0 -and $script:responses -eq 0) 'The pre-fix loop unexpectedly reconnected.'

    $health = New-AgentHealthLog (Join-Path $temporary 'close-rate')
    Close-AgentPort -Port $null -Health $health
    Assert-True (-not [IO.Directory]::Exists($health.Directory)) 'Null port close produced a spurious event.'
    $failure = [Perpendicular.Guest.Native]::Failure()
    for ($i = 0; $i -lt 1000; $i++) { Write-AgentHealthEvent $health 'channel_close' $failure -Timestamp $i }
    Write-AgentHealthEvent $health 'channel_close' $failure -Timestamp (60L * [Diagnostics.Stopwatch]::Frequency)
    $records = @(Get-Records $health.Directory)
    Assert-True ($records.Count -eq 2 -and $records[1].suppressed -eq 999) 'Repeated close errors escaped the existing one-minute log bound.'

    # Execute the actual outer-finally block: its mutex failure is intentionally
    # fatal and must not be swallowed by the port-only reconnect correction.
    $health = New-AgentHealthLog (Join-Path $temporary 'mutex')
    $ownsMutex = $true; $mutex = New-Object Perpendicular.Guest.FaultMutex
    $observed = $null
    try { . $finalCleanup } catch { $observed = $_.Exception.GetBaseException() }
    Assert-True ($observed -is [IO.IOException]) 'Intentional final mutex cleanup failure stopped propagating.'
    $records = @(Get-Records $health.Directory)
    Assert-True ($records.Count -eq 1 -and $records[0].stage -ceq 'cleanup' -and $records[0].event -ceq 'error') 'Final mutex cleanup reporting changed.'
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
Write-Output ("PASS: $script:checks reconnect fault-injection checks. Real production loop/final cleanup; memory streams only, no agent/task/device/clipboard/VM started.")
