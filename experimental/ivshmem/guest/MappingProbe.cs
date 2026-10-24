// One Windows ARM64 mapping/publication/ownership check; no graphics dependency.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

public static class IvshmemMappingProbe {
    [StructLayout(LayoutKind.Sequential)] struct InterfaceData {
        public int Size; public Guid Guid; public int Flags; public IntPtr Reserved;
    }
    [DllImport("setupapi.dll", SetLastError=true)] static extern IntPtr SetupDiGetClassDevsW(ref Guid g, IntPtr e, IntPtr w, uint flags);
    [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr d, ref Guid g, uint index, ref InterfaceData data);
    [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr set, ref InterfaceData data, IntPtr detail, uint size, out uint needed, IntPtr dev);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr sec, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeviceIoControl(IntPtr h, uint code, byte[] input, uint inputSize, byte[] output, uint outputSize, out uint returned, IntPtr overlap);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    static readonly IntPtr Invalid = new IntPtr(-1);
    static void Check(bool ok, string what) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), what); }
    static void Ioctl(IntPtr h, uint code, byte[] input, byte[] output) {
        uint returned;
        Check(DeviceIoControl(h,code,input,(uint)(input==null ? 0:input.Length),output,(uint)(output==null ? 0:output.Length),out returned,IntPtr.Zero), "IVSHMEM IOCTL " + code);
        if(output!=null && returned!=output.Length) throw new Exception("Unexpected IOCTL output length");
    }
    static IntPtr Open() {
        Guid g = new Guid("df576976-569d-4672-95a0-f57e4ea0b210");
        IntPtr set = SetupDiGetClassDevsW(ref g,IntPtr.Zero,IntPtr.Zero,0x12);
        Check(set!=Invalid,"SetupDiGetClassDevs");
        try {
            InterfaceData d = new InterfaceData(); d.Size=Marshal.SizeOf(typeof(InterfaceData));
            Check(SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref g,0,ref d),"Enumerate IVSHMEM interface");
            uint needed;
            SetupDiGetDeviceInterfaceDetailW(set,ref d,IntPtr.Zero,0,out needed,IntPtr.Zero);
            if(needed<8 || needed>65536) throw new Exception("Invalid interface size");
            IntPtr detail=Marshal.AllocHGlobal((int)needed);
            try {
                Marshal.WriteInt32(detail,8);
                Check(SetupDiGetDeviceInterfaceDetailW(set,ref d,detail,needed,out needed,IntPtr.Zero),"Device interface path");
                string path=Marshal.PtrToStringUni(IntPtr.Add(detail,4));
                IntPtr h=CreateFileW(path,0xc0000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
                Check(h!=Invalid,"Open IVSHMEM");return h;
            } finally {Marshal.FreeHGlobal(detail);}
        } finally {SetupDiDestroyDeviceInfoList(set);}
    }
    static uint Read(IntPtr p,int offset) { uint value=unchecked((uint)Marshal.ReadInt32(p,offset));Thread.MemoryBarrier();return value; }
    static void Publish(IntPtr h,IntPtr p,uint next) {
        uint published=Read(p,64), released=Read(p,72);
        if(published!=released) throw new Exception("Slot still owned by host");
        byte[] payload=new byte[4096];
        for(int i=0;i<payload.Length;i++) payload[i]=(byte)((i*31+7+next)%256);
        Marshal.Copy(payload,0,IntPtr.Add(p,8192),payload.Length);
        Thread.MemoryBarrier();Marshal.WriteInt32(p,64,(int)next);Thread.MemoryBarrier();
        Ioctl(h,0x222010,new byte[4],null);
    }
    public static object Run() {
        if(IntPtr.Size!=8) throw new Exception("64-bit process required");
        IntPtr h=Open();bool mapped=false;
        try {
            byte[] map=new byte[32];Ioctl(h,0x222008,new byte[]{0},map);mapped=true;
            ulong size=BitConverter.ToUInt64(map,8);IntPtr p=new IntPtr(BitConverter.ToInt64(map,16));
            if(size!=64*1024*1024 || p==IntPtr.Zero) throw new Exception("Unexpected mapping");
            for(int i=0;i<4096;i++) if(Marshal.ReadByte(p,4096+i)!=(byte)((i*17+3)%256)) throw new Exception("Host challenge differs at "+i);
            if(Read(p,64)!=0 || Read(p,72)!=0) throw new Exception("Expected fresh session");
            Publish(h,p,1);
            uint firstPublished=Read(p,64), firstReleased=Read(p,72);
            bool blocked=firstPublished!=firstReleased;
            if(!blocked) throw new Exception("Host did not retain the first slot");
            // Same guard used by Publish: no writes while the host owns the slot.
            byte first=Marshal.ReadByte(p,8192);
            try { Publish(h,p,2); throw new Exception("Premature reuse was accepted"); }
            catch(Exception e) { if(e.Message!="Slot still owned by host") throw; }
            if(Marshal.ReadByte(p,8192)!=first || Read(p,64)!=1) throw new Exception("Rejected publish modified slot");
            // Deliberate test delay; no polling loop or production pacing policy.
            Thread.Sleep(3000);
            if(Read(p,72)!=1) throw new Exception("Host release not visible");
            Publish(h,p,2);Thread.Sleep(500);
            if(Read(p,72)!=2) throw new Exception("Second frame not released");
            return new {size=size,peer=BitConverter.ToUInt16(map,0),vectors=BitConverter.ToUInt16(map,24),cacheMode="noncached",challenge=true,blockedWhileHeld=blocked,finalSequence=Read(p,64),finalReleased=Read(p,72)};
        } finally {
            if(mapped) {try {Ioctl(h,0x22200c,null,null);} finally {CloseHandle(h);}}
            else CloseHandle(h);
        }
    }
}
