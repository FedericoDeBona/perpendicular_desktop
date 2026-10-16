# SPDX-License-Identifier: MIT
# Explicit, independent diagnostic; never installs a driver or changes policy.
[CmdletBinding()]
param(
    [ValidateSet('Device', 'Scene')][string]$Mode = 'Device',
    [switch]$Exclusive,
    [ValidateRange(1, 600)][int]$Frames = 180,
    [ValidateRange(1, 30)][int]$Seconds = 10,
    [string]$ReportPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# ValidateSet accepts all casings; pass the canonical labels to the C# API too.
$Mode = if ($Mode -ieq 'Device') { 'Device' } else { 'Scene' }
if ($Exclusive -and $Mode -ne 'Scene') { throw '-Exclusive requires -Mode Scene.' }
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ('Perpendicular-D3D11-' + [Guid]::NewGuid().ToString('N') + '.json')
}
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
if (Test-Path -LiteralPath $ReportPath) { throw 'Choose a new report file; existing output is never overwritten.' }
$source = Join-Path $PSScriptRoot 'D3D11Probe.cs'
$compile = @{ TypeDefinition = [IO.File]::ReadAllText($source); Language = 'CSharp' }
if ((Get-Command Add-Type).Parameters.ContainsKey('CompilerOptions')) {
    $compile.CompilerOptions = @('/langversion:5')
} else {
    # Windows PowerShell 5.1 exposes CodeDom CompilerParameters, not the
    # PowerShell 7 CompilerOptions parameter.
    $compiler = New-Object System.CodeDom.Compiler.CompilerParameters
    $compiler.GenerateInMemory = $true
    $compiler.CompilerOptions = '/langversion:5'
    [void]$compiler.ReferencedAssemblies.Add('System.dll')
    $compile.CompilerParameters = $compiler
}
Add-Type @compile
$report = [Perpendicular3D.Probe]::Run($Mode, [bool]$Exclusive, $Frames, $Seconds)
$payload = [ordered]@{
    timestamp_utc = [DateTime]::UtcNow.ToString('o')
    powershell_version = $PSVersionTable.PSVersion.ToString()
    source_sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    launcher_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    probe = $report
}
$json = $payload | ConvertTo-Json -Depth 8
$bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($json + [Environment]::NewLine)
$stream = New-Object IO.FileStream($ReportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
Write-Output $json
Write-Host ('Report: ' + $ReportPath)
if (-not $report.success) { exit 1 }
