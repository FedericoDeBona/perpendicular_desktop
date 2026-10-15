#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-PerpendicularGuestTools.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw ($parseErrors | Out-String) }
# Import pure validation functions, not the Windows GUI, UAC helper or agent.
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
$script:checks = 0
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; $script:checks++ }
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-True $rejected $Message
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('perpendicular-installer-check-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $packages = @(Get-FixedDriverPackages -MediaRoot $root)
    Assert-True ($packages.Count -eq 2) 'Only the two required driver packages may be selected.'
    Assert-True ($packages[0].Inf -eq (Join-Path $root 'Drivers/NetKVM/w11/ARM64/netkvm.inf')) 'Network path must be fixed to the Windows 11 ARM64 package.'
    Assert-True ($packages[1].Inf -eq (Join-Path $root 'Drivers/vioserial/w11/ARM64/vioser.inf')) 'Serial path must use the real vioserial package directory.'
    foreach ($package in $packages) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($package.Inf))
        [IO.File]::WriteAllText($package.Inf, ('[Version]' + "`nCatalogFile=" + [IO.Path]::GetFileName($package.Catalog) + "`n[Vendor.NTARM64]`n"))
        [IO.File]::WriteAllBytes($package.Catalog, [byte[]]@(1))
        $image = New-Object byte[] 128
        $image[0] = 0x4D; $image[1] = 0x5A; $image[0x3C] = 64
        $image[64] = 0x50; $image[65] = 0x45; $image[68] = 0x64; $image[69] = 0xAA
        [IO.File]::WriteAllBytes($package.Driver, $image)
    }
    $script:signatureStatus = 'Valid'
    function Get-AuthenticodeSignature {
        param([string]$LiteralPath)
        [pscustomobject]@{ Status = $script:signatureStatus; SignerCertificate = [pscustomobject]@{ Subject = 'Fixture only' } }
    }
    foreach ($package in $packages) { Assert-SignedArm64Package $package; $script:checks++ }
    $script:signatureStatus = 'NotTrusted'
    Assert-Rejected { Assert-SignedArm64Package $packages[0] } 'An untrusted catalog was accepted.'
    $script:signatureStatus = 'NotSigned'
    Assert-Rejected { Assert-SignedArm64Package $packages[0] } 'An unsigned catalog was accepted.'
    $script:signatureStatus = 'Valid'
    $originalInf = [IO.File]::ReadAllText($packages[0].Inf)
    [IO.File]::WriteAllText($packages[0].Inf, ($originalInf.Replace('netkvm.cat', 'other.cat')))
    Assert-Rejected { Assert-SignedArm64Package $packages[0] } 'An unexpected catalog name was accepted.'
    [IO.File]::WriteAllText($packages[0].Inf, ($originalInf.Replace('NTARM64', 'NTAMD64')))
    Assert-Rejected { Assert-SignedArm64Package $packages[0] } 'A non-ARM64 INF was accepted.'
    [IO.File]::WriteAllText($packages[0].Inf, $originalInf)
    $image = [IO.File]::ReadAllBytes($packages[0].Driver)
    $image[68] = 0x64; $image[69] = 0x86
    [IO.File]::WriteAllBytes($packages[0].Driver, $image)
    Assert-Rejected { Assert-SignedArm64Package $packages[0] } 'An x64 driver image was accepted.'
    [IO.File]::Delete($packages[1].Catalog)
    Assert-Rejected { Assert-SignedArm64Package $packages[1] } 'An incomplete driver package was accepted.'
    Assert-True ((Get-DriverExitResult 0).Accepted -and -not (Get-DriverExitResult 0).RestartRequired) 'Exit 0 must be accepted without a restart claim.'
    Assert-True ((Get-DriverExitResult 3010).Accepted -and (Get-DriverExitResult 3010).RestartRequired) 'Exit 3010 must preserve the restart requirement.'
    foreach ($failureCode in @(1, 5, 1223, 1641, 3011)) { Assert-True (-not (Get-DriverExitResult $failureCode).Accepted) ('Unexpected driver result accepted: ' + $failureCode) }
    $path = 'D:\GuestTools\Install-PerpendicularGuestTools.ps1'
    $driverArguments = Get-InstallerArguments -ScriptPath $path -DriverHelper
    $agentArguments = Get-InstallerArguments -ScriptPath 'D:\GuestTools\Install-PerpendicularAgent.ps1'
    Assert-True ($driverArguments.EndsWith('" -InstallDrivers')) 'Elevated child must select only the fixed driver helper.'
    Assert-True (-not $agentArguments.Contains('InstallDrivers')) 'Agent invocation must not select the elevated helper.'
    Assert-True ($driverArguments.Contains('-STA') -and $driverArguments.Contains('-File "' + $path + '"')) 'Driver helper must use the explicit script file and STA.'
    Assert-True (-not $driverArguments.Contains('-Command') -and -not $agentArguments.Contains('-Command')) 'Installer must not launch arbitrary PowerShell commands.'
    Assert-Rejected { Get-InstallerArguments -ScriptPath 'D:\bad"name.ps1' } 'A quoted script path was accepted.'
    Assert-Rejected { Get-InstallerArguments -ScriptPath "D:\bad`nname.ps1" } 'A multiline script path was accepted.'
    Assert-Rejected { Assert-InteractiveUser -Identity ([pscustomobject]@{}) -Elevated $true } 'Elevated GUI must be rejected before user tools can launch.'
    Write-Output ('PASS: ' + $script:checks + ' installer checks; fixed ARM64 package paths, catalog and PE validation, rejection paths, restart results, constrained child arguments and elevated GUI refusal. No Windows driver, scheduled task, guest port or clipboard was touched.')
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
