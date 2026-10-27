$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsSystem) {throw 'Run Downloads integration as the interactive Windows user, not SYSTEM.'}
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run Downloads integration as administrator.'}
$state=Join-Path $env:ProgramData 'Perpendicular\SharedDownloads'
$executable=Join-Path $env:ProgramFiles 'Perpendicular Shared Files\virtiofs.exe'
if (!(Test-Path $executable)) {throw 'Install the signed shared-folder components first.'}
New-Item -ItemType Directory -Force $state | Out-Null
Add-Type -AssemblyName System.ServiceProcess
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SharedDownloadsFolder {
[DllImport("shell32.dll",CharSet=CharSet.Unicode)]
public static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
[DllImport("shell32.dll",CharSet=CharSet.Unicode)]
public static extern int SHSetKnownFolderPath(ref Guid id,uint flags,IntPtr token,string path);
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(uint change,uint flags,IntPtr a,IntPtr b);
[DllImport("user32.dll",CharSet=CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,IntPtr wParam,string lParam,uint flags,uint timeout,out IntPtr result);
[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
static extern IntPtr OpenSCManager(string machine,string database,uint access);
[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
static extern IntPtr OpenService(IntPtr manager,string name,uint access);
[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
static extern IntPtr CreateService(IntPtr manager,string name,string display,uint access,uint type,uint start,uint error,string binary,string group,IntPtr tag,string dependencies,string account,string password);
[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
static extern bool ChangeServiceConfig(IntPtr service,uint type,uint start,uint error,string binary,string group,IntPtr tag,string dependencies,string account,string password,string display);
[DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr handle);
public static void Configure(string binary,uint start) {
 var manager=OpenSCManager(null,null,3);
 if(manager==IntPtr.Zero) throw new Win32Exception();
 IntPtr service=IntPtr.Zero;
 try {
  service=OpenService(manager,"VirtioFsSvc",2);
  if(service==IntPtr.Zero) {
   if(Marshal.GetLastWin32Error()!=1060) throw new Win32Exception();
   service=CreateService(manager,"VirtioFsSvc","Perpendicular Folder Integration",2,16,start,1,binary,null,IntPtr.Zero,"VirtioFsDrv\0\0",null,null);
   if(service==IntPtr.Zero) throw new Win32Exception();
  } else if(!ChangeServiceConfig(service,0xffffffff,start,0xffffffff,binary,null,IntPtr.Zero,null,null,null,null)) throw new Win32Exception();
 } finally {if(service!=IntPtr.Zero) CloseServiceHandle(service);CloseServiceHandle(manager);}
}
}
'@
$id=[Guid]'374DE290-123F-4565-9164-39C4925E467B'
function Read-Downloads([uint32]$flags) {
    $pointer=[IntPtr]::Zero
    $hr=[SharedDownloadsFolder]::SHGetKnownFolderPath([ref]$id,$flags,[IntPtr]::Zero,[ref]$pointer)
    if ($hr -ne 0) {throw "Cannot read Downloads: $hr"}
    try {return [IO.Path]::GetFullPath([Runtime.InteropServices.Marshal]::PtrToStringUni($pointer))}
    finally {[Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer)}
}
# Resolve paths even when a stopped service has removed its mount directory.
$old=Read-Downloads 0x4000 # KF_FLAG_DONT_VERIFY
$downloads=Read-Downloads 0x4400 # DONT_VERIFY | DEFAULT_PATH
$profile=[IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')+'\'
if (!$downloads.StartsWith($profile,[StringComparison]::OrdinalIgnoreCase) -or $downloads -eq $profile.TrimEnd('\')) {throw 'Downloads must be a directory inside the interactive user profile.'}
$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\VirtioFsSvc')
$priorImage=$null;$priorStart=3
if ($key) {$priorImage=$key.GetValue('ImagePath');$priorStart=$key.GetValue('Start');$key.Close()}
if ($priorImage -and !$priorImage.StartsWith(('"'+$executable+'"'),[StringComparison]::OrdinalIgnoreCase)) {throw 'An unrelated shared-folder service already exists.'}
$binary='"'+$executable+'" -t mac-downloads -m "'+$downloads+'" -o 501:20 -i -F NTFS'
$layoutFile=Join-Path $state 'directory-layout.json'
$layout=$null
if (Test-Path $layoutFile) {
    $layout=Get-Content $layoutFile -Raw | ConvertFrom-Json
    if ($layout.sid -ne $identity.User.Value -or $layout.downloads -ne $downloads) {throw 'Shared Downloads is configured for another profile.'}
}
$moved=$false;$backup=$null;$service=$null
try {
    if ($priorImage) {
        $service=[ServiceProcess.ServiceController]::new('VirtioFsSvc')
        if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
            $service.Stop();$service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(20))
        }
    }
    if ([IO.Directory]::Exists($downloads)) {
        if (([IO.File]::GetAttributes($downloads) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {throw 'An existing directory link must not be overwritten.'}
        $backup=Join-Path $state ('OriginalDownloads-'+$identity.User.Value+'-'+[Guid]::NewGuid().ToString('N'))
        if ([IO.Path]::GetPathRoot($downloads) -ne [IO.Path]::GetPathRoot($backup)) {throw 'The local Downloads backup must stay on the same Windows volume.'}
        $entries=@([IO.Directory]::GetFileSystemEntries($downloads) | ForEach-Object {[IO.Path]::GetFileName($_)})
        # Rename the existing directory intact; never merge or overwrite user files.
        [IO.Directory]::Move($downloads,$backup);$moved=$true
    } else {$entries=@()}
    $pending=@{sid=$identity.User.Value;downloads=$downloads;previousDownloads=$old;originalDirectoryBackup=$backup;originalEntries=$entries;previousImagePath=$priorImage;previousStart=$priorStart;created=(Get-Date).ToString('o')}
    if (!$layout) {$pending | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $state 'directory-layout-pending.json') -Encoding UTF8}
    [SharedDownloadsFolder]::Configure($binary,2)
    $registry=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\VirtIO-FS')
    try {$registry.SetValue('MountPoint',$downloads,[Microsoft.Win32.RegistryValueKind]::String)} finally {$registry.Close()}
    $service=[ServiceProcess.ServiceController]::new('VirtioFsSvc');$service.Start()
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(20))
    # The service can report Running before WinFsp publishes its directory.
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while (![IO.Directory]::Exists($downloads) -and [DateTime]::UtcNow -lt $deadline) {
        $service.Refresh()
        if ($service.Status -eq [ServiceProcess.ServiceControllerStatus]::Stopped) {throw 'The shared-folder service stopped before publishing Downloads.'}
        [Threading.Thread]::Sleep(100)
    }
    if (![IO.Directory]::Exists($downloads)) {throw 'The Mac folder is not mounted at the normal Downloads location.'}
    $hr=[SharedDownloadsFolder]::SHSetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,$downloads)
    if ($hr -ne 0) {throw "Cannot restore the normal Downloads location: $hr"}
    if (!$layout) {$pending | ConvertTo-Json -Depth 5 | Set-Content $layoutFile -Encoding UTF8}
    elseif ($moved) {$pending | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $state ('directory-recovery-'+[Guid]::NewGuid().ToString('N')+'.json')) -Encoding UTF8}
    @{installed=$true;downloads=$downloads;directoryMount=$true;driveLetterAssigned=$false;service='Running'} | ConvertTo-Json | Set-Content (Join-Path $state 'installed.json') -Encoding UTF8
    & sc.exe failure VirtioFsSvc reset= 60 actions= restart/3000/restart/10000/restart/30000 | Out-Null
} catch {
    $failure=$_
    try {
        if ($service) {$service.Refresh();if($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped){$service.Stop();$service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(20))}}
        if ($moved -and ![IO.Directory]::Exists($downloads)) {[IO.Directory]::Move($backup,$downloads)}
        if ($priorImage) {
            [SharedDownloadsFolder]::Configure($priorImage,$priorStart)
            $service=[ServiceProcess.ServiceController]::new('VirtioFsSvc');$service.Start()
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(20))
        }
        [void][SharedDownloadsFolder]::SHSetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,$old)
    } catch {Write-Warning ('Recovery needs attention; original files are preserved at '+$backup+': '+$_)}
    throw $failure
} finally {if($service){$service.Dispose()}}
# Remove only address history for the drive assigned by the old layout.
# Preserve every other entry and its order; do not clear user shell history.
$previous=if($layout){$layout.previousDownloads}else{$old}
$legacyRoot=[IO.Path]::GetPathRoot($previous)
if ($previous.TrimEnd('\') -eq $legacyRoot.TrimEnd('\') -and $legacyRoot -ne [IO.Path]::GetPathRoot($downloads)) {
    $history=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths',$true)
    if ($history) {
        try {
            $names=@($history.GetValueNames() | Where-Object {$_ -match '^url[0-9]+$'} | Sort-Object {[int]$_.Substring(3)})
            $keep=@($names | ForEach-Object {$history.GetValue($_)} | Where-Object {!$_.StartsWith($legacyRoot,[StringComparison]::OrdinalIgnoreCase)})
            foreach($name in $names){$history.DeleteValue($name)}
            for($index=0;$index -lt $keep.Count;$index++){$history.SetValue(('url'+($index+1)),$keep[$index],[Microsoft.Win32.RegistryValueKind]::String)}
        } finally {$history.Close()}
    }
}
$result=[IntPtr]::Zero
[void][SharedDownloadsFolder]::SendMessageTimeout([IntPtr]0xffff,0x1a,[IntPtr]::Zero,'User Shell Folders',2,2000,[ref]$result)
[SharedDownloadsFolder]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
Write-Output 'Downloads uses the Mac files through the normal Windows user folder. No additional drive is assigned.'
