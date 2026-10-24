//! Bounded qualification overlay: full readback oracle, no partial WGC rendering.
use serde_json::{Value,json};
use sha2::{Digest,Sha256};
use std::{sync::atomic::{AtomicBool,Ordering},time::Instant};
use windows::Graphics::Capture::Direct3D11CaptureFrame;
static REFRESH:AtomicBool=AtomicBool::new(false);
pub fn request_refresh(){REFRESH.store(true,Ordering::Release);}

/// Clip WGC texture coordinates into the actual published capture crop.
/// Missing/invalid metadata forces a full frame; no inferred empty dirty area.
pub fn rectangles(frame:&Direct3D11CaptureFrame,x:i32,y:i32,w:i32,h:i32)->Option<Vec<[usize;4]>> {
 let regions=frame.DirtyRegions().ok()?;let n=regions.Size().ok()?;
 if n>32{return None;}
 let mut result=Vec::new();
 for i in 0..n {
  let r=regions.GetAt(i).ok()?;
  if r.Width<=0||r.Height<=0{return None;}
  let left=i64::from(r.X).max(i64::from(x));let top=i64::from(r.Y).max(i64::from(y));
  let right=(i64::from(r.X)+i64::from(r.Width)).min(i64::from(x)+i64::from(w));
  let bottom=(i64::from(r.Y)+i64::from(r.Height)).min(i64::from(y)+i64::from(h));
  if left<right&&top<bottom{result.push([(left-i64::from(x))as usize,(top-i64::from(y))as usize,(right-left)as usize,(bottom-top)as usize]);}
 } Some(result)
}
struct Base{key:String,pixels:Vec<u8>,sequence:u32}
pub struct Dirty{base:Option<Base>}
impl Dirty {
 pub fn new()->Self{Self{base:None}}
 /// Caller has checked the shared slot is free. A later publication error ends
 /// the whole session, so this private base is never reused after failed I/O.
 pub fn prepare(&mut self,h:&mut Value,bytes:&[u8])->Option<Vec<u8>> {
  let started=Instant::now();let forced=REFRESH.swap(false,Ordering::AcqRel);
  let key=json!([h["window"],h["guestWorkerEpoch"],h["generation"],h["width"],h["height"],h["stride"]]).to_string();
  let stride=h["stride"].as_u64().unwrap_or(0)as usize;
  let width=h["width"].as_u64().unwrap_or(0)as usize;let height=h["height"].as_u64().unwrap_or(0)as usize;
  let rects=h["guestDirtyRects"].as_array().and_then(|r|r.iter().map(|v|{
   let a=v.as_array()?;if a.len()!=4{return None;}
   Some([a[0].as_u64()? as usize,a[1].as_u64()? as usize,a[2].as_u64()? as usize,a[3].as_u64()? as usize])
  }).collect::<Option<Vec<_>>>());
  let valid=rects.as_ref().is_some_and(|r|r.len()<=32&&r.iter().all(|[x,y,w,hh]|*w>0&&*hh>0&&*x<width&&*y<height&&*w<=width-*x&&*hh<=height-*y));
  let mut payload=None;let mut base_sequence=0;let mut mismatch=None;
  let mut reason=if forced{"explicit-base-reset"}else{"initial-or-geometry"};
  if !forced {if let Some(base)=self.base.as_ref().filter(|b|b.key==key&&b.pixels.len()==bytes.len()) {
   reason="metadata-unavailable";
   if valid&&h["guestDirtyRegionMode"].as_u64()==Some(0)&&stride>=width*4&&stride.checked_mul(height)==Some(bytes.len()) {
    let mut reconstructed=base.pixels.clone();let mut packed=Vec::new();
    for [x,y,w,hh] in rects.as_ref().unwrap(){for row in *y..*y+*hh{
     let begin=row*stride+x*4;let end=begin+w*4;
     reconstructed[begin..end].copy_from_slice(&bytes[begin..end]);packed.extend_from_slice(&bytes[begin..end]);
    }}
    let different=reconstructed.iter().zip(bytes).filter(|(a,b)|a!=b).count();mismatch=Some(different);
    reason=if different>0{"coverage-mismatch"}else{"rectangles-not-smaller"};
    if different==0&&!packed.is_empty()&&packed.len()+64<bytes.len(){payload=Some(packed);base_sequence=base.sequence;reason="exact-reconstruction";}
   }
  }}
  h["guestPixelsSHA256"]=json!(format!("{:x}",Sha256::digest(bytes)));
  h["dirtyBaseIVSequence"]=json!(base_sequence);h["dirtyFullReason"]=json!(reason);
  h["dirtyCoverageMismatchBytes"]=json!(mismatch);h["dirtyFull"]=json!(payload.is_none());
  h["encoding"]=json!(if payload.is_some(){"dirty-raw"}else{"raw"});
  // A complete private base is deliberately retained for this qualification.
  // Its cost and the full-frame hash are included in the diagnostic time.
  self.base=Some(Base{key,pixels:bytes.to_vec(),sequence:0});
  h["dirtyValidationMilliseconds"]=json!(started.elapsed().as_secs_f64()*1000.0);
  payload
 }
 pub fn published(&mut self,sequence:u32){if let Some(base)=&mut self.base{base.sequence=sequence;}}
}
