//! Opt-in frame payload experiment. Stock IVSHMEM driver; no WDDM changes.
use serde_json::{Value,json};
use std::{ffi::c_void,mem::size_of,ptr,time::Instant};

const REGION:usize=64*1024*1024;
const SLOT:usize=((REGION-4096)/3)/4096*4096;
const PAYLOAD:usize=32768;
const MAGIC:u32=0x49565331;
type Handle=*mut c_void;
#[repr(C)] struct Guid {a:u32,b:u16,c:u16,d:[u8;8]}
#[repr(C)] struct Interface {size:u32,guid:Guid,flags:u32,reserved:usize}
#[link(name="setupapi")]
unsafe extern "system" {
 fn SetupDiGetClassDevsW(g:*const Guid,e:*const u16,w:Handle,f:u32)->Handle;
 fn SetupDiEnumDeviceInterfaces(s:Handle,d:Handle,g:*const Guid,i:u32,o:*mut Interface)->i32;
 fn SetupDiGetDeviceInterfaceDetailW(s:Handle,d:*const Interface,o:*mut u8,n:u32,need:*mut u32,dev:Handle)->i32;
 fn SetupDiDestroyDeviceInfoList(s:Handle)->i32;
}
#[link(name="kernel32")]
unsafe extern "system" {
 fn CreateFileW(p:*const u16,a:u32,s:u32,sec:Handle,c:u32,f:u32,t:Handle)->Handle;
 fn DeviceIoControl(h:Handle,c:u32,i:*const u8,n:u32,o:*mut u8,l:u32,r:*mut u32,v:Handle)->i32;
 fn CloseHandle(h:Handle)->i32;
}
fn barrier(){unsafe{std::arch::asm!("dmb sy",options(nostack,preserves_flags))}}
fn fail()->String {std::io::Error::last_os_error().to_string()}
unsafe fn ioctl(h:Handle,c:u32,input:&[u8],output:&mut[u8])->Result<(),String>{
 let mut count=0;
 if unsafe{DeviceIoControl(h,c,input.as_ptr(),input.len() as u32,output.as_mut_ptr(),output.len() as u32,&mut count,ptr::null_mut())}==0{return Err(fail())}
 if count as usize!=output.len(){return Err("IVSHMEM output length".into())} Ok(())
}
pub struct Frames {handle:Handle,memory:*mut u8,epoch:u32,next:u32,dropped:u64}
impl Frames {
 pub fn open()->Result<Self,String>{unsafe{
  if std::env::var("PERP_IVSHMEM").as_deref()!=Ok("1"){return Err("disabled".into())}
  let g=Guid{a:0xdf576976,b:0x569d,c:0x4672,d:[0x95,0xa0,0xf5,0x7e,0x4e,0xa0,0xb2,0x10]};
  let set=SetupDiGetClassDevsW(&g,ptr::null(),ptr::null_mut(),0x12);
  if set as isize == -1{return Err(fail())}
  let found=(||{
   let mut data:Interface=std::mem::zeroed();data.size=size_of::<Interface>() as u32;
   if SetupDiEnumDeviceInterfaces(set,ptr::null_mut(),&g,0,&mut data)==0{return Err(fail())}
   let mut needed=0;SetupDiGetDeviceInterfaceDetailW(set,&data,ptr::null_mut(),0,&mut needed,ptr::null_mut());
   if !(8..=65536).contains(&needed){return Err("IVSHMEM interface size".into())}
   let mut detail=vec![0u64;(needed as usize).div_ceil(8)];let p=detail.as_mut_ptr().cast::<u8>();p.cast::<u32>().write(8);
   if SetupDiGetDeviceInterfaceDetailW(set,&data,p,needed,&mut needed,ptr::null_mut())==0{return Err(fail())}
   let h=CreateFileW(p.add(4).cast(),0xc0000000,3,ptr::null_mut(),3,0,ptr::null_mut());
   if h as isize == -1{return Err(fail())} Ok(h)
  })();SetupDiDestroyDeviceInfoList(set);let handle=found?;
  let mut map=[0u8;32];if let Err(e)=ioctl(handle,0x222008,&[0],&mut map){CloseHandle(handle);return Err(e)}
  let memory=usize::from_le_bytes(map[16..24].try_into().unwrap()) as *mut u8;
  let mut this=Self{handle,memory,epoch:0,next:1,dropped:0};
  if u64::from_le_bytes(map[8..16].try_into().unwrap())!=REGION as u64 || memory.is_null(){return Err("IVSHMEM mapping size".into())}
  if this.read(0)!=MAGIC || this.read(4)!=1{return Err("IVSHMEM host session disabled".into())}
  this.epoch=this.read(8);if this.epoch==0{return Err("IVSHMEM epoch missing".into())}
  for slot in 0..3 {let base=4096+slot*SLOT;let ready=this.read(base);
   if ready!=this.read(base+4){return Err("IVSHMEM previous slot still owned".into())}
   this.next=this.next.max(ready.checked_add(1).ok_or("IVSHMEM sequence exhausted")?);
  } Ok(this)
 }}
 fn read(&self,offset:usize)->u32{let value=unsafe{self.memory.add(offset).cast::<u32>().read_volatile()};barrier();value}
 pub fn enabled(&self)->bool{self.read(0)==MAGIC && self.read(4)==1 && self.read(8)==self.epoch}
 /// false means the newly selected frame was dropped for lack of a free slot.
 pub fn publish(&mut self,header:&mut Value,bytes:&[u8])->Result<bool,String>{
  let sequence=self.next;let base=4096+((sequence as usize-1)%3)*SLOT;
  if bytes.len()>SLOT-PAYLOAD{return Err("IVSHMEM frame exceeds slot".into())}
  if self.read(base)!=self.read(base+4){self.dropped+=1;return Ok(false)}
  let started=Instant::now();unsafe{ptr::copy_nonoverlapping(bytes.as_ptr(),self.memory.add(base+PAYLOAD),bytes.len())};
  header["guestSharedCopyMilliseconds"]=json!(started.elapsed().as_secs_f64()*1000.0);
  header["transport"]=json!("ivshmem-raw");header["encoding"]=json!("raw");header["wireBytes"]=json!(0);
  header["ivshmemEpoch"]=json!(self.epoch);header["ivshmemSequence"]=json!(sequence);header["ivshmemDropped"]=json!(self.dropped);
  let metadata=serde_json::to_vec(header).map_err(|e|e.to_string())?;
  if metadata.is_empty() || metadata.len()>16384{return Err("IVSHMEM frame metadata length".into())}
  unsafe{
   ptr::copy_nonoverlapping(metadata.as_ptr(),self.memory.add(base+64),metadata.len());
   self.memory.add(base+8).cast::<u32>().write_volatile(metadata.len() as u32);
   self.memory.add(base+12).cast::<u32>().write_volatile(bytes.len() as u32);
   barrier();self.memory.add(base).cast::<u32>().write_volatile(sequence);barrier();
   // The stock driver uses WRITE_REGISTER_ULONG after entering kernel mode.
   ioctl(self.handle,0x222010,&[0;4],&mut [])?;
  }
  self.next=sequence.checked_add(1).ok_or("IVSHMEM sequence exhausted")?;Ok(true)
 }
}
impl Drop for Frames{fn drop(&mut self){unsafe{let _=ioctl(self.handle,0x22200c,&[],&mut []);CloseHandle(self.handle);}}}

