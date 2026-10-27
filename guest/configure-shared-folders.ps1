param(
    [Parameter(Mandatory=$true)][ValidateSet('desktop','documents','downloads','pictures','music','videos')][string]$Folder,
    [ValidatePattern('^[0-9]+:[0-9]+$')][string]$Owner='501:20',
    [switch]$Disable
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.IsSystem){throw 'Folder integration must run in the installed interactive user profile.'}
if(![Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Folder setup requires the Windows installation administrator.'}
$definitions=@{
 desktop=@('B4BFCC3A-DB2C-424C-B029-7FE99A87C641','Desktop','PerpendicularFolderDesktop')
 documents=@('FDD39AD0-238F-46AF-ADB4-6C85480369C7','Documents','PerpendicularFolderDocuments')
 downloads=@('374DE290-123F-4565-9164-39C4925E467B','Downloads','VirtioFsSvc')
 pictures=@('33E28130-4E1E-4676-835A-98395C3BC3BB','Pictures','PerpendicularFolderPictures')
 music=@('4BD8D571-6D19-48D3-BE97-422220080E43','Music','PerpendicularFolderMusic')
 videos=@('18989B1D-99B5-455B-841C-AB7C74E4DDFC','Videos','PerpendicularFolderVideos')
}
$definition=$definitions[$Folder];$id=[Guid]$definition[0];$serviceName=$definition[2];$tag='mac-'+$Folder
$exe=Join-Path $env:ProgramFiles 'Perpendicular Shared Files\virtiofs.exe'
if(![IO.File]::Exists($exe)){throw 'The signed shared-folder components are not installed.'}
$sha=[Security.Cryptography.SHA256]::Create()
try{$actual=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($exe))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
if($actual -ne 'c9371f1a2ed15c53c3c34a21cc1eec0fca63088135ef1e239876b354abe74a8f'){throw 'The installed folder client differs from the signed package.'}
Add-Type -AssemblyName System.ServiceProcess
Add-Type @'
using System;using System.Text;using System.ComponentModel;using System.Runtime.InteropServices;
public static class SharedFolderNative {
[DllImport("shell32.dll",CharSet=CharSet.Unicode)] public static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
[DllImport("shell32.dll",CharSet=CharSet.Unicode)] public static extern int SHSetKnownFolderPath(ref Guid id,uint flags,IntPtr token,string path);
[DllImport("shell32.dll")] public static extern void SHChangeNotify(uint change,uint flags,IntPtr a,IntPtr b);
[DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,IntPtr wParam,string value,uint flags,uint timeout,out IntPtr result);
[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool GetVolumeInformation(string path,StringBuilder label,uint capacity,out uint serial,out uint maximum,out uint flags,StringBuilder filesystem,uint filesystemCapacity);
[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool MoveFileEx(string source,string target,uint flags);
[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
[DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(IntPtr file,uint code,IntPtr input,uint inputSize,byte[] output,uint outputSize,out uint returned,IntPtr overlapped);
[DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool RemoveDirectory(string path);
// Remove only a dead WinFsp mount point at an already owned service path.
// OPEN_REPARSE_POINT reads the link itself; no target contents are traversed.
public static void RemoveStaleMount(string path) {
 var label=new StringBuilder(100);var fs=new StringBuilder(100);uint serial,maximum,flags;
 if(GetVolumeInformation(path.TrimEnd('\\')+"\\",label,100,out serial,out maximum,out flags,fs,100)) return;
 var error=Marshal.GetLastWin32Error();
 if(error!=2 && error!=3 && error!=21 && error!=55 && error!=1167 && error!=433) return;
 var file=CreateFile(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
 if(file==new IntPtr(-1)) return;
 string target=null;
 try {
  var data=new byte[16384];uint count;
  if(!DeviceIoControl(file,0x900a8,IntPtr.Zero,0,data,(uint)data.Length,out count,IntPtr.Zero)) return;
  if(count<16 || BitConverter.ToUInt32(data,0)!=0xa0000003) return;
  var offset=16+BitConverter.ToUInt16(data,8);var length=BitConverter.ToUInt16(data,10);
  if(offset+length>count || length%2!=0) return;
  target=Encoding.Unicode.GetString(data,offset,length).TrimEnd('\\');
 } finally {CloseHandle(file);}
 var prefix=@"\Device\Volume{";Guid guid;
 if(target==null || !target.StartsWith(prefix,StringComparison.OrdinalIgnoreCase) || !Guid.TryParse(target.Substring(prefix.Length-1),out guid)) return;
 if(!RemoveDirectory(path)) throw new Win32Exception();
}

[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenSCManager(string machine,string database,uint access);
[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenService(IntPtr manager,string name,uint access);
[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateService(IntPtr manager,string name,string display,uint access,uint type,uint start,uint error,string binary,string group,IntPtr tag,string dependencies,string account,string password);
[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ChangeServiceConfig(IntPtr service,uint type,uint start,uint error,string binary,string group,IntPtr tag,string dependencies,string account,string password,string display);
[DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr handle);
public static void Configure(string name,string display,string binary,uint start) {
 var manager=OpenSCManager(null,null,3);if(manager==IntPtr.Zero) throw new Win32Exception();IntPtr service=IntPtr.Zero;
 try {
  service=OpenService(manager,name,2);
  if(service==IntPtr.Zero) {
   if(Marshal.GetLastWin32Error()!=1060) throw new Win32Exception();
   service=CreateService(manager,name,display,2,16,start,1,binary,null,IntPtr.Zero,"VirtioFsDrv\0\0",null,null);
   if(service==IntPtr.Zero) throw new Win32Exception();
  } else if(!ChangeServiceConfig(service,0xffffffff,start,0xffffffff,binary,null,IntPtr.Zero,null,null,null,display)) throw new Win32Exception();
 } finally {if(service!=IntPtr.Zero) CloseServiceHandle(service);CloseServiceHandle(manager);}
}
}
'@
function Read-Known([uint32]$flags){
 $pointer=[IntPtr]::Zero;$hr=[SharedFolderNative]::SHGetKnownFolderPath([ref]$id,$flags,[IntPtr]::Zero,[ref]$pointer)
 if($hr -ne 0){throw "Cannot resolve the Windows folder: $hr"}
 try{return [IO.Path]::GetFullPath([Runtime.InteropServices.Marshal]::PtrToStringUni($pointer))}finally{[Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer)}
}
function Set-Known([string]$path){
 $hr=[SharedFolderNative]::SHSetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,$path)
 if($hr -ne 0){throw "Cannot set the Windows folder location: $hr"}
}
function Volume-Label([string]$path){
 $label=[Text.StringBuilder]::new(100);$fs=[Text.StringBuilder]::new(100);$serial=[uint32]0;$maximum=[uint32]0;$flags=[uint32]0
 if([SharedFolderNative]::GetVolumeInformation($path.TrimEnd('\')+'\',$label,100,[ref]$serial,[ref]$maximum,[ref]$flags,$fs,100)){return $label.ToString()}
 return ''
}
$path=Read-Known 0x4400;$oldKnown=Read-Known 0x4000
$profile=[IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')+'\'
if(!$path.StartsWith($profile,[StringComparison]::OrdinalIgnoreCase) -or $path -eq $profile.TrimEnd('\')){throw 'Only the standard personal profile folders may be configured.'}
$stateRoot=Join-Path $env:ProgramData ('Perpendicular\SharedFolders\'+$identity.User.Value)
[void][IO.Directory]::CreateDirectory($stateRoot)
$stateFile=Join-Path $stateRoot ($Folder+'.json')
$lock=[IO.FileStream]::new((Join-Path $stateRoot ($Folder+'.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$service=$null
try {
 function Save-State {
  $temporary=$stateFile+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
  [IO.File]::WriteAllText($temporary,($script:record | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  if(![SharedFolderNative]::MoveFileEx($temporary,$stateFile,9)){throw [ComponentModel.Win32Exception]::new()}
 }
 function Stop-OwnedService {
  if(!$script:priorImage){return}
  $script:service=[ServiceProcess.ServiceController]::new($serviceName);$script:service.Refresh()
  if($script:service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped){$script:service.Stop();$script:service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(15))}
  $until=[DateTime]::UtcNow.AddSeconds(10)
  while((Volume-Label $path) -eq $tag -and [DateTime]::UtcNow -lt $until){[Threading.Thread]::Sleep(100)}
  if((Volume-Label $path) -eq $tag){throw 'The shared folder has not finished closing; local data has not been moved.'}
  [SharedFolderNative]::RemoveStaleMount($path)
 }
 function Move-LocalAside {
  if(![IO.Directory]::Exists($path)){return}
  if((Volume-Label $path).StartsWith('mac-',[StringComparison]::OrdinalIgnoreCase)){throw 'An active shared folder must never be moved as local data.'}
  if(([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'An unrelated directory link must not be replaced.'}
  if(![IO.Directory]::Exists($script:record.localBackup)){
   [IO.Directory]::Move($path,$script:record.localBackup)
  }else{
   # Preserve files created locally during a disconnected boot without merging.
   $recovery=Join-Path $stateRoot ($Folder+'-recovered-'+[Guid]::NewGuid().ToString('N'))
   $script:record.recoveredLocalDirectories=@($script:record.recoveredLocalDirectories)+@($recovery);Save-State
   [IO.Directory]::Move($path,$recovery)
  }
 }
 $serviceKey=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\'+$serviceName)
 $priorImage=$null;$priorStart=3
 if($serviceKey){$priorImage=$serviceKey.GetValue('ImagePath');$priorStart=$serviceKey.GetValue('Start');$serviceKey.Close()}
 if($priorImage -and !$priorImage.StartsWith(('"'+$exe+'"'),[StringComparison]::OrdinalIgnoreCase)){throw 'An unrelated service must not be changed.'}
 $binary='"'+$exe+'" -t '+$tag+' -m "'+$path+'" -o '+$Owner+' -i -F NTFS'
 $record=$null
 if([IO.File]::Exists($stateFile)){$record=Get-Content $stateFile -Raw | ConvertFrom-Json}
 elseif($Folder -eq 'downloads' -and [IO.File]::Exists((Join-Path $env:ProgramData 'Perpendicular\SharedDownloads\directory-layout.json'))){
  $legacy=Get-Content (Join-Path $env:ProgramData 'Perpendicular\SharedDownloads\directory-layout.json') -Raw | ConvertFrom-Json
  if($legacy.sid -ne $identity.User.Value -or $legacy.downloads -ne $path){throw 'The previous Downloads layout belongs to another profile.'}
  $record=[pscustomobject]@{schema=1;sid=$identity.User.Value;folder=$Folder;path=$path;originalKnown=$path;localBackup=$legacy.originalDirectoryBackup;phase='shared';recoveredLocalDirectories=@()}
 }
 if(!$record){
  if($Disable){Write-Output ('PERP_FOLDER_READY:'+$Folder+':local');return}
  $originalKnown=if($oldKnown.StartsWith($profile,[StringComparison]::OrdinalIgnoreCase)){$oldKnown}else{$path}
  $record=[pscustomobject]@{schema=1;sid=$identity.User.Value;folder=$Folder;path=$path;originalKnown=$originalKnown;localBackup=(Join-Path $stateRoot ($Folder+'-local'));phase='local';recoveredLocalDirectories=@()}
 }
 if($record.schema -ne 1 -or $record.sid -ne $identity.User.Value -or $record.folder -ne $Folder -or $record.path -ne $path){throw 'The folder recovery record does not match this profile.'}
 $backup=[IO.Path]::GetFullPath($record.localBackup)
 $legacyPrefix=(Join-Path $env:ProgramData ('Perpendicular\SharedDownloads\OriginalDownloads-'+$identity.User.Value+'-'))
 if(!$backup.StartsWith(($stateRoot+'\'),[StringComparison]::OrdinalIgnoreCase) -and !($Folder -eq 'downloads' -and $backup.StartsWith($legacyPrefix,[StringComparison]::OrdinalIgnoreCase))){throw 'The recovery folder is outside the managed data directory.'}
 if([IO.Path]::GetPathRoot($path) -ne [IO.Path]::GetPathRoot($backup)){throw 'Local recovery must remain on the same Windows volume.'}
 if(!$record.originalKnown.StartsWith($profile,[StringComparison]::OrdinalIgnoreCase)){throw 'The previous folder location is outside this profile.'}
 if($Disable){
  $record.phase='disabling';Save-State;Stop-OwnedService
  if($priorImage){[SharedFolderNative]::Configure($serviceName,('Perpendicular '+$definition[1]),$priorImage,4)}
  if([IO.Directory]::Exists($backup)){
   if([IO.Directory]::Exists($path)){
    if((Volume-Label $path).StartsWith('mac-',[StringComparison]::OrdinalIgnoreCase)){throw 'A shared folder is still active; local restore was not attempted.'}
    $recovery=Join-Path $stateRoot ($Folder+'-recovered-'+[Guid]::NewGuid().ToString('N'))
    $record.recoveredLocalDirectories=@($record.recoveredLocalDirectories)+@($recovery);Save-State
    [IO.Directory]::Move($path,$recovery)
   }
   [IO.Directory]::Move($backup,$path)
  }elseif(![IO.Directory]::Exists($path)){[void][IO.Directory]::CreateDirectory($path)}
  Set-Known $record.originalKnown;$record.phase='local';Save-State
 }else{
  if($priorImage -eq $binary -and (Volume-Label $path) -eq $tag){
   $service=[ServiceProcess.ServiceController]::new($serviceName)
   if($service.Status -eq [ServiceProcess.ServiceControllerStatus]::Running){
    if($oldKnown -ne $path){Set-Known $path}
    $record.phase='shared';Save-State;Write-Output ('PERP_FOLDER_READY:'+$Folder+':shared');return
   }
  }
  $record.phase='enabling';Save-State;Stop-OwnedService
  try {
   Move-LocalAside
   [SharedFolderNative]::Configure($serviceName,('Perpendicular '+$definition[1]),$binary,2)
   $service=[ServiceProcess.ServiceController]::new($serviceName);$service.Start()
   $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(15))
   $until=[DateTime]::UtcNow.AddSeconds(20)
   while((Volume-Label $path) -ne $tag -and [DateTime]::UtcNow -lt $until){
    $service.Refresh();if($service.Status -eq [ServiceProcess.ServiceControllerStatus]::Stopped){throw 'The folder service stopped before publishing its mount.'}
    [Threading.Thread]::Sleep(100)
   }
   if((Volume-Label $path) -ne $tag){throw 'The expected Mac folder is not mounted.'}
   Set-Known $path;$record.phase='shared';Save-State
   & sc.exe failure $serviceName reset= 60 actions= restart/3000/restart/10000/restart/30000 | Out-Null
  }catch{
   $failure=$_
   try {
    if($service){$service.Refresh();if($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped){$service.Stop();$service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(15))}}
    if($priorImage){[SharedFolderNative]::RemoveStaleMount($path)}
    if((Volume-Label $path) -eq $tag){throw 'The shared folder is still active; recovery data was not moved.'}
    if([IO.Directory]::Exists($backup)){
     if([IO.Directory]::Exists($path)){
      if(([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'An unrelated link prevents local recovery.'}
      $recovery=Join-Path $stateRoot ($Folder+'-recovered-'+[Guid]::NewGuid().ToString('N'))
      $record.recoveredLocalDirectories=@($record.recoveredLocalDirectories)+@($recovery);Save-State
      [IO.Directory]::Move($path,$recovery)
     }
     [IO.Directory]::Move($backup,$path)
    }
    if(![IO.Directory]::Exists($path)){[void][IO.Directory]::CreateDirectory($path)}
    Set-Known $record.originalKnown;$record.phase='local';Save-State
   }catch{Write-Warning 'Folder setup failed; preserved local files remain in the recovery directory.'}
   throw $failure
  }
 }
 $result=[IntPtr]::Zero
 [void][SharedFolderNative]::SendMessageTimeout([IntPtr]0xffff,0x1a,[IntPtr]::Zero,'User Shell Folders',2,1000,[ref]$result)
 [SharedFolderNative]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
 Write-Output ('PERP_FOLDER_READY:'+$Folder+':'+$(if($Disable){'local'}else{'shared'}))
}finally{if($service){$service.Dispose()};$lock.Dispose()}
