// One bounded edit in a verified synthetic ClassicNotepad; never saves a file.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class IvshmemSmallUpdate {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern IntPtr FindWindowExW(IntPtr p,IntPtr a,string c,string t);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,string l);
 [DllImport("user32.dll")]static extern bool UpdateWindow(IntPtr h);
 public static string Run(int pid,string creation,string text) {
  if(text.Length<1||text.Length>80)throw new Exception("Small synthetic update only");
  Process p=Process.GetProcessById(pid);
  if(p.ProcessName!="ClassicNotepad"||p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()!=creation)throw new Exception("Scratch identity differs");
  IntPtr edit=FindWindowExW(p.MainWindowHandle,IntPtr.Zero,"Edit",null);
  if(edit==IntPtr.Zero)throw new Exception("Scratch edit missing");
  long start=Stopwatch.GetTimestamp();
  SendMessageW(edit,0x00b1,new IntPtr(-1),new IntPtr(-1));
  SendMessageW(edit,0x00c2,IntPtr.Zero,text);UpdateWindow(edit);
  return "{\"pid\":"+pid+",\"characters\":"+text.Length+",\"qpc\":"+start+",\"frequency\":"+Stopwatch.Frequency+"}";
 }
}
