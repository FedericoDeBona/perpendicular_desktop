# SPDX-License-Identifier: MIT
# Pure compile/ABI/delegate checks. Never invokes a Windows DLL or graphics API.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'D3D11Probe.cs'
$compile = @{ TypeDefinition = [IO.File]::ReadAllText($source); Language = 'CSharp' }
if ((Get-Command Add-Type).Parameters.ContainsKey('CompilerOptions')) {
    $compile.CompilerOptions = @('/langversion:5')
} else {
    $compiler = New-Object System.CodeDom.Compiler.CompilerParameters
    $compiler.GenerateInMemory = $true
    $compiler.CompilerOptions = '/langversion:5'
    [void]$compiler.ReferencedAssemblies.Add('System.dll')
    $compile.CompilerParameters = $compiler
}
Add-Type @compile
foreach ($check in [Perpendicular3D.Probe]::SelfTest()) { Write-Output ('PASS: ' + $check) }
$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-D3D11Probe.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ($errors | Out-String) }
Write-Output 'PASS: PowerShell launcher parse (Windows 5.1 runtime not claimed)'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('Perpendicular-Probe-Case-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    try {
        $hostPath = (Get-Process -Id $PID).Path
        foreach ($mode in @('device', 'sCeNe', 'gEoMeTrY')) {
            $path = Join-Path $folder ($mode + '.json')
            $output = & $hostPath -NoProfile -File (Join-Path $PSScriptRoot 'Invoke-D3D11Probe.ps1') -Mode $mode -Frames 1 -Seconds 1 -ReportPath $path
            if ($LASTEXITCODE -ne 1) { throw ('Expected platform denial for launcher mode ' + $mode + ': ' + ($output | Out-String)) }
            $report = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            $expected = if ($mode -ieq 'device') { 'Device' } elseif ($mode -ieq 'scene') { 'Scene' } else { 'Geometry' }
            if ($report.probe.mode -cne $expected -or $report.probe.error_stage -ne 'platform' -or $report.probe.device_creation_succeeded -or $report.probe.scene_attempted -or $report.probe.shader_compile_attempts -ne 0 -or $report.probe.draw_attempts -ne 0) {
                throw ('Launcher did not canonicalize mode before the platform guard: ' + $mode)
            }
        }
        Write-Output 'PASS: Real fresh-process launcher accepts lowercase/mixed-case modes, writes canonical reports, reaches platform guard without native calls'
    } finally { [IO.Directory]::Delete($folder, $true) }
}
