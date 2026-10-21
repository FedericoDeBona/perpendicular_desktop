#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$InstallBridge,[switch]$RemoveParallelsTools)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'Run this one-time cleanup in the development Windows desktop as its owner.'
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$root = Join-Path $env:ProgramData 'Perpendicular Restart'
$agent = Join-Path $env:LOCALAPPDATA 'Perpendicular Desktop\Guest Agent'
$setup = Join-Path $env:ProgramData 'Perpendicular Desktop Setup'
$shared = Join-Path $env:LOCALAPPDATA 'Perpendicular Desktop\Shared Files'
$trial = Join-Path $env:ProgramFiles 'Perpendicular VirtioFS Trial'
$backup = Join-Path $root ('Legacy Cleanup\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
& icacls.exe $backup /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' ("*$($sid):(OI)(CI)F") | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the cleanup backup.' }
Start-Transcript -Path (Join-Path $backup 'cleanup.log') | Out-Null
$report = [ordered]@{ product='PerpendicularLegacyCleanup/v1'; ownerSid=$sid; backup=$backup
    removedTasks=@(); removedServices=@(); stoppedProcesses=@(); removedStartup=@(); removedShares=@()
    restoredFolders=@(); quarantined=@(); removedOwnedCredentials=@(); restartRequired=$false; completed=$false }

