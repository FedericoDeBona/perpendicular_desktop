#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-DiagnosticWindowsPath {
    param($Path)
    # Compare ordinary absolute Windows paths lexically. Do not resolve aliases,
    # expand variables, collapse dot segments or consult the filesystem.
    if ($Path -isnot [string] -or $Path.Length -le 3 -or $Path.Length -gt 32767 -or
        $Path -notmatch '^[A-Za-z]:[\\/]') { return $null }
    $normalized = $Path.Replace([char]47, [char]92)
    if ($normalized.Substring(2) -match '[\x00-\x1f<>:"|?*]') { return $null }
    foreach ($part in $normalized.Substring(3).Split([char]92)) {
        if ($part.Length -eq 0 -or $part -eq '.' -or $part -eq '..' -or
            $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)') { return $null }
    }
    return $normalized
}

function Test-DiagnosticWindowsPath {
    param($Path, $ExpectedPath)
    $actual = ConvertTo-DiagnosticWindowsPath $Path
    $expected = ConvertTo-DiagnosticWindowsPath $ExpectedPath
    return ($null -ne $actual -and $null -ne $expected -and
        [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase))
}

function Get-DiagnosticExpectedTask {
    param([string]$Sid, [string]$Account, [string]$Directory, [string]$WindowsDirectory)
    $directoryPath = ConvertTo-DiagnosticWindowsPath $Directory
    $windowsPath = ConvertTo-DiagnosticWindowsPath $WindowsDirectory
    if ($null -eq $directoryPath -or $null -eq $windowsPath) {
        throw [IO.InvalidDataException]::new('Expected ordinary absolute Windows installation paths.')
    }
    $agent = $directoryPath + '\PerpendicularAgent.ps1'
    [pscustomobject]@{
        Sid = $Sid; Account = $Account; Directory = $directoryPath; Agent = $agent
        Name = 'Perpendicular Desktop Guest Agent (' + $Sid + ')'
        Description = 'PerpendicularDesktopGuestAgent/v1;sid=' + $Sid
        Execute = $windowsPath + '\System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments = '-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $agent + '"'
    }
}

function Test-DiagnosticAgentArguments {
    param($Arguments, $Expected)
    # Only the quoted -File path may vary in case or slash spelling. No generic
    # shell parsing or whole-command slash replacement can hide extra options.
    $prefix = '-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'
    if ($Arguments -isnot [string] -or $Arguments.Length -gt 32767 -or
        $Arguments.Length -le ($prefix.Length + 1) -or
        -not $Arguments.StartsWith($prefix, [StringComparison]::Ordinal) -or
        -not $Arguments.EndsWith('"', [StringComparison]::Ordinal)) { return $false }
    $path = $Arguments.Substring($prefix.Length, $Arguments.Length - $prefix.Length - 1)
    return (Test-DiagnosticWindowsPath $path $Expected.Agent)
}

function Test-DiagnosticOwnedTask {
    param($Task, $Expected)
    try {
        return ($Task.TaskName -ceq $Expected.Name -and $Task.TaskPath -ceq '\' -and
            $Task.Description -ceq $Expected.Description -and @($Expected.Sid, $Expected.Account) -contains $Task.Principal.UserId -and
            [string]$Task.Principal.LogonType -eq 'Interactive' -and [string]$Task.Principal.RunLevel -eq 'Limited' -and
            @($Task.Actions).Count -eq 1 -and
            (Test-DiagnosticWindowsPath $Task.Actions[0].Execute $Expected.Execute) -and
            (Test-DiagnosticAgentArguments $Task.Actions[0].Arguments $Expected) -and
            (Test-DiagnosticWindowsPath $Task.Actions[0].WorkingDirectory $Expected.Directory))
    } catch { return $false }
}

function Test-DiagnosticOwnedProcess {
    param($Process, $Expected)
    try {
        if (-not (Test-DiagnosticWindowsPath $Process.ExecutablePath $Expected.Execute)) { return $false }
        # Command lines are compared privately and are never returned or logged.
        $line = $Process.CommandLine
        if ($line -isnot [string] -or $line.Length -gt 32767) { return $false }
        if ($line.StartsWith('"', [StringComparison]::Ordinal)) {
            $end = $line.IndexOf('"', 1)
            if ($end -le 1 -or $line.Length -le ($end + 2) -or $line[$end + 1] -ne ' ') { return $false }
            $program = $line.Substring(1, $end - 1)
            $arguments = $line.Substring($end + 2)
            if (-not (Test-DiagnosticWindowsPath $program $Expected.Execute)) { return $false }
        } else {
            $end = $line.IndexOf(' ')
            if ($end -le 0 -or $line.Length -le ($end + 1)) { return $false }
            $program = $line.Substring(0, $end)
            $arguments = $line.Substring($end + 1)
            if (-not [string]::Equals($program, 'powershell.exe', [StringComparison]::OrdinalIgnoreCase) -and
                -not (Test-DiagnosticWindowsPath $program $Expected.Execute)) { return $false }
        }
        return (Test-DiagnosticAgentArguments $arguments $Expected)
    } catch { return $false }
}

