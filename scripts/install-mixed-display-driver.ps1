# Select one original signed driver on one explicit PCI instance. Run elevated
# on a prepared N+1 VM. After staging, pass the original INF in DriverStore;
# installing directly from CD failed with 0xe0000217 in the main qualification.
param(
 [Parameter(Mandatory=$true)][string]$InstanceId,
 [Parameter(Mandatory=$true)][ValidateSet('Accelerated','AppDisplay')][string]$Role,
 [Parameter(Mandatory=$true)][string]$InfPath
)
$ErrorActionPreference='Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Elevation required'}
$expected = if ($Role -eq 'Accelerated') {
 @{Subsystem='1101'; Hash='22DCA43CB82E02EB1467EFFA0EA8E3288DA0C8A07B99C6E3BD95A79B98F92545'; Service='VioGpu3D'}
} else {
 @{Subsystem='1100'; Hash='849CFEFA9364B4A3E80DD44CE898E3B4766AF5C4A475EA0A95DDB4C9F1CB2E4B'; Service='VioGpuDod'}
}
$device=Get-PnpDevice -InstanceId $InstanceId
$hardware=@((Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_HardwareIds).Data)
if ($device.Class -ne 'Display' -or $InstanceId -notlike 'PCI\VEN_1AF4&DEV_1050*' -or
    -not ($hardware -match ('^PCI\\VEN_1AF4&DEV_1050&SUBSYS_'+$expected.Subsystem+'1AF4(&|$)'))) {throw 'Device does not match this display role'}
$inf=(Resolve-Path -LiteralPath $InfPath).Path
if ((Get-FileHash -LiteralPath $inf -Algorithm SHA256).Hash -ne $expected.Hash) {throw 'Not the original qualified ARM64 INF'}

# Staging does not use /install, which would update every matching device.
& pnputil.exe /add-driver $inf
if ($LASTEXITCODE -ne 0) {throw "Driver staging failed: $LASTEXITCODE"}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PerpendicularDisplayInstall {
 [StructLayout(LayoutKind.Sequential)] public struct Dev { public int cb; public Guid guid; public uint inst; public IntPtr reserved; }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct Params { public int cb; public uint flags,ex; public IntPtr parent,callback,context,queue,reserved; public uint reserved2; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string path; }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct Driver { public int cb; public uint type; public IntPtr reserved; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string description; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string mfg; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string provider; public System.Runtime.InteropServices.ComTypes.FILETIME date; public ulong version; }
 [DllImport("setupapi.dll",SetLastError=true)] static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr cls,IntPtr parent);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiOpenDeviceInfoW(IntPtr set,string id,IntPtr parent,uint flags,ref Dev dev);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInstallParamsW(IntPtr set,ref Dev dev,ref Params args);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiSetDeviceInstallParamsW(IntPtr set,ref Dev dev,ref Params args);
 [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiBuildDriverInfoList(IntPtr set,ref Dev dev,uint type);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiEnumDriverInfoW(IntPtr set,ref Dev dev,uint type,uint index,ref Driver driver);
 [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiSetSelectedDriverW(IntPtr set,ref Dev dev,ref Driver driver);
 [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiCallClassInstaller(uint function,IntPtr set,ref Dev dev);
 [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDriverInfoList(IntPtr set,ref Dev dev,uint type);
 [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
 static void Check(bool ok,string stage) {if(!ok) throw new Exception(stage+" error 0x"+Marshal.GetLastWin32Error().ToString("x"));}
 public static uint Run(string id,string inf) {
  IntPtr set=SetupDiCreateDeviceInfoList(IntPtr.Zero,IntPtr.Zero);
  if(set==new IntPtr(-1)) throw new Exception("Create device list");
  Dev d=new Dev(); d.cb=Marshal.SizeOf(typeof(Dev)); bool built=false;
  try {
   Check(SetupDiOpenDeviceInfoW(set,id,IntPtr.Zero,0,ref d),"Open device");
   Params p=new Params(); p.cb=Marshal.SizeOf(typeof(Params));
   Check(SetupDiGetDeviceInstallParamsW(set,ref d,ref p),"Read parameters");
   p.flags |= 0x10000; p.path=inf; // DI_ENUMSINGLEINF
   Check(SetupDiSetDeviceInstallParamsW(set,ref d,ref p),"Select INF");
   Check(SetupDiBuildDriverInfoList(set,ref d,1),"Build driver list"); built=true;
   Driver v=new Driver(); v.cb=Marshal.SizeOf(typeof(Driver));
   Check(SetupDiEnumDriverInfoW(set,ref d,1,0,ref v),"Read driver");
   Check(SetupDiSetSelectedDriverW(set,ref d,ref v),"Select driver");
   // Use the supported class installer, not DiInstallDevice (which updated
   // both adapters in the trial), nor the class installer's default handler.
   Check(SetupDiCallClassInstaller(2,set,ref d),"Install selected device");
   Check(SetupDiGetDeviceInstallParamsW(set,ref d,ref p),"Read restart flags");
   return p.flags & 0x180; // DI_NEEDRESTART | DI_NEEDREBOOT
  } finally {
   if(built) SetupDiDestroyDriverInfoList(set,ref d,1);
   SetupDiDestroyDeviceInfoList(set);
  }
 }
}
'@
$restartFlags=[PerpendicularDisplayInstall]::Run($InstanceId,$inf)
$service=(Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_Service).Data
$problem=(Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_ProblemCode).Data
if ($service -ne $expected.Service) {throw "Selected driver not observed: $service, problem=$problem"}
[pscustomobject]@{InstanceId=$InstanceId;Role=$Role;Service=$service;Problem=$problem;RestartFlags=$restartFlags;InfSHA256=$expected.Hash} | ConvertTo-Json
# Zero installer flags are not proof of a successful subsequent boot or pixels.
