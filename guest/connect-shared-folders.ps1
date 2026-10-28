param([Parameter(Mandatory=$true)][string]$Username,[Parameter(Mandatory=$true)][string]$Password)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($Username -notmatch '^[A-Za-z0-9_.-]{1,64}$' -or $Password -notmatch '^[0-9a-f]{64}$'){throw 'Invalid private folder credentials.'}
Add-Type @'
using System;using System.ComponentModel;using System.Runtime.InteropServices;
public static class FolderConnection {
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Credential {public uint Flags,Type;public string TargetName,Comment;public long LastWritten;public uint BlobSize;public IntPtr Blob;public uint Persist,AttributeCount;public IntPtr Attributes;public string TargetAlias,UserName;}
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Resource {public uint Scope,Type,DisplayType,Usage;public string LocalName,RemoteName,Comment,Provider;}
[DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CredWrite(ref Credential credential,uint flags);
[DllImport("mpr.dll",CharSet=CharSet.Unicode)]static extern int WNetAddConnection2(ref Resource resource,string password,string username,uint flags);
public static void Connect(string username,string password){
 var bytes=System.Text.Encoding.Unicode.GetBytes(password);var blob=Marshal.AllocHGlobal(bytes.Length);
 try{Marshal.Copy(bytes,0,blob,bytes.Length);var value=new Credential{Type=2,TargetName="10.0.2.4",BlobSize=(uint)bytes.Length,Blob=blob,Persist=2,UserName=username};if(!CredWrite(ref value,0))throw new Win32Exception();}
 finally{for(int i=0;i<bytes.Length;i++)Marshal.WriteByte(blob,i,0);Marshal.FreeHGlobal(blob);Array.Clear(bytes,0,bytes.Length);}
 // Reuse Windows' existing authenticated session, or its stored credential.
 // Passing an explicit unqualified user conflicts with automatic reconnect.
 var resource=new Resource{Type=1,RemoteName=@"\\10.0.2.4\IPC$"};var result=WNetAddConnection2(ref resource,null,null,0);if(result!=0)throw new Win32Exception(result);
}
}
'@
[FolderConnection]::Connect($Username,$Password)
