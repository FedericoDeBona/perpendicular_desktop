$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsSystem) {throw 'Run Downloads redirection as the interactive Windows user, not SYSTEM.'}
if (!(Test-Path 'X:\')) {throw 'The Mac Downloads volume is not mounted.'}
$state=Join-Path $env:ProgramData 'Perpendicular\SharedDownloads'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SharedDownloadsFolder {
[DllImport("shell32.dll",CharSet=CharSet.Unicode)]
public static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
[DllImport("shell32.dll",CharSet=CharSet.Unicode)]
public static extern int SHSetKnownFolderPath(ref Guid id,uint flags,IntPtr token,string path);
[DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
public static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,IntPtr wParam,string lParam,uint flags,uint timeout,out IntPtr result);
}
'@
$id=[Guid]'374DE290-123F-4565-9164-39C4925E467B'
$pointer=[IntPtr]::Zero
$hr=[SharedDownloadsFolder]::SHGetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,[ref]$pointer)
if ($hr -ne 0) {throw "Cannot read Downloads: $hr"}
try {$old=[Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)}
finally {[Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer)}
$backup=Join-Path $state 'downloads-before.json'
if (!(Test-Path $backup)) {
    @{sid=$identity.User.Value;path=$old;created=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content $backup -Encoding UTF8
}
$hr=[SharedDownloadsFolder]::SHSetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,'X:\')
if ($hr -ne 0) {throw "Cannot redirect Downloads: $hr"}
$result=[IntPtr]::Zero
[void][SharedDownloadsFolder]::SendMessageTimeout([IntPtr]0xffff,0x1a,[IntPtr]::Zero,'User Shell Folders',2,2000,[ref]$result)
@{installed=$true;downloads='X:\';previousDownloads=$old;filesMoved=$false;service=(Get-Service VirtioFsSvc).Status.ToString()} | ConvertTo-Json | Set-Content (Join-Path $state 'installed.json') -Encoding UTF8
Write-Output 'Mac Downloads is mounted and the Windows Downloads folder points to X:\. Existing Windows downloads were preserved in their original directory.'