function Save-CleanupReport {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $backup 'result.json')
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $root 'cleanup.json')
}
function Test-OldCommand([string]$Text) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Text)
    foreach ($path in @((Join-Path $agent 'PerpendicularAgent.ps1'),
        (Join-Path $agent 'PerpendicularAgent.Launcher.exe'),(Join-Path $agent 'perpendicular-app-agent.exe'),
        (Join-Path $setup 'Complete-PerpendicularSetup.ps1'))) {
        if ($expanded -match ('(?i)(?:^|[\s"])' + [regex]::Escape($path) + '(?:$|[\s"])')) { return $true }
    }
    return $false
}
function Test-OldRemote([string]$Path) {
    return $Path -match '^\\\\10\.0\.2\.2\\[^\\]+(?:\\|$)' -or
        $Path -match '^\\\\10\.0\.2\.4\\(?:Home|AllFiles)(?:\\|$)'
}
function Move-OwnedDirectory([string]$Path,[string]$Name,[string]$Product) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('Unsafe legacy directory preserved: ' + $Path)
    }
    $marker = if ($Name -eq 'Guest Agent') { 'install.json' } else { 'perpendicular.json' }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $Path $marker) | ConvertFrom-Json
    if ($manifest.product -cne $Product -or $manifest.owner_sid -cne $sid) {
        throw ('Legacy ownership receipt does not match; directory preserved: ' + $Path)
    }
    $destination = Join-Path $backup $Name
    Move-Item -LiteralPath $Path -Destination $destination
    $report.quarantined += @{source=$Path; destination=$destination}
}
function Get-HostForwardingLinks {
    # The old native app-agent identifies converted Parallels entries by
    # PKEY_Link_Arguments=SharedHostApps.dll, not the translated "(Mac)" name.
    $directories=New-Object 'Collections.Generic.Queue[string]'
    foreach ($path in @((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:PUBLIC 'Desktop'))) {
        if (Test-Path -LiteralPath $path) { $directories.Enqueue($path) }
    }
    $shell=New-Object -ComObject WScript.Shell
    try {
        while ($directories.Count -gt 0) {
            $directory=$directories.Dequeue()
            if (((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($item.PSIsContainer) { $directories.Enqueue($item.FullName); continue }
                if ($item.Extension -ine '.lnk') { continue }
                $link=$shell.CreateShortcut($item.FullName)
                try {
                    $target=[Environment]::ExpandEnvironmentVariables([string]$link.TargetPath)
                    $rundll=@((Join-Path $env:SystemRoot 'System32\rundll32.exe'),(Join-Path $env:SystemRoot 'SysWOW64\rundll32.exe'))
                    if ($rundll -icontains $target -and
                        [string]$link.Arguments -match '(?i)(?:^|[\\\s"])SharedHostApps\.dll(?:[,"\s]|$)') {
                        @{source=$item.FullName; delegation='SharedHostApps.dll'}
                    }
                } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
            }
        }
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
}
try {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PerpendicularCleanup {
    public static class Native {
        [DllImport("shell32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
        static extern int SHSetKnownFolderPath(ref Guid id,uint flags,IntPtr token,string path);
        [DllImport("user32.dll",CharSet=CharSet.Unicode,ExactSpelling=true)]
        static extern IntPtr SendMessageTimeoutW(IntPtr window,uint message,UIntPtr wParam,string text,uint flags,uint timeout,out UIntPtr result);
        [DllImport("mpr.dll",CharSet=CharSet.Unicode,ExactSpelling=true)]
        public static extern int WNetCancelConnection2W(string name,uint flags,bool force);
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
        struct Credential {
            public uint Flags,Type; public string TargetName,Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint BlobSize; public IntPtr Blob; public uint Persist,AttributeCount;
            public IntPtr Attributes; public string TargetAlias,UserName;
        }
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true,ExactSpelling=true)]
        static extern bool CredReadW(string target,uint type,uint flags,out IntPtr value);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true,ExactSpelling=true)]
        static extern bool CredDeleteW(string target,uint type,uint flags);
        [DllImport("advapi32.dll",ExactSpelling=true)] static extern void CredFree(IntPtr value);
        public static void SetFolder(string value,string path) {
            Guid id=new Guid(value); int code=SHSetKnownFolderPath(ref id,0,IntPtr.Zero,path);
            if(code!=0) Marshal.ThrowExceptionForHR(code);
        }
        public static void Refresh() {
            UIntPtr result; SendMessageTimeoutW(new IntPtr(0xffff),0x001a,UIntPtr.Zero,
                "User Shell Folders",2,1000,out result);
        }
        public static bool RemoveOwnedCredential(string target,string sid) {
            if(target!="10.0.2.2" && target!="10.0.2.4") throw new ArgumentException();
            IntPtr pointer;
            if(!CredReadW(target,2,0,out pointer)) {
                int code=Marshal.GetLastWin32Error(); if(code==1168) return false;
                throw new Win32Exception(code);
            }
            bool owned;
            try { Credential value=(Credential)Marshal.PtrToStructure(pointer,typeof(Credential));
                owned=value.Type==2 && value.Comment=="PerpendicularSharedFiles/v1;sid="+sid;
            } finally { CredFree(pointer); }
            if(!owned) return false;
            if(!CredDeleteW(target,2,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return true;
        }
    }
}
'@
    # Inventory and rollback data are written before stopping anything. Match
    # exact old package paths, owner SID and product markers, never name prefixes.
    $tasks = @(Get-ScheduledTask | Where-Object {
        if ($_.TaskName -eq 'PerpendicularRestart') { return $false }
        $owner = [string]$_.Principal.UserId
        try { if ($owner -notlike 'S-1-*') { $owner = (New-Object Security.Principal.NTAccount($owner)).Translate([Security.Principal.SecurityIdentifier]).Value } }
        catch { return $false }
        $marker = $_.Description -ceq ('PerpendicularDesktopGuestAgent/v1;sid=' + $sid) -or
            $_.Description -ceq ('PerpendicularDesktopSetup/v1;sid=' + $sid)
        return $owner -ceq $sid -and $marker -and @($_.Actions | Where-Object { Test-OldCommand ($_.Execute + ' ' + $_.Arguments) }).Count -gt 0
    })
    $services = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' | ForEach-Object {
        if ($_.PSChildName -eq 'PerpendicularRestart') { return }
        $value = Get-ItemProperty -LiteralPath $_.PSPath
        if (($value.Type -band 0x30) -ne 0 -and (Test-OldCommand ([string]$value.ImagePath))) { $value }
    })
    $trialMarker = Join-Path $trial 'installation.json'
    if (Test-Path -LiteralPath $trialMarker) {
        $ownedTrial = Get-Content -Raw -LiteralPath $trialMarker | ConvertFrom-Json
        $trialKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\VirtioFsSvc'
        if ($ownedTrial.product -ceq 'PerpendicularVirtioFSTrial/v1' -and (Test-Path $trialKey)) {
            $trialService = Get-ItemProperty $trialKey
            if ($trialService.ImagePath -ceq $ownedTrial.binary_path -and
                $trialService.ImagePath -match [regex]::Escape((Join-Path $trial 'virtiofs.exe'))) { $services += $trialService }
        }
    }
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='PerpendicularAgent.Launcher.exe' OR Name='perpendicular-app-agent.exe'" | Where-Object {
        if ($_.ProcessId -eq $PID -or -not (Test-OldCommand ([string]$_.CommandLine))) { return $false }
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
        return $owner.ReturnValue -eq 0 -and $owner.Sid -ceq $sid
    })
    $startup = @()
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
        if (Test-Path $key) { foreach ($property in (Get-ItemProperty $key).PSObject.Properties) {
            if ($property.Value -is [string] -and (Test-OldCommand $property.Value)) {
                $startup += @{key=$key; name=$property.Name; value=$property.Value}
            }
        } }
    }
    $mappings = @()
    if (Test-Path 'HKCU:\Network') { foreach ($key in @(Get-ChildItem 'HKCU:\Network')) {
        $remote = [string](Get-ItemProperty $key.PSPath).RemotePath
        if (Test-OldRemote $remote) { $mappings += @{local=($key.PSChildName + ':'); remote=$remote; key=$key.PSPath} }
    } }
    $folders = @()
    $names = @{ Desktop='Desktop'; Personal='Documents'; 'My Pictures'='Pictures'; 'My Music'='Music'; 'My Video'='Videos'
        '{374DE290-123F-4565-9164-39C4925E467B}'='Downloads'; '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}'='Documents'
        '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}'='Desktop'; '{33E28130-4E1E-4676-835A-98395C3BC3BB}'='Pictures'
        '{4BD8D571-6D19-48D3-BE97-422220080E43}'='Music'; '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}'='Videos'
        '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'='Documents'; '{0DDD015D-B06C-45D5-8C4C-F59713854639}'='Pictures'
        '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}'='Videos'; '{A0C69A99-21C8-4671-8703-7934162FCF1D}'='Music'
        '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}'='Downloads' }
    foreach ($part in @('User Shell Folders','Shell Folders')) {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\' + $part
        if (Test-Path $key) { foreach ($property in (Get-ItemProperty $key).PSObject.Properties) {
            if ($property.Value -isnot [string] -or -not $names.ContainsKey($property.Name)) { continue }
            $value = [Environment]::ExpandEnvironmentVariables($property.Value)
            $old = Test-OldRemote $value
            foreach ($drive in (@('M:') + @($mappings | ForEach-Object { $_.local }))) {
                if ($value.StartsWith($drive + '\',[StringComparison]::OrdinalIgnoreCase)) { $old=$true }
            }
            if ($old) { $folders += @{key=$key; name=$property.Name; old=$property.Value; folder=$names[$property.Name]; type=$part} }
        } }
    }
    $hostLinks=@(Get-HostForwardingLinks)
    $parallelsTools=@(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -ceq 'Parallels Tools' } |
        Select-Object DisplayName,PSChildName,PSPath,Publisher,WindowsInstaller)
    @{tasks=@($tasks | Select-Object TaskPath,TaskName); services=@($services | Select-Object PSChildName,ImagePath,Start)
        processes=@($processes | Select-Object Name,ProcessId,CreationDate); startup=$startup; mappings=$mappings; folders=$folders
        hostForwardingLinks=$hostLinks; parallelsTools=$parallelsTools} |
        ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $backup 'before.json')
    if ($RemoveParallelsTools) {
        if ($parallelsTools.Count -gt 1) { throw 'Multiple Parallels Tools packages found; no MSI was invoked.' }
        if ($parallelsTools.Count -eq 1) {
            $package=$parallelsTools[0]; $product=[guid]::Empty
            if ($package.WindowsInstaller -ne 1 -or $package.Publisher -notmatch '^Parallels(?:[\s,]|$)' -or
                -not [guid]::TryParseExact($package.PSChildName,'B',[ref]$product)) {
                throw 'The registered Parallels Tools MSI identity/publisher could not be verified.'
            }
            $code=$product.ToString('B').ToUpperInvariant()
            $msiLog=Join-Path $backup 'Parallels-Tools-uninstall.log'
            # Never execute a registry UninstallString or remove driver keys.
            $arguments='/x ' + $code + ' /qn /norestart /L*v "' + $msiLog + '"'
            $uninstall=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $arguments -Wait -PassThru
            $report.parallelsTools=@{productCode=$code; publisher=$package.Publisher; exitCode=$uninstall.ExitCode; log=$msiLog}
            Save-CleanupReport
            if ($uninstall.ExitCode -notin @(0,3010)) { throw ('Parallels Tools removal failed; MSI exit code: ' + $uninstall.ExitCode) }
            $report.parallelsTools.removalAccepted=$true
            $report.parallelsTools.registryStillPresent=Test-Path -LiteralPath $package.PSPath
            $report.restartRequired=$true
            # MSI may remove some shortcuts itself. Quarantine only the
            # remaining delegated links, with their exact identities re-read.
            $hostLinks=@(Get-HostForwardingLinks)
        } else { $report.parallelsTools=@{alreadyAbsent=$true} }
    }
    $index=0
    foreach ($task in $tasks) {
        Export-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName | Set-Content -Encoding Unicode -LiteralPath (Join-Path $backup ("task-$index.xml")); $index++
        Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -InputObject $task -Confirm:$false
        $report.removedTasks += $task.TaskPath + $task.TaskName
    }
    foreach ($service in $services) {
        $name=$service.PSChildName
        & reg.exe export ('HKLM\SYSTEM\CurrentControlSet\Services\' + $name) (Join-Path $backup ($name + '.reg')) /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('Could not back up old service: ' + $name) }
        Set-Service -Name $name -StartupType Disabled
        Stop-Service -Name $name -ErrorAction Stop
        & sc.exe delete $name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('Could not remove old service: ' + $name) }
        $report.removedServices += $name
    }
    foreach ($candidate in $processes) {
        try { $process=[Diagnostics.Process]::GetProcessById($candidate.ProcessId) } catch [ArgumentException] { continue }
        try {
            [void]$process.Handle
            if ([Math]::Abs(($process.StartTime.ToUniversalTime()-$candidate.CreationDate.ToUniversalTime()).TotalMilliseconds) -gt 1) { continue }
            $process.Kill(); if (-not $process.WaitForExit(5000)) { throw 'An old agent process did not stop.' }
            $report.stoppedProcesses += $candidate.ProcessId
        } catch { if (-not $process.HasExited) { throw } } finally { $process.Dispose() }
    }
    foreach ($entry in $startup) {
        Remove-ItemProperty -LiteralPath $entry.key -Name $entry.name
        $report.removedStartup += @{key=$entry.key; name=$entry.name}
    }
    foreach ($entry in $folders) {
        $local=Join-Path $env:USERPROFILE $entry.folder
        if (Test-Path -LiteralPath $local) {
            $item=Get-Item -LiteralPath $local -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('The local Windows folder is not an ordinary directory; preserved: ' + $local)
            }
        }
        New-Item -ItemType Directory -Force -Path $local | Out-Null
        $value=if ($entry.type -eq 'User Shell Folders') { '%USERPROFILE%\' + $entry.folder } else { $local }
        $type=if ($entry.type -eq 'User Shell Folders') { 'ExpandString' } else { 'String' }
        New-ItemProperty -LiteralPath $entry.key -Name $entry.name -Value $value -PropertyType $type -Force | Out-Null
        $report.restoredFolders += @{name=$entry.name; local=$local}
    }
    $folderIds=@{ Desktop='B4BFCC3A-DB2C-424C-B029-7FE99A87C641'; Documents='FDD39AD0-238F-46AF-ADB4-6C85480369C7'
        Downloads='374DE290-123F-4565-9164-39C4925E467B'; Pictures='33E28130-4E1E-4676-835A-98395C3BC3BB'
        Music='4BD8D571-6D19-48D3-BE97-422220080E43'; Videos='18989B1D-99B5-455B-841C-AB7C74E4DDFC' }
    foreach ($folder in @($folders | ForEach-Object { $_.folder } | Select-Object -Unique)) {
        [PerpendicularCleanup.Native]::SetFolder($folderIds[$folder],(Join-Path $env:USERPROFILE $folder))
    }
    [PerpendicularCleanup.Native]::Refresh()
    foreach ($mapping in $mappings) {
        $code=[PerpendicularCleanup.Native]::WNetCancelConnection2W($mapping.local,1,$false)
        if ($code -ne 0 -and $code -ne 2250) { throw ('Old mapping remains in use; no open files were forced closed. Code: ' + $code) }
        Remove-Item -LiteralPath $mapping.key -Recurse -Force -ErrorAction SilentlyContinue
        $report.removedShares += $mapping.remote
    }
    foreach ($remote in @('\\10.0.2.2\Home','\\10.0.2.2\AllFiles','\\10.0.2.4\Home','\\10.0.2.4\AllFiles')) {
        $code=[PerpendicularCleanup.Native]::WNetCancelConnection2W($remote,0,$false)
        if ($code -ne 0 -and $code -ne 2250) { throw ('Old direct share remains in use; code: ' + $code) }
    }
    foreach ($target in @('10.0.2.2','10.0.2.4')) {
        if ([PerpendicularCleanup.Native]::RemoveOwnedCredential($target,$sid)) { $report.removedOwnedCredentials += $target }
    }
    if ($hostLinks.Count -gt 0) {
        $linkBackup=Join-Path $backup 'Host application links'
        New-Item -ItemType Directory -Path $linkBackup | Out-Null
        $index=0
        foreach ($link in $hostLinks) {
            $destination=Join-Path $linkBackup (([string]$index) + '.lnk'); $index++
            Move-Item -LiteralPath $link.source -Destination $destination
            $report.quarantined += @{source=$link.source; destination=$destination}
        }
    }
    $report.quarantinedHostApplicationLinks=$hostLinks.Count
    Move-OwnedDirectory $agent 'Guest Agent' 'Perpendicular Desktop Guest Agent'
    $navigation=Join-Path ([Environment]::GetFolderPath('NetworkShortcuts')) 'Mac'
    Move-OwnedDirectory $navigation 'Mac network location' 'PerpendicularMacNavigation/v1'
    Move-OwnedDirectory (Join-Path $shared 'Mac') 'Mac navigation contents' 'PerpendicularMacNavigation/v1'
    $report.remainingLegacyTasks=@(Get-ScheduledTask | Where-Object {
        $_.Description -ceq ('PerpendicularDesktopGuestAgent/v1;sid=' + $sid) -or
        $_.Description -ceq ('PerpendicularDesktopSetup/v1;sid=' + $sid)
    }).Count
    if ($report.remainingLegacyTasks -ne 0) { throw 'A legacy integration task remains; the receipt identifies the completed actions.' }
    $report.completed=$true; $report.completedAt=[DateTime]::UtcNow.ToString('o')
    Save-CleanupReport
    Write-Host 'Recognized legacy startup and sharing cleanup completed. Windows folders now use local paths; no documents were moved or deleted.'
    Write-Host ('Private rollback inventory and quarantined agent: ' + $backup)
    Write-Host 'Sign out or restart Windows to discard any old connections retained by the unelevated desktop session.'
    if ($report.restartRequired) { Write-Host 'Parallels Tools uninstaller completed; restart Windows before evaluating remaining drivers or Shell icons.' }
    if ($InstallBridge) { & (Join-Path $PSScriptRoot 'install.ps1') }
} catch {
    $report.error=$_.Exception.Message; Save-CleanupReport; throw
} finally { Stop-Transcript | Out-Null }
