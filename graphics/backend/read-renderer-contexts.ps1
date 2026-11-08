# Read-only diagnostic for the pinned ARM64 v20 UMD; not a production component.
# Supply active contexts from the already verified QA renderer parent, never from timing.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$TargetProcessId,
 [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][uint32[]]$ActiveContexts
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$p=Get-Process -Id $TargetProcessId -ErrorAction Stop
$m=@($p.Modules|Where-Object {$_.ModuleName-ieq'neptune_umd_arm64.dll'});if($m.Count-ne1){throw 'Expected exactly one actual pinned ARM64 UMD'};$m=$m[0]
$sha=(Get-FileHash $m.FileName).Hash;if($sha-ine'EB1E1AA133124B07138993BFBFE386E7CE31A0ABC757D9927D3C409F536E424D'){throw 'Actual production UMD differs'}
Add-Type @'
using System;using System.Collections.Generic;using System.Diagnostics;using System.Runtime.InteropServices;
public static class RendererContextRead {
 [StructLayout(LayoutKind.Sequential)]public struct M{public ulong Base,Allocation;public uint AllocationProtect;public ushort Partition,Padding;public ulong Size;public uint State,Protect,Type,Pad;}
 [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",SetLastError=true)]static extern UIntPtr VirtualQueryEx(IntPtr process,UIntPtr address,out M info,UIntPtr size);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool ReadProcessMemory(IntPtr process,UIntPtr address,byte[] data,UIntPtr size,out UIntPtr read);
 public static object Read(int pid,ulong moduleBase,ulong moduleSize,uint[] activeContexts){
  var handle=OpenProcess(0x410,false,pid);if(handle==IntPtr.Zero)throw new Exception("Read-only OpenProcess failed "+Marshal.GetLastWin32Error());
  var rows=new List<object>();var ids=new HashSet<uint>(activeContexts);var clock=Stopwatch.StartNew();ulong address=0,total=0;int errors=0,regions=0;bool bounded=false;var buffer=new byte[262144];
  try{while(true){M info;if(VirtualQueryEx(handle,(UIntPtr)address,out info,(UIntPtr)48)==UIntPtr.Zero)break;
   uint prot=info.Protect&255;
   if(info.State==0x1000&&info.Type==0x20000&&(info.Protect&0x100)==0&&(prot==4||prot==8||prot==64||prot==128)){
    regions++;for(ulong off=0;off<info.Size;){if(total>=134217728||clock.ElapsedMilliseconds>1000){bounded=true;goto done;}
     int size=(int)Math.Min(262144ul,Math.Min(info.Size-off,134217728ul-total));if(size<144)break;UIntPtr got;
     bool ok=ReadProcessMemory(handle,(UIntPtr)(info.Base+off),buffer,(UIntPtr)(uint)size,out got);int read=(int)got.ToUInt64();if(!ok)errors++;if(read>0){total+=(uint)read;
      for(int i=0;i+144<=read;i+=8){if(BitConverter.ToUInt32(buffer,i)!=2||BitConverter.ToUInt32(buffer,i+8)!=64)continue;
       uint caps=BitConverter.ToUInt32(buffer,i+4),ctx=BitConverter.ToUInt32(buffer,i+12);if(caps==0||(caps&~255u)!=0||!ids.Contains(ctx))continue;
       bool valid=true;foreach(int offset in new int[]{16,24,32,120,128}){ulong f=BitConverter.ToUInt64(buffer,i+offset);if(f<moduleBase||f>=moduleBase+moduleSize){valid=false;break;}}
       if(!valid)continue;rows.Add(new {address=info.Base+off+(uint)i,wire=2,caps=caps,timelines=64,context=ctx,validatedFunctionPointers=5});if(rows.Count==8)goto done;
      }
     }off+=(uint)(size-136);
    }
   }
   if(info.Size==0||info.Base+info.Size<=address)break;address=info.Base+info.Size;
  }
 done:return new {pid=pid,objects=rows,bytesRead=total,milliseconds=clock.Elapsed.TotalMilliseconds,stoppedByBudget=bounded,readErrors=errors,privateWritableRegions=regions,access="PROCESS_QUERY_INFORMATION|PROCESS_VM_READ only; no writes or target calls"};
  }finally{CloseHandle(handle);}
 }
}
'@
$contexts=[uint32[]]$ActiveContexts
@{actualUMDSHA=$sha;moduleBase=$m.BaseAddress.ToInt64();moduleSize=$m.ModuleMemorySize;result=[RendererContextRead]::Read($TargetProcessId,[uint64]$m.BaseAddress.ToInt64(),[uint64]$m.ModuleMemorySize,$contexts);scope='Source-pinned npt_renderer starts with wire/caps/timelines/virtio_ctx_id; validate five ops pointers inside actual UMD. Context ownership candidates, not current draw proof.'}|ConvertTo-Json -Depth 7 -Compress