function Get-DiagnosticErrorSummary {
    param([Exception]$Exception)
    $base = $Exception.GetBaseException()
    $bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$base.HResult), 0)
    $code = $null
    if ($base -is [ComponentModel.Win32Exception]) { $code = $base.NativeErrorCode }
    # No exception messages, invocation records, paths or command lines escape.
    [pscustomobject]@{ Type = $base.GetType().FullName; HResult = ('0x{0:X8}' -f $bits); Win32Error = $code }
}

function Write-DiagnosticFailure {
    param([string]$Section, [Exception]$Exception)
    $failure = Get-DiagnosticErrorSummary $Exception
    Write-Output ($Section + ': unavailable; exception_type=' + $failure.Type + '; hresult=' + $failure.HResult)
}

function Get-DiagnosticNativeSource {
    param([string]$CorePath)
    $core = Get-Item -LiteralPath $CorePath -ErrorAction Stop
    if ($core.PSIsContainer -or $core.Length -gt 1048576 -or
        ($core.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw [IO.InvalidDataException]::new('Expected a bounded regular installed core file.')
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($CorePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw [IO.InvalidDataException]::new('Installed core did not parse.') }
    $function = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Initialize-AgentNative' }, $false)
    if (@($function).Count -ne 1) { throw [IO.InvalidDataException]::new('Expected fixed native initializer was not found.') }
    $source = $function[0].Body.FindAll({ param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Contains('namespace Perpendicular.Guest') -and $node.Value.Contains('public static class Native')
    }, $true)
    if (@($source).Count -ne 1) { throw [IO.InvalidDataException]::new('Expected fixed native source was not found.') }
    if (-not $source[0].Value.Contains('@"\\.\Global\org.perpendicular.guest_agent.0"')) {
        throw [IO.InvalidDataException]::new('The installed native port does not match the fixed diagnostic target.')
    }
    return $source[0].Value
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run this diagnostic inside the logged-in Windows desktop.' }
Write-Output 'Perpendicular Guest Tools diagnostic: no clipboard, protocol traffic, task changes or driver changes.'
Write-Output ('PowerShell=' + $PSVersionTable.PSVersion.ToString() + '; CLR=' + [Environment]::Version.ToString() + '; Windows=' + [Environment]::OSVersion.Version.ToString())
Write-Output ('Session=' + [Diagnostics.Process]::GetCurrentProcess().SessionId + '; Apartment=' + [Threading.Thread]::CurrentThread.GetApartmentState())
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Perpendicular Desktop/Guest Agent'
$expected = Get-DiagnosticExpectedTask -Sid $identity.User.Value -Account $identity.Name -Directory $directory -WindowsDirectory ([Environment]::GetFolderPath('Windows'))
$manifestOwned = $false
try {
    $manifestPath = Join-Path $directory 'install.json'
    $item = Get-Item -LiteralPath $directory -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-Item -LiteralPath $manifestPath).Length -gt 1048576) { throw [IO.InvalidDataException]::new('Invalid installed manifest.') }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifestOwned = $manifest.product -ceq 'Perpendicular Desktop Guest Agent' -and
        $manifest.owner_sid -ceq $expected.Sid -and $manifest.task_name -ceq $expected.Name
    Write-Output ('InstalledManifestOwned=' + $manifestOwned)
} catch { Write-DiagnosticFailure -Section 'InstalledManifest' -Exception $_.Exception }

$taskOwned = $false
try {
    $task = Get-ScheduledTask -TaskPath '\' -TaskName $expected.Name -ErrorAction Stop
    $taskOwned = Test-DiagnosticOwnedTask -Task $task -Expected $expected
    Write-Output ('ScheduledTaskOwned=' + $taskOwned)
    if ($taskOwned) {
        $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
        $state = [string]$task.State
        if (@('Unknown', 'Disabled', 'Queued', 'Ready', 'Running') -notcontains $state) { $state = 'Unknown' }
        Write-Output ('ScheduledTaskState=' + $state + '; LastTaskResult=' + $info.LastTaskResult + (' (0x{0:X8})' -f [uint32]$info.LastTaskResult))
    }
} catch { Write-DiagnosticFailure -Section 'ScheduledTask' -Exception $_.Exception }

try {
    $count = 0
    if ($manifestOwned -and $taskOwned) {
        $processes = @(Get-CimInstance -Namespace 'root/cimv2' -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)
        foreach ($process in $processes) {
            if (-not (Test-DiagnosticOwnedProcess -Process $process -Expected $expected)) { continue }
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
            if ($owner.ReturnValue -eq 0 -and $owner.Sid -ceq $expected.Sid) {
                Write-Output ('OwnedAgentProcess PID=' + $process.ProcessId + '; Session=' + $process.SessionId)
                $count++
            }
        }
        Write-Output ('OwnedAgentProcessCount=' + $count + '; inaccessible or unmatched processes are excluded')
    } else { Write-Output 'OwnedAgentProcess: not inspected because package/task ownership was not confirmed.' }
} catch { Write-DiagnosticFailure -Section 'OwnedAgentProcess' -Exception $_.Exception }

try {
    $count = 0
    foreach ($device in @(Get-CimInstance -Namespace 'root/cimv2' -ClassName Win32_PnPEntity -ErrorAction Stop)) {
        if ($device.Service -ieq 'VirtioSerial' -or $device.DeviceID -match '^PCI\\VEN_1AF4&DEV_(1003|1043)(?:&|\\)') {
            $count++
            $serviceMatches = $device.Service -ieq 'VirtioSerial'
            Write-Output ('VirtIOSerialDevice Present=' + $device.Present + '; ConfigManagerErrorCode=' + $device.ConfigManagerErrorCode + '; ExpectedService=' + $serviceMatches)
        }
    }
    Write-Output ('VirtIOSerialDeviceCount=' + $count)
} catch { Write-DiagnosticFailure -Section 'VirtIOSerialDevice' -Exception $_.Exception }

$nativeReady = $false
try {
    if (-not $manifestOwned) { throw [InvalidOperationException]::new('Installed package ownership was not confirmed.') }
    # Extract only the fixed C# declaration. Do not dot-source the core, start
    # the agent, initialize its clipboard or execute any PowerShell function.
    $source = Get-DiagnosticNativeSource -CorePath (Join-Path $directory 'PerpendicularAgent.Core.ps1')
    Add-Type -TypeDefinition $source -ErrorAction Stop
    $nativeReady = $true
    Write-Output 'InstalledNativeSourceCompiled=True'
    $memory = New-Object IO.MemoryStream(,[byte[]]@(123, 125, 10))
    try {
        $reader = New-Object Perpendicular.Guest.BoundedLineReader($memory, 16)
        $line = $reader.ReadLine()
        Write-Output ('BoundedReaderMemoryCheck=' + ($line.Length -eq 2))
    } finally { $memory.Dispose() }
} catch { Write-DiagnosticFailure -Section 'InstalledNativeRuntime' -Exception $_.Exception }
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Write-Output 'WindowsFormsAssemblyAvailable=True (clipboard was not accessed)'
} catch { Write-DiagnosticFailure -Section 'WindowsFormsAssembly' -Exception $_.Exception }

if ($nativeReady) {
    $port = $null
    try {
        # Exact production target, exclusive overlapped open + FileStream only.
        # No read, write, flush, request, alternative path or discovery probe.
        $port = [Perpendicular.Guest.Native]::OpenAgentPort()
        Write-Output 'FixedAgentPortOpen=True; Win32Error=0; no protocol bytes read or written'
    } catch {
        $failure = Get-DiagnosticErrorSummary $_.Exception
        Write-Output ('FixedAgentPortOpen=False; Win32Error=' + $failure.Win32Error + '; exception_type=' + $failure.Type + '; hresult=' + $failure.HResult)
    } finally { if ($null -ne $port) { $port.Dispose() } }
} else { Write-Output 'FixedAgentPortOpen: not attempted because native initialization was not confirmed.' }
Write-Output 'Port errors 2/3 mean missing path; 5 means access denied; 32 means an exclusive opener may already own it. Opening alone does not prove agent communication.'
