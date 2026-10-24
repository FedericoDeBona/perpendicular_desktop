//! Single-window trial: shared GPU image, query completion, one TCP-metadata ACK.
use super::{capture::Target,wire::Outbox,error,catalogue};
use serde_json::{Value,json};
use sha2::{Digest,Sha256};
use std::{sync::{Mutex,OnceLock,atomic::Ordering},time::{Instant,Duration,SystemTime,UNIX_EPOCH}};
use windows::{core::Interface,Win32::{Foundation::{HWND,POINT},Graphics::{Direct3D11::*,Dxgi::IDXGIResource,Gdi::ClientToScreen}}};
static OWNER:OnceLock<Mutex<Option<String>>>=OnceLock::new();
pub fn enabled(id:&str)->bool{
 let mut owner=OWNER.get_or_init(||Mutex::new(None)).lock().unwrap();
 if owner.is_none(){*owner=Some(id.to_owned());}owner.as_deref()==Some(id)
}
pub struct Gpu{texture:ID3D11Texture2D,query:ID3D11Query,width:u32,height:u32,nonce:[u8;24],checks_left:u8}
impl Gpu{
 pub unsafe fn new(device:&ID3D11Device,width:u32,height:u32)->Result<Self,String>{unsafe{
  if width<32||height==0||width>4096||height>=4096||u64::from(width)*u64::from(height)>4_000_000{return Err("GPU trial size bound".into());}
  let desc=D3D11_TEXTURE2D_DESC{Width:width.div_ceil(64)*64,Height:height.div_ceil(64)*64+1,MipLevels:1,ArraySize:1,Format:windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM,
   SampleDesc:windows::Win32::Graphics::Dxgi::Common::DXGI_SAMPLE_DESC{Count:1,Quality:0},Usage:D3D11_USAGE_DEFAULT,BindFlags:(D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET).0 as u32,CPUAccessFlags:0,MiscFlags:D3D11_RESOURCE_MISC_SHARED.0 as u32};
  let mut texture=None;device.CreateTexture2D(&desc,None,Some(&mut texture)).map_err(error)?;let texture=texture.ok_or("No GPU surface")?;
  // The stock UMD/KMD exports this shared allocation through its existing blob command.
  let resource:IDXGIResource=texture.cast().map_err(error)?;let _handle=resource.GetSharedHandle().map_err(error)?;
  let mut query=None;device.CreateQuery(&D3D11_QUERY_DESC{Query:D3D11_QUERY_EVENT,MiscFlags:0},Some(&mut query)).map_err(error)?;
  let seed=format!("{}|{}",std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos());
  let hash=Sha256::digest(seed.as_bytes());let mut nonce=[0u8;24];nonce.copy_from_slice(&hash[..24]);
  Ok(Self{texture,query:query.ok_or("No GPU query")?,width,height,nonce,checks_left:3})
 }}
 pub fn matches(&self,w:u32,h:u32)->bool{self.width==w&&self.height==h}
 pub unsafe fn submit(&mut self,device:&ID3D11Device,context:&ID3D11DeviceContext,source:&ID3D11Texture2D,x:i32,y:i32,
  target:&Target,outbox:&Outbox,generation:u64,sequence:u64,selected_qpc:i64)->Result<(),String>{unsafe{
  let started=Instant::now();let (w,h)=(self.width,self.height);
  let mut source_desc=D3D11_TEXTURE2D_DESC::default();source.GetDesc(&mut source_desc);
  if x<0||y<0||i64::from(x)+i64::from(w)>i64::from(source_desc.Width)||i64::from(y)+i64::from(h)>i64::from(source_desc.Height){return Err("GPU crop outside source".into());}
  let region=D3D11_BOX{left:x as u32,top:y as u32,front:0,right:x as u32+w,bottom:y as u32+h,back:1};
  context.CopySubresourceRegion(&self.texture,0,0,0,0,source,0,Some(&region));
  let mut marker=[0u8;32];marker[..24].copy_from_slice(&self.nonce);marker[24..].copy_from_slice(&sequence.to_le_bytes());
  let row=D3D11_BOX{left:0,top:h,front:0,right:8,bottom:h+1,back:1};
  context.UpdateSubresource(&self.texture,0,Some(&row),marker.as_ptr().cast(),32,0);
  context.End(&self.query);context.Flush();let submitted=started.elapsed().as_secs_f64()*1000.0;
  let wait=Instant::now();loop{
   let mut ready=0u32;context.GetData(&self.query,Some((&mut ready as *mut u32).cast()),4,0).map_err(error)?;
   if ready!=0{break;}if wait.elapsed()>Duration::from_millis(800){return Err("GPU query timeout".into());}std::thread::sleep(Duration::from_millis(1));
  }
  let gpu_wait=wait.elapsed().as_secs_f64()*1000.0;
  // Only the first three frames read back a reference for the qualification.
  let reference=self.checks_left>0;
  let hash=if reference{
   self.checks_left-=1;
   let mut desc=D3D11_TEXTURE2D_DESC::default();source.GetDesc(&mut desc);desc.Width=w;desc.Height=h;desc.MipLevels=1;desc.ArraySize=1;
   desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ.0 as u32;desc.MiscFlags=0;
   let mut staging=None;device.CreateTexture2D(&desc,None,Some(&mut staging)).map_err(error)?;let staging=staging.ok_or("No reference staging")?;
   context.CopySubresourceRegion(&staging,0,0,0,0,source,0,Some(&region));context.Flush();let mut mapped=D3D11_MAPPED_SUBRESOURCE::default();
   context.Map(&staging,0,D3D11_MAP_READ,0,Some(&mut mapped)).map_err(error)?;
   let mut digest=Sha256::new();for row in 0..h as usize{digest.update(std::slice::from_raw_parts((mapped.pData as *const u8).add(row*mapped.RowPitch as usize),w as usize*4));}
   context.Unmap(&staging,0);Some(format!("{:x}",digest.finalize()))
  }else{None};
  let hwnd=HWND(target.hwnd as *mut _);let bounds=catalogue::frame_bounds(hwnd).ok_or("No bounds")?;let mut origin=POINT::default();
  if !ClientToScreen(hwnd,&mut origin).as_bool(){return Err("No origin".into());}
  let offset=if target.full_frame{(bounds.left-origin.x,bounds.top-origin.y)}else{(0,0)};
  *target.geometry.lock().unwrap()=(generation,w as i32,h as i32,offset.0,offset.1);
  target.capture_frames.store(sequence,Ordering::Release);
  let stride=(w as usize*4).div_ceil(256)*256;
  let marker_hex=marker.iter().map(|b|format!("{b:02x}")).collect::<String>();
  let header=json!({"type":"frame","window":target.id,"sequence":sequence,"generation":generation,"width":w,"height":h,
   "stride":stride,"bytes":stride*h as usize,"wireBytes":0,"encoding":"wgc-gpu","transport":"wgc-gpu",
   "capture":"wgc-hardware-gpu","gpuMarker":marker_hex,"gpuAllocationWidth":w.div_ceil(64)*64,"gpuAllocationHeight":h.div_ceil(64)*64+1,"guestPixelsSHA256Packed":hash,
   "guestCaptureSelectedQPC":selected_qpc,"guestGpuSubmitMilliseconds":submitted,"guestGpuWaitMilliseconds":gpu_wait,
   "guestReferenceReadback":reference,"guestReadbackMilliseconds":if reference{Value::Null}else{json!(0)},"guestEncodeMilliseconds":0});
  outbox.frame(&target.id,header,Vec::new(),None);
  let deadline=Instant::now();while outbox.gpu_ack.load(Ordering::Acquire)<sequence{
   if !outbox.connected.load(Ordering::Acquire)||deadline.elapsed()>Duration::from_secs(4){return Err("GPU consumer acknowledgement missing".into());}
   std::thread::sleep(Duration::from_millis(1));
  }Ok(())
 }}
}

pub fn clock()->Value {unsafe{
 unsafe extern "system" {fn GetProcessTimes(h:*mut core::ffi::c_void,creation:*mut u64,exit:*mut u64,kernel:*mut u64,user:*mut u64)->i32;}
 let (mut qpc,mut frequency)=(0,0);let _=windows::Win32::System::Performance::QueryPerformanceCounter(&mut qpc);
 let _=windows::Win32::System::Performance::QueryPerformanceFrequency(&mut frequency);
 let (mut c,mut e,mut k,mut u)=(0,0,0,0);let ok=GetProcessTimes(-1isize as *mut _,&mut c,&mut e,&mut k,&mut u)!=0;
 json!({"qpc":qpc,"frequency":frequency,"workerCPU100ns":if ok{Some(k+u)}else{None}})
}}
