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
