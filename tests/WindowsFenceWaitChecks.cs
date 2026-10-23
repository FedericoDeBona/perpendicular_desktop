
// Real Windows D3D11 driver check. Wait must gate queries and GPU writes.
// Only temporary devices, one 64x64 texture, one EVENT and one shared fence.
// COM slots/GUIDs come from the public d3d11_3.h/d3d11_4.h SDK interfaces.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class PerpendicularFenceWait {
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int CreateFence(IntPtr self, ulong initial, uint flags, ref Guid iid, out IntPtr fence);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int OpenFence(IntPtr self, IntPtr handle, ref Guid iid, out IntPtr fence);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int ShareFence(IntPtr self, IntPtr attributes, uint access, IntPtr name, out IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int FenceOp(IntPtr self, IntPtr fence, ulong value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate ulong FenceValue(IntPtr self);
    static IntPtr QI(IntPtr value, string id) {
        var guid=new Guid(id); IntPtr result;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(value, ref guid, out result));
        return result;
    }
    static void Check(int hr) { Marshal.ThrowExceptionForHR(hr); }
    static void Drop(IntPtr value) { if(value!=IntPtr.Zero) Method<Release>(value,2)(value); }

    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    struct AdapterDesc {
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Name;
        public uint Vendor,Device,Subsystem,Revision;
        public UIntPtr VideoMemory,SystemMemory,SharedMemory;
        public ulong Luid;public uint Flags;
    }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetAdapter(IntPtr self,out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetAdapterDesc(IntPtr self,out AdapterDesc desc);
    static object AdapterInfo(IntPtr device) {
        IntPtr dxgi=IntPtr.Zero,adapter=IntPtr.Zero,adapter1=IntPtr.Zero;
        try {
            dxgi=QI(device,"54ec77fa-1377-44e6-8c32-88fd5f44c84c");
            Check(Method<GetAdapter>(dxgi,7)(dxgi,out adapter));
            adapter1=QI(adapter,"29038f61-3839-4626-91fd-086879011a05");
            AdapterDesc desc;Check(Method<GetAdapterDesc>(adapter1,10)(adapter1,out desc));
            return new {name=desc.Name,vendor=desc.Vendor,device=desc.Device,flags=desc.Flags};
        } finally {Drop(adapter1);Drop(adapter);Drop(dxgi);}
    }
    static object DriverModules() {
        var result=new System.Collections.Generic.List<object>();
        // Read while the devices are alive: releasing them may unload the UMD.
        using(var process=Process.GetCurrentProcess()) {
            foreach(ProcessModule module in process.Modules) {
                if(module.ModuleName.IndexOf("neptune_umd",StringComparison.OrdinalIgnoreCase)<0)continue;
                using(var file=System.IO.File.OpenRead(module.FileName))
                using(var hash=System.Security.Cryptography.SHA256.Create())
                    result.Add(new {name=module.ModuleName,sha256=BitConverter.ToString(hash.ComputeHash(file)).Replace("-","").ToLowerInvariant()});
            }
        }
        return result;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct TexDesc { public uint Width,Height,Mips,Arrays,Format,Count,Quality,Usage,Bind,CPU,Misc; }
    [StructLayout(LayoutKind.Sequential)]
    struct Mapped { public IntPtr Data; public uint RowPitch,DepthPitch; }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int MakeTexture(IntPtr self,ref TexDesc desc,IntPtr initial,out IntPtr texture);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int MakeRTV(IntPtr self,IntPtr texture,IntPtr desc,out IntPtr view);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void ClearRTV(IntPtr self,IntPtr view,float[] color);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void CopyResource(IntPtr self,IntPtr destination,IntPtr source);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int MapTexture(IntPtr self,IntPtr resource,uint sub,uint mode,uint flags,out Mapped mapped);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void UnmapTexture(IntPtr self,IntPtr resource,uint sub);
    public static object Run() {
        var r=new System.Collections.Generic.Dictionary<string,object>();
        IntPtr a=IntPtr.Zero,b=IntPtr.Zero,ca=IntPtr.Zero,cb=IntPtr.Zero;
        IntPtr a5=IntPtr.Zero,b5=IntPtr.Zero,ca4=IntPtr.Zero,cb4=IntPtr.Zero;
        IntPtr fa=IntPtr.Zero,fb=IntPtr.Zero,shared=IntPtr.Zero,q=IntPtr.Zero;
        bool waitQueued=false; Thread releaser=null; int releaseHr=0; IntPtr tex=IntPtr.Zero,staging=IntPtr.Zero,rtv=IntPtr.Zero;
        try {
            uint levelA,levelB;
            Check(D3D11CreateDevice(IntPtr.Zero,1,IntPtr.Zero,0x20,IntPtr.Zero,0,7,out a,out levelA,out ca));
            Check(D3D11CreateDevice(IntPtr.Zero,1,IntPtr.Zero,0x20,IntPtr.Zero,0,7,out b,out levelB,out cb));
            r["featureLevels"]=new uint[]{levelA,levelB};
            r["adapter"]=AdapterInfo(a);
            a5=QI(a,"8ffde202-a0e7-45df-9e01-e837801b5ea0");
            b5=QI(b,"8ffde202-a0e7-45df-9e01-e837801b5ea0");
            ca4=QI(ca,"917600da-f58c-4c33-98d8-3e15b390fa24");
            cb4=QI(cb,"917600da-f58c-4c33-98d8-3e15b390fa24");
            var fenceID=new Guid("affde9d1-1df7-4bb7-8a34-0f46251dab80");
            Check(Method<CreateFence>(a5,68)(a5,0,2,ref fenceID,out fa));
            Check(Method<ShareFence>(fa,7)(fa,IntPtr.Zero,0x10000000,IntPtr.Zero,out shared));
            Check(Method<OpenFence>(b5,67)(b5,shared,ref fenceID,out fb));
            var desc=new QueryDesc();
            Check(Method<CreateQuery>(a,24)(a,ref desc,out q));
            var value=Method<FenceValue>(fa,8);
            r["initialFenceValue"]=value(fa);
            
            var td=new TexDesc{Width=64,Height=64,Mips=1,Arrays=1,Format=87,Count=1,Bind=0x20};
            Check(Method<MakeTexture>(a,5)(a,ref td,IntPtr.Zero,out tex));
            Check(Method<MakeRTV>(a,9)(a,tex,IntPtr.Zero,out rtv));
            td.Usage=3;td.Bind=0;td.CPU=0x20000;
            Check(Method<MakeTexture>(a,5)(a,ref td,IntPtr.Zero,out staging));
            var timer=Stopwatch.StartNew();
            int hr=Method<FenceOp>(ca4,148)(ca4,fa,1);
            r["waitHr"]=hr;r["waitCpuMilliseconds"]=timer.Elapsed.TotalMilliseconds;Check(hr);
            waitQueued=true;
            Method<ClearRTV>(ca,50)(ca,rtv,new float[]{0.2f,0.4f,0.6f,1f});
            Method<CopyResource>(ca,47)(ca,staging,tex);
            Method<End>(ca,28)(ca,q);
            Method<Flush>(ca,111)(ca);
            uint queryValue;double elapsed;
            // Before any signal, even an otherwise idle GPU must stay pending.
            int queryHr=Poll(Method<GetData>(ca,29),ca,q,1,100,out queryValue,out elapsed);
            r["beforeSignalQueryHr"]=queryHr;r["beforeSignalQueryValue"]=queryValue;
            r["beforeSignalMilliseconds"]=elapsed;r["beforeSignalFenceValue"]=value(fa);
            r["prematureCompletion"]=queryHr==0 && queryValue!=0 && value(fa)==0;
            
            // Release from independent B even if the correct driver blocks Map.
            // Fence values, rather than timing alone, establish ordering.
            releaser=new Thread(delegate() {
                Thread.Sleep(250);
                releaseHr=Method<FenceOp>(cb4,147)(cb4,fb,1);
                Method<Flush>(cb,111)(cb);
            });
            releaser.IsBackground=true;releaser.Start();
            timer.Restart();Mapped mapped;
            int mapHr=Method<MapTexture>(ca,14)(ca,staging,0,1,0,out mapped);
            r["mapHr"]=mapHr;r["mapMilliseconds"]=timer.Elapsed.TotalMilliseconds;
            r["fenceAtMapReturn"]=value(fa);
            Check(mapHr);
            try {
                int first=Marshal.ReadInt32(mapped.Data);bool uniform=true;
                for(int y=0;y<64;y++)for(int x=0;x<64;x++)
                    uniform &= Marshal.ReadInt32(mapped.Data,y*(int)mapped.RowPitch+x*4)==first;
                r["pixel"]=unchecked((uint)first).ToString("x8");r["uniform"]=uniform;
                r["gpuWriteBeforeGate"]=uniform && unchecked((uint)first)==0xff336699u && value(fa)==0;
            } finally {Method<UnmapTexture>(ca,15)(ca,staging,0);}
            releaser.Join();r["signalHr"]=releaseHr;Check(releaseHr);
            queryHr=Poll(Method<GetData>(ca,29),ca,q,0,1000,out queryValue,out elapsed);
            r["afterSignalQueryHr"]=queryHr;r["afterSignalQueryValue"]=queryValue;
            r["afterSignalMilliseconds"]=elapsed;r["afterSignalFenceValue"]=value(fa);
            r["scope"]="D3D11 Wait ordering for one GPU clear, staging copy and EVENT behind an initially zero shared fence, released by independent device B";
            r["driverModules"]=DriverModules();
            return r;
        } finally {
            if(waitQueued && cb4!=IntPtr.Zero && fb!=IntPtr.Zero) {
                Method<FenceOp>(cb4,147)(cb4,fb,1);
                Method<Flush>(cb,111)(cb);
            }
            if(releaser!=null)releaser.Join(1000);Drop(rtv);Drop(staging);Drop(tex);Drop(q);Drop(fb);Drop(fa);if(shared!=IntPtr.Zero)CloseHandle(shared);
            Drop(cb4);Drop(ca4);Drop(b5);Drop(a5);Drop(cb);Drop(ca);Drop(b);Drop(a);
        }
    }

    [DllImport("d3d11.dll", CallingConvention=CallingConvention.StdCall)]
    static extern int D3D11CreateDevice(IntPtr adapter, uint driver, IntPtr software,
        uint flags, IntPtr levels, uint count, uint sdk,
        out IntPtr device, out uint level, out IntPtr context);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int CreateQuery(IntPtr self, ref QueryDesc desc, out IntPtr query);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void End(IntPtr self, IntPtr query);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void Flush(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetData(IntPtr self, IntPtr query, out uint value, uint size, uint flags);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate uint Release(IntPtr self);
    [StructLayout(LayoutKind.Sequential)]
    struct QueryDesc { public uint Query; public uint MiscFlags; }
    // These are slots in the public ID3D11Device/ID3D11DeviceContext COM ABI.
    static T Method<T>(IntPtr self, int slot) where T : class {
        return Marshal.GetDelegateForFunctionPointer(
            Marshal.ReadIntPtr(Marshal.ReadIntPtr(self), slot * IntPtr.Size), typeof(T)) as T;
    }
    static int Poll(GetData get, IntPtr context, IntPtr query, uint flags,
                    int limit, out uint value, out double milliseconds) {
        var elapsed = Stopwatch.StartNew();
        int hr;
        do {
            hr = get(context, query, out value, 4, flags);
            if (hr != 1) break; // S_FALSE is the only retryable result.
            Thread.Sleep(1);
        } while (elapsed.ElapsedMilliseconds < limit);
        milliseconds = elapsed.Elapsed.TotalMilliseconds;
        return hr;
    }
}
