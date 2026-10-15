#Requires -Version 5.1
[CmdletBinding()]
param([switch]$InstallDrivers)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FixedDriverPackages {
    param([Parameter(Mandatory = $true)][string]$MediaRoot)
    foreach ($entry in @(
        @{ Name = 'VirtIO network'; Directory = 'Drivers/NetKVM/w11/ARM64'; Base = 'netkvm'; Service = 'netkvm'; DevicePattern = '^PCI\\VEN_1AF4&DEV_(1000|1041)(?:&|\\)' },
        @{ Name = 'VirtIO serial'; Directory = 'Drivers/vioserial/w11/ARM64'; Base = 'vioser'; Service = 'VirtioSerial'; DevicePattern = '^PCI\\VEN_1AF4&DEV_(1003|1043)(?:&|\\)' }
    )) {
        $directory = Join-Path $MediaRoot $entry.Directory
        [pscustomobject]@{
            Name = $entry.Name
            Inf = Join-Path $directory ($entry.Base + '.inf')
            Catalog = Join-Path $directory ($entry.Base + '.cat')
            Driver = Join-Path $directory ($entry.Base + '.sys')
            DevicePattern = $entry.DevicePattern
            Service = $entry.Service
        }
    }
}

function Assert-SignedArm64Package {
    param([Parameter(Mandatory = $true)]$Package)
    foreach ($path in @($Package.Inf, $Package.Catalog, $Package.Driver)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ($Package.Name + ' is missing or is not a regular package file. Use the complete Perpendicular driver disc.')
        }
    }
    $inf = Get-Content -LiteralPath $Package.Inf -Raw
    $catalogName = [regex]::Escape([IO.Path]::GetFileName($Package.Catalog))
    if ($inf -notmatch '(?i)NTARM64' -or $inf -notmatch ('(?im)^\s*CatalogFile\s*=\s*' + $catalogName + '\s*$')) {
        throw ($Package.Name + ' does not identify the expected ARM64 driver catalog. Nothing was installed.')
    }
    $stream = [IO.File]::OpenRead($Package.Driver)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw 'Not a Windows driver image.' }
        $stream.Position = 0x3C
        $offset = $reader.ReadUInt32()
        if ($offset -gt $stream.Length - 6) { throw 'Invalid Windows driver image.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0xAA64) {
            throw ($Package.Name + ' is not an ARM64 driver. Nothing was installed.')
        }
    } finally { $stream.Dispose() }
    # Catalog validity is a preflight. PnPUtil additionally checks catalog
    # membership and Windows driver policy; no security setting is changed.
    $signature = Get-AuthenticodeSignature -LiteralPath $Package.Catalog
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw ($Package.Name + ' signature could not be verified by Windows (' + $signature.Status + '). Nothing was installed. Connect Windows to the internet if certificate validation needs it, or obtain a trusted signed package. Security settings were not changed.')
    }
}

function Get-DriverExitResult {
    param([int]$ExitCode, $Package = $null)
    $accepted = $ExitCode -eq 0 -or $ExitCode -eq 3010
    $verification = ''
    if ($ExitCode -eq 259 -and $null -ne $Package) {
        $installed = Confirm-InstalledDriverPackage -Package $Package
        $accepted = $installed.Verified
        $verification = $installed.Details
    }
    [pscustomobject]@{ Accepted = $accepted; RestartRequired = ($ExitCode -eq 3010); VerificationDetails = $verification }
}

function Get-WindowsInfDirectory {
    $windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    if ([string]::IsNullOrEmpty($windows)) { throw 'Windows could not locate its installed INF directory.' }
    return (Join-Path $windows 'INF')
}

