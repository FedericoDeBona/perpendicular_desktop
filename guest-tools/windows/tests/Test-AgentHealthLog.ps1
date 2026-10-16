#Requires -Version 5.1
# Portable real-file tests; no agent, device, task or clipboard is started.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'PerpendicularAgent.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ($errors | Out-String) }
foreach ($name in @('New-AgentHealthLog', 'Get-AgentHealthFailure', 'Write-AgentHealthEvent')) {
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false))
    if ($definitions.Count -ne 1) { throw ('Missing or ambiguous logger declaration: ' + $name) }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$script:checks = 0
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('perpendicular-health-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $log = New-AgentHealthLog (Join-Path $temporary 'normal')
    $current = Join-Path $log.Directory 'agent-health.log'
    $previous = Join-Path $log.Directory 'agent-health.previous.log'
    $secret = 'PRIVATE_REQUEST_CLIPBOARD_FILE_CREDENTIAL_MESSAGE'
    $failure = New-Object ComponentModel.Win32Exception(5, $secret)
    $failure.Data['request'] = $secret; $failure.Data['AgentCode'] = $secret
    Write-AgentHealthEvent $log 'starting' -Timestamp 0
    Write-AgentHealthEvent $log 'native_init' $failure -Timestamp 0 -Fatal
    $lines = [IO.File]::ReadAllLines($current)
    Assert-True ($lines.Length -eq 2) 'Startup and fatal events were not retained.'
    $fatal = $lines[1] | ConvertFrom-Json
    Assert-True ($fatal.schema -eq 1 -and $fatal.stage -ceq 'native_init' -and $fatal.event -ceq 'fatal' -and $fatal.code -ceq 'win32_error' -and $fatal.win32 -eq 5) 'Fatal native error lost its stage or numeric error.'
    Assert-True ($fatal.hresult -cmatch '^[0-9A-F]{8}$') 'HRESULT was not a bounded numeric value.'
    Assert-True (-not [IO.File]::ReadAllText($current).Contains($secret)) 'Exception message leaked.'
    $wrapped = New-Object InvalidOperationException($secret, $failure)
    Assert-True ((Get-AgentHealthFailure $wrapped).win32 -eq 5) 'Wrapped Win32 error was not classified.'
    foreach ($case in @(
        @((New-Object IO.EndOfStreamException($secret)), 'channel_eof'),
        @((New-Object IO.InvalidDataException($secret)), 'invalid_frame'),
        @((New-Object Text.DecoderFallbackException($secret)), 'invalid_utf8'),
        @((New-Object IO.FileNotFoundException($secret)), 'file_missing'),
        @((New-Object InvalidOperationException($secret)), 'operation_failed')
    )) { Assert-True ((Get-AgentHealthFailure $case[0]).code -ceq $case[1]) 'Failure classification mismatch.' }
    $before = (Get-Item -LiteralPath $current).Length
    Write-AgentHealthEvent $log $secret $failure -Timestamp 0
    Assert-True ((Get-Item -LiteralPath $current).Length -eq $before) 'Unreviewed stage text was admitted.'

    foreach ($stage in @('channel_open', 'channel_request', 'channel_reset')) {
        Write-AgentHealthEvent $log $stage $failure -Timestamp 0
        for ($i = 1; $i -le 500; $i++) { Write-AgentHealthEvent $log $stage $failure -Timestamp $i }
        $tick = 60L * [Diagnostics.Stopwatch]::Frequency
        Write-AgentHealthEvent $log $stage $failure -Timestamp $tick
        $records = @([IO.File]::ReadAllLines($current) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.stage -ceq $stage })
        Assert-True ($records.Count -eq 2 -and $records[1].suppressed -eq 500) 'A reconnect/request storm escaped the one-per-minute category limit.'
    }
    Write-AgentHealthEvent $log 'channel_reset' $failure -Timestamp $tick -Fatal
    $last = [IO.File]::ReadAllLines($current)[-1] | ConvertFrom-Json
    Assert-True ($last.event -ceq 'fatal') 'A terminating channel failure was hidden by normal rate limiting.'

    for ($i = 0; $i -lt 700; $i++) { Write-AgentHealthEvent $log 'starting' -Timestamp $i }
    Assert-True ([IO.File]::Exists($previous)) 'The log did not rotate.'
    foreach ($file in @($current, $previous)) {
        Assert-True ((Get-Item -LiteralPath $file).Length -le 65536) 'Rotated file exceeded 64 KiB.'
        foreach ($line in [IO.File]::ReadAllLines($file)) { [void]($line | ConvertFrom-Json) }
    }
    Assert-True (@(Get-ChildItem -LiteralPath $log.Directory -File).Count -eq 2) 'Rotation created unbounded extra files.'
    [IO.File]::WriteAllBytes($current, (New-Object byte[] 70000))
    [IO.File]::WriteAllBytes($previous, (New-Object byte[] 80000))
    Write-AgentHealthEvent $log 'starting' -Timestamp 0
    Assert-True ((Get-Item $current).Length -le 65536 -and (Get-Item $previous).Length -le 65536) 'Pre-existing oversized diagnostic files were copied or retained unbounded.'

    $before = (Get-Item $current).Length
    $lock = New-Object IO.FileStream($current, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { Write-AgentHealthEvent $log 'starting' -Timestamp 0 } finally { $lock.Dispose() }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Assert-True ((Get-Item $current).Length -eq $before) 'Windows exclusive-writer contention changed the active file.'
    } else {
        # Unix does not implement Windows FileShare.Read write exclusion.
        Assert-True ((Get-Item $current).Length -le 65536) 'Portable sharing-path exercise escaped the file bound.'
    }
    $blocked = Join-Path $temporary 'not-a-directory'; [IO.File]::WriteAllText($blocked, 'fixture')
    Write-AgentHealthEvent (New-AgentHealthLog $blocked) 'starting' -Timestamp 0
    Assert-True ([IO.File]::ReadAllText($blocked) -ceq 'fixture') 'Logger failure escaped or modified an unrelated file.'

    # Exercise the real top-level startup/catch before any platform/native call.
    # Only the fixed log destination is replaced in an owned disposable copy.
    $startup = Join-Path $temporary 'startup'; [void][IO.Directory]::CreateDirectory($startup)
    $destination = Join-Path $startup 'health'
    $source = [IO.File]::ReadAllText($path)
    $original = "New-AgentHealthLog (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Perpendicular Desktop/Guest Agent')"
    Assert-True ($source.Contains($original)) 'The startup fixture could not isolate its log destination.'
    $replacement = "New-AgentHealthLog '" + $destination.Replace("'", "''") + "'"
    [IO.File]::WriteAllText((Join-Path $startup 'PerpendicularAgent.ps1'), $source.Replace($original, $replacement))
    [IO.File]::WriteAllText((Join-Path $startup 'PerpendicularAgent.Core.ps1'), ("throw '" + $secret + "'"))
    $hostPath = (Get-Process -Id $PID).Path
    $output = & $hostPath -NoProfile -File (Join-Path $startup 'PerpendicularAgent.ps1') 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'The failing startup fixture unexpectedly succeeded.'
    $text = [IO.File]::ReadAllText((Join-Path $destination 'agent-health.log'))
    $records = @($text -split "`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($records | Where-Object { $_.stage -ceq 'core_load' -and $_.event -ceq 'fatal' }).Count -eq 1) 'A failure before the port retry loop was not retained.'
    Assert-True (-not $text.Contains($secret)) 'The real startup error message leaked into the health log.'
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
Write-Output ("Agent health log checks passed: $script:checks. Windows startup/task/device behavior is not verified by this portable fixture.")
