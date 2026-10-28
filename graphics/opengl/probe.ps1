$ErrorActionPreference = 'Stop'
# Hidden disposable window; no driver, registry or machine configuration changes.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GLPrerequisites {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex,string cls,string title,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
 [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr w);
 [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr w,IntPtr dc);
 [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr w);
 [DllImport("gdi32.dll")] static extern int ChoosePixelFormat(IntPtr dc,byte[] pfd);
 [DllImport("gdi32.dll")] static extern bool SetPixelFormat(IntPtr dc,int format,byte[] pfd);
 [DllImport("opengl32.dll")] static extern IntPtr wglCreateContext(IntPtr dc);
 [DllImport("opengl32.dll")] static extern bool wglMakeCurrent(IntPtr dc,IntPtr ctx);
 [DllImport("opengl32.dll")] static extern bool wglDeleteContext(IntPtr ctx);
 [DllImport("opengl32.dll")] static extern IntPtr glGetString(uint name);
 [DllImport("d3d12.dll")] static extern int D3D12CreateDevice(IntPtr adapter,uint level,ref Guid iid,out IntPtr device);
 [StructLayout(LayoutKind.Sequential)] struct InstanceInfo { public uint type; public IntPtr next; public uint flags; public IntPtr app; public uint layers; public IntPtr layerNames; public uint extensions; public IntPtr extensionNames; }
 [DllImport("vulkan-1.dll")] static extern int vkCreateInstance(ref InstanceInfo info,IntPtr allocator,out IntPtr instance);
 [DllImport("vulkan-1.dll")] static extern int vkEnumeratePhysicalDevices(IntPtr instance,ref uint count,IntPtr devices);
 [DllImport("vulkan-1.dll")] static extern void vkDestroyInstance(IntPtr instance,IntPtr allocator);
 public static string[] Run() {
  var lines = new System.Collections.Generic.List<string>();
  IntPtr w=IntPtr.Zero,dc=IntPtr.Zero,ctx=IntPtr.Zero;
  try {
   w=CreateWindowExW(0,"STATIC","Perpendicular GL prerequisite probe",0,0,0,16,16,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
   if(w==IntPtr.Zero) throw new Exception("CreateWindow failed");
   dc=GetDC(w); var pfd=new byte[40];pfd[0]=40;pfd[2]=1;pfd[4]=37;pfd[9]=32;pfd[23]=24;pfd[24]=8;
   int pf=ChoosePixelFormat(dc,pfd);
   if(pf==0 || !SetPixelFormat(dc,pf,pfd)) throw new Exception("SetPixelFormat failed");
   ctx=wglCreateContext(dc);
   if(ctx==IntPtr.Zero || !wglMakeCurrent(dc,ctx)) throw new Exception("WGL context failed");
   lines.Add("GL_VENDOR="+Marshal.PtrToStringAnsi(glGetString(0x1F00)));
   lines.Add("GL_RENDERER="+Marshal.PtrToStringAnsi(glGetString(0x1F01)));
   lines.Add("GL_VERSION="+Marshal.PtrToStringAnsi(glGetString(0x1F02)));
  } catch(Exception e) {lines.Add("GL_ERROR="+e.Message);}
  finally {if(ctx!=IntPtr.Zero){wglMakeCurrent(IntPtr.Zero,IntPtr.Zero);wglDeleteContext(ctx);}if(dc!=IntPtr.Zero)ReleaseDC(w,dc);if(w!=IntPtr.Zero)DestroyWindow(w);}
  try {
   Guid iid=new Guid("189819f1-1db6-4b57-be54-1821339b85f7");IntPtr d;
   int hr=D3D12CreateDevice(IntPtr.Zero,0xB000,ref iid,out d);
   lines.Add("D3D12_FL11_0_HRESULT=0x"+hr.ToString("X8"));
   if(d!=IntPtr.Zero) Marshal.Release(d);
  } catch(Exception e){lines.Add("D3D12_ERROR="+e.Message);}
  IntPtr vi=IntPtr.Zero;
  try {
   var info=new InstanceInfo(); info.type=1;
   int vr=vkCreateInstance(ref info,IntPtr.Zero,out vi);
   lines.Add("VK_CREATE_INSTANCE="+vr);
   if(vr==0){uint count=0;vr=vkEnumeratePhysicalDevices(vi,ref count,IntPtr.Zero);lines.Add("VK_ENUMERATE="+vr+"; DEVICES="+count);}
  }catch(Exception e){lines.Add("VK_ERROR="+e.Message);}
  finally {if(vi!=IntPtr.Zero)vkDestroyInstance(vi,IntPtr.Zero);}
  return lines.ToArray();
 }
}
'@
[PSCustomObject]@{
    ProcessArchitecture=$env:PROCESSOR_ARCHITECTURE
    NativeArchitecture=$env:PROCESSOR_ARCHITEW6432
    SecureBootRegistry=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State').UEFISecureBootEnabled
    Probe=[GLPrerequisites]::Run()
    VulkanLoader=(Test-Path "$env:windir\System32\vulkan-1.dll")
    VulkanRegistry=@(Get-ItemProperty 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers' -ErrorAction SilentlyContinue | Select-Object * -ExcludeProperty PS*)
} | ConvertTo-Json -Depth 5