function Confirm-InstalledDriverPackage {
    param([Parameter(Mandatory = $true)]$Package)
    try {
        # 259 is also returned when no device matches. Do not infer success from
        # localized PnPUtil output or a package merely being in the driver store.
        $sourceHash = (Get-FileHash -LiteralPath $Package.Inf -Algorithm SHA256 -ErrorAction Stop).Hash
        $infDirectory = Get-WindowsInfDirectory
        $drivers = @(Get-CimInstance -Namespace 'root/cimv2' -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
        $devices = @(Get-CimInstance -Namespace 'root/cimv2' -ClassName Win32_PnPEntity -ErrorAction Stop)
        foreach ($driver in $drivers) {
            if ($driver.IsSigned -isnot [bool] -or -not $driver.IsSigned -or $driver.DeviceID -notmatch $Package.DevicePattern -or
                $driver.InfName -notmatch '^oem[0-9]+\.inf$') { continue }
            # Win32_PnPSignedDriver.InfName identifies the device's installed INF.
            # SetupAPI preserves its bytes while assigning an unpredictable OEM
            # name in Windows/INF. Hash equality binds this device to our INF.
            $installedInf = Join-Path $infDirectory $driver.InfName
            if (-not (Test-Path -LiteralPath $installedInf -PathType Leaf) -or
                ((Get-Item -LiteralPath $installedInf).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ((Get-FileHash -LiteralPath $installedInf -Algorithm SHA256 -ErrorAction Stop).Hash -cne $sourceHash) { continue }
            foreach ($device in $devices) {
                if ($device.DeviceID -ieq $driver.DeviceID -and $device.Present -is [bool] -and $device.Present -and
                    $device.ConfigManagerErrorCode -is [uint32] -and $device.ConfigManagerErrorCode -eq 0 -and
                    $device.Service -ieq $Package.Service) {
                    return [pscustomobject]@{
                        Verified = $true
                        Details = 'Independent Windows verification: signed ' + $driver.InfName + ' matches the disc INF (SHA-256); device ' + $device.DeviceID + ' is present, reports no configuration error and uses service ' + $device.Service + '. Windows result 259 is accepted for this already-installed device.'
                    }
                }
            }
        }
        return [pscustomobject]@{ Verified = $false; Details = 'Windows result 259 remains unconfirmed: no signed, identical INF was associated with a present, healthy device using the expected VirtIO service.' }
    } catch {
        return [pscustomobject]@{ Verified = $false; Details = 'Windows result 259 remains unconfirmed because the independent device check failed: ' + $_.Exception.Message }
    }
}

function Get-NativeSystemDirectory {
    $windowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    if ([string]::IsNullOrEmpty($windowsDirectory)) { throw 'Windows could not locate its system directory.' }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return (Join-Path $windowsDirectory 'Sysnative')
    }
    return (Join-Path $windowsDirectory 'System32')
}

function Get-InstallerArguments {
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [switch]$DriverHelper)
    if ($ScriptPath.Contains('"') -or $ScriptPath.Contains("`r") -or $ScriptPath.Contains("`n")) {
        throw 'The installer path contains unsupported characters.'
    }
    $arguments = '-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    if ($DriverHelper) { $arguments += ' -InstallDrivers' }
    return $arguments
}

function Get-ReadOnlyDriverMedia {
    $directory = [IO.Path]::GetFullPath($PSScriptRoot)
    if ([IO.Path]::GetFileName($directory) -ine 'GuestTools') {
        throw 'Open GuestTools on the mounted Perpendicular driver disc. Do not copy this installer to a different folder.'
    }
    $root = [IO.Path]::GetPathRoot($directory)
    $drive = New-Object IO.DriveInfo($root)
    if ($drive.DriveType -ne [IO.DriveType]::CDRom -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($directory).TrimEnd('\'), $root.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Run this installer from GuestTools on the mounted Perpendicular driver disc. Writable folders and network paths are not accepted.'
    }
    return $root
}

function Assert-InteractiveUser {
    param([Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][bool]$Elevated)
    if ($Elevated) { throw 'Close this window and double-click Install-PerpendicularGuestTools.cmd normally. Do not use Run as administrator; only the driver step requests administrator permission.' }
    if (-not ('PerpendicularInstaller.DesktopUser' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PerpendicularInstaller {
    public static class DesktopUser {
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int info, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr buffer);
        private static string Read(int session, int info) {
            IntPtr buffer;
            int bytes;
            if (!WTSQuerySessionInformationW(IntPtr.Zero, session, info, out buffer, out bytes))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try { return Marshal.PtrToStringUni(buffer) ?? ""; }
            finally { WTSFreeMemory(buffer); }
        }
        public static string Account(int session) {
            string user = Read(session, 5);
            string domain = Read(session, 7);
            if (user.Length == 0) throw new InvalidOperationException("No logged-in Windows desktop user was found.");
            return domain.Length == 0 ? user : domain + "\\" + user;
        }
    }
}
'@
    }
    $desktopAccount = [PerpendicularInstaller.DesktopUser]::Account([Diagnostics.Process]::GetCurrentProcess().SessionId)
    $account = New-Object Security.Principal.NTAccount($desktopAccount)
    $desktopSid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($desktopSid -cne $Identity.User.Value) {
        throw 'This installer is running as a different account from the logged-in Windows desktop. Close it and double-click the installer as the desktop user.'
    }
}

function Start-InstallerProcess {
    param([string]$ScriptPath, [switch]$Elevated, [switch]$DriverHelper)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path (Get-NativeSystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe'
    $start.Arguments = Get-InstallerArguments -ScriptPath $ScriptPath -DriverHelper:$DriverHelper
    $start.UseShellExecute = $Elevated.IsPresent
    $start.WorkingDirectory = $PSScriptRoot
    if ($Elevated) { $start.Verb = 'runas' }
    else { $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true }
    $process = [Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Windows did not start the installer.' }
    $output = $null; $errors = $null
    if (-not $Elevated) { $output = $process.StandardOutput.ReadToEndAsync(); $errors = $process.StandardError.ReadToEndAsync() }
    return [pscustomobject]@{ Process = $process; Output = $output; Errors = $errors }
}

function Show-InstallationDetails {
    param([string]$Title, [string]$Text, [string]$Summary)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = $Title; $dialog.ClientSize = New-Object Drawing.Size(680, 410)
    $dialog.StartPosition = 'CenterScreen'; $dialog.Font = New-Object Drawing.Font('Segoe UI', 10)
    $heading = New-Object Windows.Forms.Label
    $heading.Text = $Summary; $heading.SetBounds(20, 16, 640, 88)
    $log = New-Object Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Both'; $log.WordWrap = $false
    $log.Text = $Text; $log.SetBounds(20, 112, 640, 231); $log.Anchor = 'Top,Bottom,Left,Right'
    $close = New-Object Windows.Forms.Button
    $close.Text = 'Close'; $close.SetBounds(550, 360, 110, 32); $close.Anchor = 'Bottom,Right'
    $close.Add_Click({ $this.FindForm().Close() }); $dialog.AcceptButton = $close; $dialog.CancelButton = $close
    $dialog.Controls.AddRange(@($heading, $log, $close))
    try { [void]$dialog.ShowDialog() } finally { $dialog.Dispose() }
}

function Invoke-PnpDriverPackage {
    param([Parameter(Mandatory = $true)]$Package)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path (Get-NativeSystemDirectory) 'pnputil.exe'
    $start.Arguments = '/add-driver "' + $Package.Inf + '" /install'
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Windows could not start its driver installer.' }
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.GetAwaiter().GetResult(); Errors = $errors.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function Invoke-FixedDriverInstallation {
    param([string]$MediaRoot)
    $packages = @(Get-FixedDriverPackages -MediaRoot $MediaRoot)
    # Validate both packages before changing the Windows driver store.
    foreach ($package in $packages) { Assert-SignedArm64Package -Package $package }
    $restart = $false
    $details = New-Object Text.StringBuilder
    foreach ($package in $packages) {
        $outcome = Invoke-PnpDriverPackage -Package $package
        [void]$details.AppendLine($package.Name + ' (Windows result ' + $outcome.ExitCode + '):')
        [void]$details.AppendLine($outcome.Output)
        [void]$details.AppendLine($outcome.Errors)
        $result = Get-DriverExitResult -ExitCode $outcome.ExitCode -Package $package
        if (-not [string]::IsNullOrEmpty($result.VerificationDetails)) { [void]$details.AppendLine($result.VerificationDetails) }
        if (-not $result.Accepted) {
            throw ($package.Name + ' was not accepted by Windows. No security policy was changed.' + [Environment]::NewLine + $details.ToString())
        }
        if ($result.RestartRequired) { $restart = $true }
    }
    return [pscustomobject]@{ RestartRequired = $restart; Details = $details.ToString() }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This installer runs inside the Windows ARM64 desktop.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
try {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
        throw 'Double-click Install-PerpendicularGuestTools.cmd from your logged-in Windows desktop.'
    }
    $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', [EnvironmentVariableTarget]::Machine)
    if ($architecture -ine 'ARM64') { throw 'This driver disc supports Windows ARM64 only.' }
    $mediaRoot = Get-ReadOnlyDriverMedia
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($InstallDrivers) {
        if (-not $isElevated) { throw 'The driver helper requires the administrator permission requested by the Guest Tools window.' }
        $result = Invoke-FixedDriverInstallation -MediaRoot $mediaRoot
        $summary = 'Windows accepted the network and serial driver packages. This does not prove that either device is connected.'
        if ($result.RestartRequired) { $summary += ' Windows requests a restart. Finish the user tools step first, then restart Windows when convenient.' }
        Show-InstallationDetails -Title 'Perpendicular Driver Results' -Summary $summary -Text $result.Details
        if ($result.RestartRequired) { exit 3010 }
        exit 0
    }
    Assert-InteractiveUser -Identity $identity -Elevated $isElevated
    $agentInstaller = Join-Path $PSScriptRoot 'Install-PerpendicularAgent.ps1'
    foreach ($file in @('Install-PerpendicularAgent.ps1', 'PerpendicularAgent.ps1', 'PerpendicularAgent.Core.ps1', 'PerpendicularAgent.Display.ps1', 'Uninstall-PerpendicularAgent.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) { throw ('The Guest Tools disc is incomplete: ' + $file) }
    }
} catch {
    Show-InstallationDetails -Title 'Perpendicular Installation Could Not Start' -Summary 'Installation did not complete. Read the message below, then close this window.' -Text $_.Exception.Message
    exit 1
}

$script:pending = $null
$script:driverAccepted = $false
$script:restartRequired = $false
$script:details = ''
$selfInstaller = $PSCommandPath
$form = New-Object Windows.Forms.Form
$form.Text = 'Perpendicular Guest Tools'; $form.ClientSize = New-Object Drawing.Size(720, 550)
$form.MinimumSize = $form.Size; $form.MaximumSize = $form.Size; $form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'; $form.Font = New-Object Drawing.Font('Segoe UI', 10)
$title = New-Object Windows.Forms.Label
$title.Text = 'Set up Windows for Perpendicular'; $title.Font = New-Object Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold)
$title.SetBounds(26, 22, 670, 38)
$intro = New-Object Windows.Forms.Label
$intro.Text = 'Install the network and serial drivers, then the tools for your Windows account. You choose both steps.'
$intro.SetBounds(28, 68, 660, 46)
$driverDescription = New-Object Windows.Forms.Label
$driverDescription.Text = '1. Network and serial drivers (ARM64). Windows asks for administrator permission for this step only.'
$driverDescription.SetBounds(28, 126, 660, 46)
$driverButton = New-Object Windows.Forms.Button
$driverButton.Text = 'Install drivers (administrator)...'; $driverButton.SetBounds(28, 176, 320, 38)
$driverStatus = New-Object Windows.Forms.Label
$driverStatus.Text = 'Ready to check the signed driver packages on this disc.'; $driverStatus.SetBounds(28, 222, 660, 48)
$agentDescription = New-Object Windows.Forms.Label
$agentDescription.Text = '2. Install user tools for ' + $identity.Name + '. This step stays in your current Windows account.'
$agentDescription.SetBounds(28, 282, 660, 46)
$agentButton = New-Object Windows.Forms.Button
$agentButton.Text = 'Install tools for my account'; $agentButton.SetBounds(28, 332, 320, 38); $agentButton.Enabled = $false
$agentStatus = New-Object Windows.Forms.Label
$agentStatus.Text = 'Complete the driver step first.'; $agentStatus.SetBounds(28, 378, 660, 44)
$footer = New-Object Windows.Forms.Label
$footer.Text = 'After installation, open Guest Tools in the Mac app and choose Check Connection. Installation alone does not prove a connection.'
$footer.SetBounds(28, 436, 660, 48)
$detailsButton = New-Object Windows.Forms.Button
$detailsButton.Text = 'View Details...'; $detailsButton.SetBounds(28, 500, 140, 32); $detailsButton.Enabled = $false
$closeButton = New-Object Windows.Forms.Button
$closeButton.Text = 'Close'; $closeButton.SetBounds(580, 500, 110, 32)
$form.Controls.AddRange(@($title, $intro, $driverDescription, $driverButton, $driverStatus, $agentDescription, $agentButton, $agentStatus, $footer, $detailsButton, $closeButton))
$form.CancelButton = $closeButton

function Update-InstallerButtons {
    $idle = $null -eq $script:pending
    $driverButton.Enabled = $idle
    $agentButton.Enabled = $idle -and $script:driverAccepted
    $closeButton.Enabled = $idle
    $detailsButton.Enabled = $idle -and $script:details.Length -gt 0
}

$driverButton.Add_Click({
    try {
        Assert-InteractiveUser -Identity ([Security.Principal.WindowsIdentity]::GetCurrent()) -Elevated $false
        $child = Start-InstallerProcess -ScriptPath $selfInstaller -Elevated -DriverHelper
        $script:pending = [pscustomobject]@{ Kind = 'drivers'; Child = $child }
        $driverStatus.Text = 'Installing drivers. Review the administrator results window and close it when finished.'
    } catch {
        $exception = $_.Exception.GetBaseException()
        if ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) {
            $driverStatus.Text = 'Administrator permission was cancelled. Driver installation did not start.'
        } else { $driverStatus.Text = 'Driver installation did not start. Choose View Details for the error.' }
        $script:details = $exception.Message
    }
    Update-InstallerButtons
})
$agentButton.Add_Click({
    try {
        # Recheck the desktop identity immediately before the unelevated launch.
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
        Assert-InteractiveUser -Identity $currentIdentity -Elevated ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
        $child = Start-InstallerProcess -ScriptPath $agentInstaller
        $script:pending = [pscustomobject]@{ Kind = 'agent'; Child = $child }
        $agentStatus.Text = 'Installing the tools for your account. No administrator permission is requested.'
    } catch {
        $agentStatus.Text = 'User tools installation did not start. Choose View Details for the error.'
        $script:details = $_.Exception.Message
    }
    Update-InstallerButtons
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    if ($null -eq $script:pending) { return }
    $child = $script:pending.Child
    $completed = $false
    try {
        if (-not $child.Process.HasExited) { return }
        $completed = $true
        $child.Process.WaitForExit()
        $exitCode = $child.Process.ExitCode
        if ($script:pending.Kind -eq 'drivers') {
            $result = Get-DriverExitResult -ExitCode $exitCode
            $script:driverAccepted = $result.Accepted
            $script:restartRequired = $script:restartRequired -or $result.RestartRequired
            $script:details = 'Driver helper exit code: ' + $exitCode + '. Full Windows results were shown in the administrator window.'
            if ($result.Accepted) {
                $driverStatus.Text = 'Windows accepted the driver packages. Continue with the user tools below.'
                if ($script:restartRequired) { $driverStatus.Text += ' Restart Windows after both steps.' }
                $agentStatus.Text = 'Ready to install for ' + $identity.Name + '.'
            } else { $driverStatus.Text = 'Driver installation did not complete. The administrator window showed the Windows error. You can try again.' }
        } else {
            $script:details = ($child.Output.GetAwaiter().GetResult() + [Environment]::NewLine + $child.Errors.GetAwaiter().GetResult()).Trim()
            if ($exitCode -eq 0) {
                $agentStatus.Text = 'User tools were installed and their startup task was requested. Check the connection in the Mac app.'
                if ($script:restartRequired) { $agentStatus.Text += ' Windows still needs a restart.' }
            } else { $agentStatus.Text = 'User tools installation failed. Choose View Details for the actual Windows error.' }
        }
    } catch {
        $script:details = $_.Exception.Message
        if ($script:pending.Kind -eq 'drivers') { $driverStatus.Text = 'The driver result could not be confirmed. Choose View Details.' }
        else { $agentStatus.Text = 'The user tools result could not be confirmed. Choose View Details.' }
    } finally {
        if ($completed -and $null -ne $script:pending) {
            $child.Process.Dispose(); $script:pending = $null; Update-InstallerButtons
        }
    }
})
$detailsButton.Add_Click({ Show-InstallationDetails -Title 'Perpendicular Installation Details' -Summary 'These are the actual results from the most recent installation step.' -Text $script:details })
$closeButton.Add_Click({ $form.Close() })
$form.Add_FormClosing({ param($sender, $eventArgs) if ($null -ne $script:pending) { $eventArgs.Cancel = $true } })
try { $timer.Start(); [void]$form.ShowDialog() }
finally { $timer.Stop(); $timer.Dispose(); $form.Dispose() }