/// Fast diagnostic on the existing authenticated TCP control channel.
/// Keeps host/guest clocks separate until the caller estimates their offset.
pub fn clock()->Value {unsafe{
 unsafe extern "system" {
  fn GetProcessTimes(h:Handle,creation:*mut u64,exit:*mut u64,kernel:*mut u64,user:*mut u64)->i32;
  fn GetSystemTimes(idle:*mut u64,kernel:*mut u64,user:*mut u64)->i32;
 }
 let (mut counter,mut frequency)=(0i64,0i64);
 let _=windows::Win32::System::Performance::QueryPerformanceCounter(&mut counter);
 let _=windows::Win32::System::Performance::QueryPerformanceFrequency(&mut frequency);
 let (mut creation,mut exit,mut kernel,mut user)=(0u64,0u64,0u64,0u64);
 let process_ok=GetProcessTimes(-1isize as Handle,&mut creation,&mut exit,&mut kernel,&mut user)!=0;
 let (mut idle,mut system_kernel,mut system_user)=(0u64,0u64,0u64);
 let system_ok=GetSystemTimes(&mut idle,&mut system_kernel,&mut system_user)!=0;
 json!({"qpc":counter,"frequency":frequency,"workerCPU100ns":if process_ok {Some(kernel+user)}else{None},
  "systemIdle100ns":if system_ok {Some(idle)}else{None},
  "systemKernel100ns":if system_ok {Some(system_kernel)}else{None},
  "systemUser100ns":if system_ok {Some(system_user)}else{None}})
}}
