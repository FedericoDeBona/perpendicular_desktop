param([Parameter(Mandatory=$true)][string]$IcdPath)
# Diagnostic ICD call: separates loader errors from device initialization.
# These settings affect only this PowerShell process, not Windows configuration.
$env:VN_DEBUG='init,result'
$env:MESA_LOG='file'
$env:MESA_LOG_LEVEL='debug'
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class DirectICD {
 [StructLayout(LayoutKind.Sequential)] struct Info {public uint type;public IntPtr next;public uint flags;public IntPtr app;public uint layers;public IntPtr ln;public uint extensions;public IntPtr en;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryW(string p);
 [DllImport("kernel32.dll",CharSet=CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr h,string n);
 [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr h);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate IntPtr GetProc(IntPtr i,[MarshalAs(UnmanagedType.LPStr)] string n);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int Create(ref Info i,IntPtr a,out IntPtr instance);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int Enumerate(IntPtr i,ref uint count,IntPtr devices);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate void Destroy(IntPtr i,IntPtr a);
 public static string Run(string path) {
  IntPtr h=LoadLibraryW(path);if(h==IntPtr.Zero)return "Load failed="+Marshal.GetLastWin32Error();
  IntPtr inst=IntPtr.Zero;GetProc gp=null;
  try {
   gp=(GetProc)Marshal.GetDelegateForFunctionPointer(GetProcAddress(h,"vk_icdGetInstanceProcAddr"),typeof(GetProc));
   var c=(Create)Marshal.GetDelegateForFunctionPointer(gp(IntPtr.Zero,"vkCreateInstance"),typeof(Create));
   var info=new Info();info.type=1;int rc=c(ref info,IntPtr.Zero,out inst);string result="DIRECT_VK_CREATE="+rc;
   if(rc==0){var e=(Enumerate)Marshal.GetDelegateForFunctionPointer(gp(inst,"vkEnumeratePhysicalDevices"),typeof(Enumerate));uint count=0;rc=e(inst,ref count,IntPtr.Zero);result+="; ENUM="+rc+"; DEVICES="+count;}
   return result;
  }finally{if(inst!=IntPtr.Zero && gp!=null){var d=(Destroy)Marshal.GetDelegateForFunctionPointer(gp(inst,"vkDestroyInstance"),typeof(Destroy));d(inst,IntPtr.Zero);}FreeLibrary(h);}
 }
}
'@
[DirectICD]::Run($IcdPath)
