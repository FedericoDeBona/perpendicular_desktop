#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallerScript)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-PerpendicularGuestTools.ps1'
if (-not [string]::IsNullOrEmpty($InstallerScript)) { $scriptPath = [IO.Path]::GetFullPath($InstallerScript) }
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
    Assert-True ($packages[1].Service -ceq 'VirtioSerial') 'The serial service must match AddService=VirtioSerial, not the vioser file basename.'
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
    $image[69] = 0xAA
    [IO.File]::WriteAllBytes($packages[0].Driver, $image)
    [IO.File]::Delete($packages[1].Catalog)
    Assert-Rejected { Assert-SignedArm64Package $packages[1] } 'An incomplete driver package was accepted.'
    Assert-True ((Get-DriverExitResult 0).Accepted -and -not (Get-DriverExitResult 0).RestartRequired) 'Exit 0 must be accepted without a restart claim.'
    Assert-True ((Get-DriverExitResult 3010).Accepted -and (Get-DriverExitResult 3010).RestartRequired) 'Exit 3010 must preserve the restart requirement.'
    foreach ($failureCode in @(1, 5, 259, 1223, 1641, 3011)) { Assert-True (-not (Get-DriverExitResult $failureCode).Accepted) ('Unexpected driver result accepted: ' + $failureCode) }
    $script:windowsInf = Join-Path $root 'Windows/INF'
    [void][IO.Directory]::CreateDirectory($script:windowsInf)
    function Get-WindowsInfDirectory { return $script:windowsInf }
    function Reset-InstalledDriverFixture {
        $script:cimFailure = $false
        $script:cimCalls = @()
        $id = 'PCI\VEN_1AF4&DEV_1000&SUBSYS_00011AF4\3&FIXTURE&0&08'
        $script:installedDrivers = @([pscustomobject]@{ DeviceID = $id; InfName = 'oem1.inf'; IsSigned = $true })
        $script:presentDevices = @([pscustomobject]@{ DeviceID = $id; Present = $true; ConfigManagerErrorCode = [uint32]0; Service = 'netkvm' })
        [IO.File]::Copy($packages[0].Inf, (Join-Path $script:windowsInf 'oem1.inf'), $true)
    }
    function Get-CimInstance {
        [CmdletBinding()]
        param([string]$Namespace, [string]$ClassName)
        if ($Namespace -cne 'root/cimv2') { throw 'Only the local Windows device namespace is expected.' }
        $script:cimCalls += $ClassName
        if ($script:cimFailure) { throw 'Fixture Windows device API unavailable.' }
        switch ($ClassName) {
            'Win32_PnPSignedDriver' { return $script:installedDrivers }
            'Win32_PnPEntity' { return $script:presentDevices }
            default { throw 'Unexpected Windows API request.' }
        }
    }
    Reset-InstalledDriverFixture
    $existing = Get-DriverExitResult -ExitCode 259 -Package $packages[0]
    Assert-True $existing.Accepted 'PnPUtil 259 rejected the independently verified, already-active signed package.'
    Assert-True (-not $existing.RestartRequired -and $existing.VerificationDetails.Contains('259')) 'Verified 259 must preserve its code without claiming a restart.'
    Assert-True ($script:cimCalls.Count -eq 2) 'Accepting 259 requires both independent Windows device APIs.'
    [IO.File]::Copy($packages[1].Inf, (Join-Path $script:windowsInf 'oem3.inf'), $true)
    $script:installedDrivers = @([pscustomobject]@{ DeviceID = 'PCI\VEN_1AF4&DEV_1003\FIXTURE'; InfName = 'oem3.inf'; IsSigned = $true })
    $script:presentDevices = @([pscustomobject]@{ DeviceID = 'PCI\VEN_1AF4&DEV_1003\FIXTURE'; Present = $true; ConfigManagerErrorCode = [uint32]0; Service = 'VirtioSerial' })
    Assert-True ((Get-DriverExitResult -ExitCode 259 -Package $packages[1]).Accepted) 'An already-installed serial driver uses the VirtioSerial service.'
    $script:presentDevices[0].Service = 'vioser'
    Assert-True (-not (Get-DriverExitResult -ExitCode 259 -Package $packages[1]).Accepted) 'The vioser filename is not the installed serial service.'
    foreach ($mode in @('no-driver', 'no-device', 'unsigned', 'unknown-signature', 'wrong-inf', 'changed-inf', 'wrong-device', 'not-present', 'unknown-present', 'device-error', 'unknown-error', 'string-error', 'wrong-service', 'wrong-hardware', 'unsafe-inf', 'api-failure')) {
        Reset-InstalledDriverFixture
        switch ($mode) {
            'no-driver' { $script:installedDrivers = @() }
            'no-device' { $script:presentDevices = @() }
            'unsigned' { $script:installedDrivers[0].IsSigned = $false }
            'unknown-signature' { $script:installedDrivers[0].IsSigned = 'True' }
            'wrong-inf' { $script:installedDrivers[0].InfName = 'oem2.inf' }
            'changed-inf' { [IO.File]::AppendAllText((Join-Path $script:windowsInf 'oem1.inf'), '; different package') }
            'wrong-device' { $script:presentDevices[0].DeviceID += '-OTHER' }
            'not-present' { $script:presentDevices[0].Present = $false }
            'unknown-present' { $script:presentDevices[0].Present = $null }
            'device-error' { $script:presentDevices[0].ConfigManagerErrorCode = 28 }
            'unknown-error' { $script:presentDevices[0].ConfigManagerErrorCode = $null }
            'string-error' { $script:presentDevices[0].ConfigManagerErrorCode = '0' }
            'wrong-service' { $script:presentDevices[0].Service = 'unrelated' }
            'wrong-hardware' { $script:installedDrivers[0].DeviceID = 'PCI\VEN_DEAD&DEV_1000\FIXTURE' }
            'unsafe-inf' { $script:installedDrivers[0].InfName = '../oem1.inf' }
            'api-failure' { $script:cimFailure = $true }
        }
        $unconfirmed = Get-DriverExitResult -ExitCode 259 -Package $packages[0]
        Assert-True (-not $unconfirmed.Accepted -and $unconfirmed.VerificationDetails.Contains('unconfirmed')) ('Ambiguous 259 was accepted: ' + $mode)
    }
    Reset-InstalledDriverFixture
    Assert-True (-not (Get-DriverExitResult -ExitCode 5 -Package $packages[0]).Accepted -and $script:cimCalls.Count -eq 0) 'An unrelated failure must not be converted to success by an already-active driver.'
    [IO.File]::WriteAllBytes($packages[1].Catalog, [byte[]]@(1))
    $script:driverInvocations = @()
    $script:serialExitCode = 0
    $script:rawPnpOutput = 'Pacchetto gia esistente; oem1.inf; fixture full output.'
    function Invoke-PnpDriverPackage {
        param($Package)
        $script:driverInvocations += $Package.Service
        if ($Package.Service -eq 'netkvm') { return [pscustomobject]@{ ExitCode = 259; Output = $script:rawPnpOutput; Errors = 'Fixture original diagnostic.' } }
        return [pscustomobject]@{ ExitCode = $script:serialExitCode; Output = 'Serial package accepted.'; Errors = '' }
    }
    $installed = Invoke-FixedDriverInstallation -MediaRoot $root
    Assert-True (($script:driverInvocations -join ',') -eq 'netkvm,VirtioSerial') 'Verified existing NetKVM must allow the serial driver step.'
    Assert-True ($installed.Details.Contains($script:rawPnpOutput) -and $installed.Details.Contains('Windows result 259') -and $installed.Details.Contains('Fixture original diagnostic.')) 'The full original output, code and diagnostics must be preserved for a verified 259.'
    $script:driverInvocations = @(); $script:serialExitCode = 3010
    Assert-True ((Invoke-FixedDriverInstallation -MediaRoot $root).RestartRequired) 'A verified NetKVM 259 must not suppress a later serial 3010 restart requirement.'
    $script:driverInvocations = @(); $script:presentDevices = @()
    $failure = ''
    try { Invoke-FixedDriverInstallation -MediaRoot $root } catch { $failure = $_.Exception.Message }
    Assert-True ($failure.Contains('Windows result 259') -and $failure.Contains($script:rawPnpOutput) -and $failure.Contains('Fixture original diagnostic.') -and $failure.Contains('unconfirmed')) 'An unconfirmed 259 must remain an error and preserve all original output.'
    Assert-True (($script:driverInvocations -join ',') -eq 'netkvm') 'An ambiguous 259 must stop before the serial driver step.'
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
    Write-Output ('PASS: ' + $script:checks + ' installer checks; fixed ARM64 packages, signatures, verified/ambiguous 259, independent device/INF checks, serial continuation, complete diagnostics, restart results, constrained arguments and elevated GUI refusal. No Windows driver, scheduled task, guest port or clipboard was touched.')
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
