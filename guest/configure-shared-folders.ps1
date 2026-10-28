param(
 [Parameter(Mandatory=$true)][ValidateSet('desktop','documents','downloads','pictures','music','videos')][string]$Folder,
 [switch]$Disable
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.IsSystem -or ![Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Folder setup requires the installation user with normal administration.'}
$definitions=@{
 desktop=@('B4BFCC3A-DB2C-424C-B029-7FE99A87C641','Desktop','PerpendicularFolderDesktop')
 documents=@('FDD39AD0-238F-46AF-ADB4-6C85480369C7','Documents','PerpendicularFolderDocuments')
 downloads=@('374DE290-123F-4565-9164-39C4925E467B','Downloads','VirtioFsSvc')
 pictures=@('33E28130-4E1E-4676-835A-98395C3BC3BB','Pictures','PerpendicularFolderPictures')
 music=@('4BD8D571-6D19-48D3-BE97-422220080E43','Music','PerpendicularFolderMusic')
 videos=@('18989B1D-99B5-455B-841C-AB7C74E4DDFC','Videos','PerpendicularFolderVideos')
}
$definition=$definitions[$Folder];$id=[Guid]$definition[0];$remote='\\10.0.2.4\'+$definition[1]
Add-Type -AssemblyName System.ServiceProcess
Add-Type @'
using System;using System.Text;using System.ComponentModel;using System.Runtime.InteropServices;
public static class SharedFolderNative {
[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateSymbolicLink(string link,string target,uint flags);
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


public static bool RemoveOwnedLink(string path,string remote) {return OwnedLink(path,remote,true);}
public static bool IsOwnedLink(string path,string remote) {return OwnedLink(path,remote,false);}
static bool OwnedLink(string path,string remote,bool remove) {
 var file=CreateFile(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
 if(file==new IntPtr(-1)) return false;
 try {
  var data=new byte[16384];uint count;
  if(!DeviceIoControl(file,0x900a8,IntPtr.Zero,0,data,(uint)data.Length,out count,IntPtr.Zero)) return false;
  if(count<20 || BitConverter.ToUInt32(data,0)!=0xa000000c) throw new InvalidOperationException("An unrelated directory link must not be replaced.");
  var offset=20+BitConverter.ToUInt16(data,8);var length=BitConverter.ToUInt16(data,10);
  if(offset+length>count || length%2!=0) throw new InvalidOperationException("Invalid directory link.");
  var target=Encoding.Unicode.GetString(data,offset,length).TrimEnd('\\');
  var expected=@"\??\UNC\"+remote.TrimStart('\\');
  if(!target.Equals(expected,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("An unrelated directory link must not be replaced.");
 } finally {CloseHandle(file);}
 if(remove && !RemoveDirectory(path)) throw new Win32Exception();
 return true;
}
}

'@
function Read-Known([uint32]$flags){
 $pointer=[IntPtr]::Zero;$hr=[SharedFolderNative]::SHGetKnownFolderPath([ref]$id,$flags,[IntPtr]::Zero,[ref]$pointer)
 if($hr -ne 0){throw "Cannot resolve Windows folder: $hr"}
 try{return [IO.Path]::GetFullPath([Runtime.InteropServices.Marshal]::PtrToStringUni($pointer))}finally{[Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer)}
}
function Set-Known([string]$path){if([SharedFolderNative]::SHSetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,$path) -ne 0){throw 'Cannot set Windows folder location.'}}
$profile=[IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')+'\'
$stateRoot=Join-Path $env:ProgramData ('Perpendicular\SharedFolders\'+$identity.User.Value)
$stateFile=Join-Path $stateRoot ($Folder+'.json')
# Shell can wait indefinitely on the previous provider even with DONT_VERIFY.
# Recover an already managed path from its protected per-user record first;
# the ownership, profile and reparse-point checks below still apply.
if([IO.File]::Exists($stateFile)){
 $saved=[IO.File]::ReadAllText($stateFile)|ConvertFrom-Json
 if($saved.schema -notin @(1,2) -or $saved.sid -ne $identity.User.Value -or $saved.folder -ne $Folder){throw 'Folder recovery state differs from this profile.'}
 $path=[IO.Path]::GetFullPath($saved.path);$oldKnown=[IO.Path]::GetFullPath($saved.originalKnown)
}else{$path=Read-Known 0x4400;$oldKnown=Read-Known 0x4000}
if(!$path.StartsWith($profile,[StringComparison]::OrdinalIgnoreCase) -or $path -eq $profile.TrimEnd('\')){throw 'Only personal profile folders may be configured.'}
if(!$Disable -and ![IO.Directory]::Exists($remote)){throw 'The selected Mac folder is not available over the private connection.'}
[void][IO.Directory]::CreateDirectory($stateRoot)
$lock=[IO.FileStream]::new((Join-Path $stateRoot ($Folder+'.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
 $old=$null
 if([IO.File]::Exists($stateFile)){
  $old=Get-Content $stateFile -Raw|ConvertFrom-Json
  $old.path=[IO.Path]::GetFullPath($old.path);$old.originalKnown=[IO.Path]::GetFullPath($old.originalKnown)
 }
 # The previous single-folder layout is decoded only to preserve original data.
 if(!$old -and $Folder -eq 'downloads' -and [IO.File]::Exists((Join-Path $env:ProgramData 'Perpendicular\SharedDownloads\directory-layout.json'))){
  $legacy=Get-Content (Join-Path $env:ProgramData 'Perpendicular\SharedDownloads\directory-layout.json') -Raw|ConvertFrom-Json
  if($legacy.sid -ne $identity.User.Value -or $legacy.downloads -ne $path){throw 'The previous folder belongs to another profile.'}
  $old=[pscustomobject]@{schema=1;sid=$identity.User.Value;folder=$Folder;path=$path;originalKnown=$path;localBackup=$legacy.originalDirectoryBackup;recoveredLocalDirectories=@()}
 }
 if($old -and ($old.schema -notin @(1,2) -or $old.sid -ne $identity.User.Value -or $old.folder -ne $Folder -or $old.path -ne $path)){throw 'Folder recovery state differs from this profile.'}
 $record=[pscustomobject]@{schema=2;backend='smb';sid=$identity.User.Value;folder=$Folder;path=$path;originalKnown=$path;localBackup=(Join-Path $stateRoot ($Folder+'-local'));phase='local';recoveredLocalDirectories=@()}
 if($old){$record.originalKnown=$old.originalKnown;$record.localBackup=$old.localBackup;$record.recoveredLocalDirectories=@($old.recoveredLocalDirectories)}
 elseif($oldKnown.StartsWith($profile,[StringComparison]::OrdinalIgnoreCase)){$record.originalKnown=$oldKnown}
 $backup=[IO.Path]::GetFullPath($record.localBackup)
 $legacyPrefix=Join-Path $env:ProgramData ('Perpendicular\SharedDownloads\OriginalDownloads-'+$identity.User.Value+'-')
 if(!$backup.StartsWith($stateRoot+'\',[StringComparison]::OrdinalIgnoreCase) -and !($Folder -eq 'downloads' -and $backup.StartsWith($legacyPrefix,[StringComparison]::OrdinalIgnoreCase))){throw 'Recovery directory is outside managed data.'}
 if(!$record.originalKnown.StartsWith($profile,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetPathRoot($path) -ne [IO.Path]::GetPathRoot($backup)){throw 'Invalid original folder location.'}
 function Save-State {
  $temp=$stateFile+'.'+[Guid]::NewGuid().ToString('N')+'.tmp';[IO.File]::WriteAllText($temp,($record|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  if(![SharedFolderNative]::MoveFileEx($temp,$stateFile,9)){throw [ComponentModel.Win32Exception]::new()}
 }
 function Preserve-Local {
  if(![IO.Directory]::Exists($path)){return}
  if(([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'An unrelated directory link must not be moved.'}
  if(![IO.Directory]::Exists($backup)){[IO.Directory]::Move($path,$backup)}
  else{$recovery=Join-Path $stateRoot ($Folder+'-recovered-'+[Guid]::NewGuid().ToString('N'));$record.recoveredLocalDirectories+=@($recovery);Save-State;[IO.Directory]::Move($path,$recovery)}
 }
 # Transitional cleanup only: stop an owned previous client before touching its
 # mount point. No old transport or Windows filesystem driver is installed.
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\'+$definition[2])
 if($key){
  try{$image=$key.GetValue('ImagePath')}finally{$key.Close()}
  if(!$image.StartsWith('"C:\Program Files\Perpendicular Shared Files\virtiofs.exe"',[StringComparison]::OrdinalIgnoreCase)){throw 'An unrelated folder service must not be changed.'}
  $service=[ServiceProcess.ServiceController]::new($definition[2]);try{if($service.Status -ne 'Stopped'){$service.Stop();$service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(15))}}finally{$service.Dispose()}
  [SharedFolderNative]::RemoveStaleMount($path)
 }
 $isLink=[SharedFolderNative]::IsOwnedLink($path,$remote)
 if($isLink -and !$Disable -and [SharedFolderNative]::IsOwnedLink($path,$remote)){Set-Known $path;$record.phase='shared';Save-State;Write-Output ('PERP_FOLDER_READY:'+$Folder+':shared');return}
 if($isLink){[void][SharedFolderNative]::RemoveOwnedLink($path,$remote)}
 if($Disable){
  if(!$old -and !$key){Write-Output ('PERP_FOLDER_READY:'+$Folder+':local');return}
  $record.phase='disabling';Save-State
  if([IO.Directory]::Exists($backup)){Preserve-Local;[IO.Directory]::Move($backup,$path)}
  elseif(![IO.Directory]::Exists($path)){[void][IO.Directory]::CreateDirectory($path)}
  Set-Known $record.originalKnown;$record.phase='local';Save-State
 }else{
  $record.phase='enabling';Save-State;Preserve-Local
  try {
   if(![SharedFolderNative]::CreateSymbolicLink($path,$remote,1)){throw [ComponentModel.Win32Exception]::new()}
   if(![IO.Directory]::Exists($path)){throw 'Windows cannot access the prepared Mac folder.'}
   Set-Known $path;$record.phase='shared';Save-State
  }catch{
   $failure=$_
   try{[void][SharedFolderNative]::RemoveOwnedLink($path,$remote);if(![IO.Directory]::Exists($path) -and [IO.Directory]::Exists($backup)){[IO.Directory]::Move($backup,$path)};Set-Known $record.originalKnown;$record.phase='local';Save-State}catch{Write-Warning 'Preserved local files remain in the recovery directory.'}
   throw $failure
  }
 }
 $result=[IntPtr]::Zero;[void][SharedFolderNative]::SendMessageTimeout([IntPtr]0xffff,0x1a,[IntPtr]::Zero,'User Shell Folders',2,1000,[ref]$result)
 [SharedFolderNative]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
 Write-Output ('PERP_FOLDER_READY:'+$Folder+':'+$(if($Disable){'local'}else{'shared'}))
}finally{$lock.Dispose()}
