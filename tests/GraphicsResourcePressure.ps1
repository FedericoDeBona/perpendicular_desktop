# Bounded QA fixture: 230 valid 1x1 shared textures, held for 35 seconds.
# No display changes or file writes. All COM references release in finally.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Add-Type -TypeDefinition @'
using System;using System.Collections.Generic;using System.Runtime.InteropServices;using System.Threading;
public static class PerpSharedPressure {
 [DllImport("d3d11.dll")]static extern int D3D11CreateDevice(IntPtr adapter,int type,IntPtr software,uint flags,int[] levels,uint count,uint sdk,out IntPtr device,out int level,out IntPtr context);
 [StructLayout(LayoutKind.Sequential)]public struct Desc {public uint Width,Height,Mips,Array,Format,SampleCount,Quality,Usage,Bind,Cpu,Misc;}
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int CreateTexture(IntPtr self,ref Desc desc,IntPtr initial,out IntPtr texture);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int SharedHandle(IntPtr self,out IntPtr handle);
 static Delegate Method(IntPtr obj,int index,Type type){return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj),index*IntPtr.Size),type);}
 public static object Run(){IntPtr device=IntPtr.Zero,context=IntPtr.Zero;int level;var textures=new List<IntPtr>();int failedAt=-1,error=0;int created=0,exported=0;
 try{int hr=D3D11CreateDevice(IntPtr.Zero,1,IntPtr.Zero,0,new[]{0xb000},1,7,out device,out level,out context);if(hr<0)Marshal.ThrowExceptionForHR(hr);
 var create=(CreateTexture)Method(device,5,typeof(CreateTexture));var desc=new Desc{Width=1,Height=1,Mips=1,Array=1,Format=87,SampleCount=1,Usage=0,Bind=8,Misc=2};
 for(int i=0;i<230;i++){IntPtr texture;hr=create(device,ref desc,IntPtr.Zero,out texture);if(hr<0){failedAt=i;error=hr;break;}textures.Add(texture);created++;
 Guid iid=new Guid("035f3ab4-482e-4e50-b41f-8a7f8bd8960b");IntPtr resource;hr=Marshal.QueryInterface(texture,ref iid,out resource);if(hr<0){failedAt=i;error=hr;break;}try{IntPtr handle;hr=((SharedHandle)Method(resource,8,typeof(SharedHandle)))(resource,out handle);if(hr<0||handle==IntPtr.Zero){failedAt=i;error=hr;break;}exported++;}finally{Marshal.Release(resource);}}
 Thread.Sleep(35000);return new{created,exported,failedAt,error,featureLevel=level,holdSeconds=35};
 }finally{for(int i=textures.Count-1;i>=0;i--)Marshal.Release(textures[i]);if(context!=IntPtr.Zero)Marshal.Release(context);if(device!=IntPtr.Zero)Marshal.Release(device);}}
}
'@
$result=[PerpSharedPressure]::Run();$result|ConvertTo-Json -Compress
if($result.created -ne 230 -or $result.exported -ne 230 -or $result.failedAt -ne -1){throw 'Shared texture pressure did not reach its defined case'}
