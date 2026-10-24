// Complements WindowsFenceWaitChecks.cs. Compile both files in one assembly.
// One bounded shared-producer publication check, not a throughput benchmark.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static partial class PerpendicularFenceWait {
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetSharedResourceHandle(IntPtr self,out IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int OpenResource(IntPtr self,IntPtr handle,ref Guid iid,out IntPtr resource);
    public static object RunPublication() {
        var r=new System.Collections.Generic.Dictionary<string,object>();
        IntPtr adapter=IntPtr.Zero,a=IntPtr.Zero,b=IntPtr.Zero,ca=IntPtr.Zero,cb=IntPtr.Zero;
        IntPtr a5=IntPtr.Zero,b5=IntPtr.Zero,ca4=IntPtr.Zero,cb4=IntPtr.Zero;
        IntPtr fa=IntPtr.Zero,fb=IntPtr.Zero,fenceHandle=IntPtr.Zero;
        IntPtr source=IntPtr.Zero,opened=IntPtr.Zero,sourceRTV=IntPtr.Zero,stagingA=IntPtr.Zero,stagingB=IntPtr.Zero;
        IntPtr busy=IntPtr.Zero,busyCopy=IntPtr.Zero,busyRTV=IntPtr.Zero,query=IntPtr.Zero;
        bool waitQueued=false;
        try {
            uint la,lb;adapter=TargetAdapter();
            Check(D3D11CreateDevice(adapter,0,IntPtr.Zero,0x20,IntPtr.Zero,0,7,out a,out la,out ca));
            Check(D3D11CreateDevice(adapter,0,IntPtr.Zero,0x20,IntPtr.Zero,0,7,out b,out lb,out cb));
            r["adapter"]=AdapterInfo(a);
            a5=QI(a,"8ffde202-a0e7-45df-9e01-e837801b5ea0");b5=QI(b,"8ffde202-a0e7-45df-9e01-e837801b5ea0");
            ca4=QI(ca,"917600da-f58c-4c33-98d8-3e15b390fa24");cb4=QI(cb,"917600da-f58c-4c33-98d8-3e15b390fa24");
            var fid=new Guid("affde9d1-1df7-4bb7-8a34-0f46251dab80");
            Check(Method<CreateFence>(a5,68)(a5,0,2,ref fid,out fa));
            Check(Method<ShareFence>(fa,7)(fa,IntPtr.Zero,0x10000000,IntPtr.Zero,out fenceHandle));
            Check(Method<OpenFence>(b5,67)(b5,fenceHandle,ref fid,out fb));
            var td=new TexDesc{Width=64,Height=64,Mips=1,Arrays=1,Format=87,Count=1,Bind=0x28,Misc=2};
            Check(Method<MakeTexture>(b,5)(b,ref td,IntPtr.Zero,out source));
            Check(Method<MakeRTV>(b,9)(b,source,IntPtr.Zero,out sourceRTV));
            IntPtr resource=QI(source,"035f3ab4-482e-4e50-b41f-8a7f8bd8960b");IntPtr textureHandle;
            try {Check(Method<GetSharedResourceHandle>(resource,8)(resource,out textureHandle));} finally {Drop(resource);}
            var tid=new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
            Check(Method<OpenResource>(a,28)(a,textureHandle,ref tid,out opened));
            td.Misc=0;td.Bind=0;td.Usage=3;td.CPU=0x20000;
            Check(Method<MakeTexture>(a,5)(a,ref td,IntPtr.Zero,out stagingA));
            Check(Method<MakeTexture>(b,5)(b,ref td,IntPtr.Zero,out stagingB));
            Method<ClearRTV>(cb,50)(cb,sourceRTV,new float[]{0,0,0,1});
            Method<CopyResource>(cb,47)(cb,stagingB,source);Method<Flush>(cb,111)(cb);
            Mapped mapped;Check(Method<MapTexture>(cb,14)(cb,stagingB,0,1,0,out mapped));
            r["initialPixel"]=unchecked((uint)Marshal.ReadInt32(mapped.Data)).ToString("x8");Method<UnmapTexture>(cb,15)(cb,stagingB,0);
            td.Width=td.Height=2048;td.CPU=0;td.Usage=0;td.Bind=0x20;
            Check(Method<MakeTexture>(b,5)(b,ref td,IntPtr.Zero,out busy));
            Check(Method<MakeTexture>(b,5)(b,ref td,IntPtr.Zero,out busyCopy));
            Check(Method<MakeRTV>(b,9)(b,busy,IntPtr.Zero,out busyRTV));
            var qd=new QueryDesc();Check(Method<CreateQuery>(a,24)(a,ref qd,out query));
            var timer=Stopwatch.StartNew();Check(Method<FenceOp>(ca4,148)(ca4,fa,1));waitQueued=true;r["waitCpuMilliseconds"]=timer.Elapsed.TotalMilliseconds;
            Method<CopyResource>(ca,47)(ca,stagingA,opened);Method<End>(ca,28)(ca,query);Method<Flush>(ca,111)(ca);
            uint qv;double elapsed;int hr=Poll(Method<GetData>(ca,29),ca,query,1,100,out qv,out elapsed);
            r["beforeSignalQueryHr"]=hr;r["beforeSignalFenceValue"]=Method<FenceValue>(fa,8)(fa);
            // One finite queued producer batch, not a throughput benchmark.
            // Only the initial black baseline was read back on B.
            for(int i=0;i<16;i++) {Method<ClearRTV>(cb,50)(cb,busyRTV,new float[]{(i&1)==0?0.25f:0.75f,0,0,1});Method<CopyResource>(cb,47)(cb,busyCopy,busy);}
            Method<ClearRTV>(cb,50)(cb,sourceRTV,new float[]{0.2f,0.4f,0.6f,1});
            timer.Restart();Check(Method<FenceOp>(cb4,147)(cb4,fb,1));Method<Flush>(cb,111)(cb);r["signalCpuMilliseconds"]=timer.Elapsed.TotalMilliseconds;
            timer.Restart();Check(Method<MapTexture>(ca,14)(ca,stagingA,0,1,0,out mapped));r["mapMilliseconds"]=timer.Elapsed.TotalMilliseconds;
            try {
                uint first=unchecked((uint)Marshal.ReadInt32(mapped.Data));int wrong=0;
                for(int y=0;y<64;y++)for(int x=0;x<64;x++)if(unchecked((uint)Marshal.ReadInt32(mapped.Data,y*(int)mapped.RowPitch+x*4))!=0xff336699u)wrong++;
                r["pixel"]=first.ToString("x8");r["incorrectPixels"]=wrong;r["fenceAtMapReturn"]=Method<FenceValue>(fa,8)(fa);
            } finally {Method<UnmapTexture>(ca,15)(ca,stagingA,0);}
            // Post-failure control only: make B's actual GPU writes complete,
            // then check the same imported resource again. Not a driver workaround.
            Method<CopyResource>(cb,47)(cb,stagingB,source);Method<Flush>(cb,111)(cb);
            Check(Method<MapTexture>(cb,14)(cb,stagingB,0,1,0,out mapped));
            try {r["producerAfterReadback"]=unchecked((uint)Marshal.ReadInt32(mapped.Data)).ToString("x8");}
            finally {Method<UnmapTexture>(cb,15)(cb,stagingB,0);}
            Method<CopyResource>(ca,47)(ca,stagingA,opened);Method<Flush>(ca,111)(ca);
            Check(Method<MapTexture>(ca,14)(ca,stagingA,0,1,0,out mapped));
            try {int wrong=0;for(int y=0;y<64;y++)for(int x=0;x<64;x++)if(unchecked((uint)Marshal.ReadInt32(mapped.Data,y*(int)mapped.RowPitch+x*4))!=0xff336699u)wrong++;
                r["consumerAfterProducerReadback"]=unchecked((uint)Marshal.ReadInt32(mapped.Data)).ToString("x8");r["incorrectPixelsAfterProducerReadback"]=wrong;}
            finally {Method<UnmapTexture>(ca,15)(ca,stagingA,0);}
            r["driverModules"]=DriverModules();r["scope"]="Shared producer GPU writes before Signal, consumer copy after Wait; producer CPU readback only in post-failure control";
            return r;
        } finally {
            if(waitQueued && cb4!=IntPtr.Zero && fb!=IntPtr.Zero){Method<FenceOp>(cb4,147)(cb4,fb,1);Method<Flush>(cb,111)(cb);}
            Drop(query);Drop(busyRTV);Drop(busyCopy);Drop(busy);Drop(stagingB);Drop(stagingA);Drop(sourceRTV);Drop(opened);Drop(source);Drop(fb);Drop(fa);
            if(fenceHandle!=IntPtr.Zero)CloseHandle(fenceHandle);Drop(cb4);Drop(ca4);Drop(b5);Drop(a5);Drop(cb);Drop(ca);Drop(b);Drop(a);Drop(adapter);
        }
    }

}
