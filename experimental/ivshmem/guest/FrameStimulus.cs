// Bounded, identical text updates to a newly opened scratch ClassicNotepad.
// Run only with its verified PID and creation FILETIME; never saves a document.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class FrameStimulus {
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent,IntPtr after,string cls,string title);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr hwnd,uint message,IntPtr wparam,string text);
    [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr hwnd,IntPtr rect,bool erase);
    [DllImport("user32.dll")] static extern bool UpdateWindow(IntPtr hwnd);
    public static int Main(string[] args) {
        try {
            if(args.Length!=4) throw new Exception("Expected PID creationFILETIME count intervalMs");
            int pid=int.Parse(args[0]),count=int.Parse(args[2]),interval=int.Parse(args[3]);
            if(count<1 || count>60 || interval<50 || interval>500) throw new Exception("Trial bounds");
            Process app=Process.GetProcessById(pid);
            if(app.ProcessName!="ClassicNotepad" || app.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()!=args[1]) throw new Exception("Scratch app identity changed");
            IntPtr main=app.MainWindowHandle;
            IntPtr edit=FindWindowExW(main,IntPtr.Zero,"Edit",null);
            if(main==IntPtr.Zero || edit==IntPtr.Zero) throw new Exception("Classic edit control missing");
            long cpuBefore=app.TotalProcessorTime.Ticks;
            long start=Stopwatch.GetTimestamp();
            for(int step=0;step<count;step++) {
                StringBuilder text=new StringBuilder("PERPENDICULAR IVSHMEM TRANSPORT TRIAL\r\n");
                text.Append("Update ").Append(step.ToString("D3")).Append("\r\n");
                for(int line=0;line<120;line++) text.Append((line+step).ToString("D4")).Append("  WGC hardware, full BGRA frame, unchanged control channel.\r\n");
                SendMessageW(edit,0x000c,IntPtr.Zero,text.ToString());
                InvalidateRect(edit,IntPtr.Zero,true);UpdateWindow(edit);
                long deadline=start+(long)((step+1)*interval*(Stopwatch.Frequency/1000.0));
                int remaining=(int)((deadline-Stopwatch.GetTimestamp())*1000/Stopwatch.Frequency);
                if(remaining>0) Thread.Sleep(remaining);
            }
            long end=Stopwatch.GetTimestamp();app.Refresh();
            Console.WriteLine("{\"pid\":"+pid+",\"updates\":"+count+",\"intervalMs\":"+interval+",\"startQPC\":"+start+",\"endQPC\":"+end+",\"frequency\":"+Stopwatch.Frequency+",\"appCPU100ns\":"+(app.TotalProcessorTime.Ticks-cpuBefore)+"}");
            return 0;
        }catch(Exception error){Console.Error.WriteLine(error.ToString());return 1;}
    }
}
