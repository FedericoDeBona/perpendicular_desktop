//! Classic Win32 menu HWNDs reject WGC. Capture only their authenticated window
//! DC; never substitute a desktop crop or send PrintWindow to an app thread.
use super::{capture::{Phase, Target}, catalogue, error, wire::Outbox};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{sync::atomic::{AtomicBool, Ordering}, time::{Duration, Instant}};
use windows::Win32::{
    Foundation::{HWND, POINT, RECT},
    Graphics::Gdi::*,
    UI::{HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext},
        WindowsAndMessaging::{GetWindowRect, IsWindowVisible}},
};

struct WindowDC(HWND, HDC);
impl Drop for WindowDC { fn drop(&mut self) { unsafe { ReleaseDC(Some(self.0),self.1); } } }
struct Bitmap {
    dc: HDC,
    bitmap: HBITMAP,
    previous: HGDIOBJ,
    pixels: *mut u8,
    width: i32,
    height: i32,
}
impl Drop for Bitmap {
    fn drop(&mut self) { unsafe {
        SelectObject(self.dc,self.previous);
        let _ = DeleteObject(self.bitmap.into());
        let _ = DeleteDC(self.dc);
    }}
}
impl Bitmap {
    unsafe fn new(source: HDC, width:i32, height:i32)->Result<Self,String> {
        unsafe {
            let dc = CreateCompatibleDC(Some(source));
            if dc.is_invalid() {return Err("Menu memory DC unavailable".into());}
            let info = BITMAPINFO { bmiHeader:BITMAPINFOHEADER {
                biSize:size_of::<BITMAPINFOHEADER>() as u32,biWidth:width,biHeight:-height,
                biPlanes:1,biBitCount:32,biCompression:BI_RGB.0,..Default::default()
            },..Default::default()};
            let mut pixels = std::ptr::null_mut();
            let bitmap = match CreateDIBSection(Some(dc),&info,DIB_RGB_COLORS,&mut pixels,None,0) {
                Ok(value) if !pixels.is_null() => value,
                Ok(value) => { let _=DeleteObject(value.into());let _=DeleteDC(dc);return Err("Menu bitmap has no storage".into()); }
                Err(e) => {let _=DeleteDC(dc);return Err(error(e));}
            };
            let previous = SelectObject(dc,bitmap.into());
            if previous.is_invalid() || previous.0 as isize == -1 {
                let _=DeleteObject(bitmap.into());let _=DeleteDC(dc);return Err("Menu bitmap selection failed".into());
            }
            Ok(Self {dc,bitmap,previous,pixels:pixels.cast(),width,height})
        }
    }
}

pub fn run(target:&Target,outbox:&Outbox,stop:&AtomicBool)->Result<(),String> {
    unsafe {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let hwnd=HWND(target.hwnd as *mut _);
        let mut bitmap:Option<Bitmap>=None;
        let mut previous:Option<[u8;32]>=None;
        let mut sequence=0u64;
        let mut generation=0u64;
        while !stop.load(Ordering::Acquire) && outbox.connected.load(Ordering::Acquire) {
            let tick=Instant::now();target.set_phase(Phase::Validating);
            if !target.valid() || catalogue::window_class(target.hwnd)!="#32768" || !IsWindowVisible(hwnd).as_bool() {
                target.set_phase(Phase::Invalidated);break;
            }
            let mut rect=RECT::default();GetWindowRect(hwnd,&mut rect).map_err(error)?;
            let (width,height)=(rect.right-rect.left,rect.bottom-rect.top);
            if width<=0 || height<=0 || width>4096 || height>4096 || i64::from(width)*i64::from(height)>2_097_152 {
                return Err("Menu exceeds capture bounds".into());
            }
            target.set_phase(Phase::Backpressure);
            if !outbox.wait_for_frame_slot(&target.id,stop) {break;}
            let started=Instant::now();target.set_phase(Phase::Reading);
            let source=WindowDC(hwnd,GetWindowDC(Some(hwnd)));
            if source.1.is_invalid() {return Err("Menu window DC unavailable".into());}
            if bitmap.as_ref().is_none_or(|b| b.width!=width || b.height!=height) {
                bitmap=Some(Bitmap::new(source.1,width,height)?);generation+=1;previous=None;
            }
            let backing=bitmap.as_ref().unwrap();
            // A clipped source must not retain pixels from an earlier draw.
            std::ptr::write_bytes(backing.pixels,0,width as usize*height as usize*4);
            BitBlt(backing.dc,0,0,width,height,Some(source.1),0,0,SRCCOPY).map_err(error)?;
            if !GdiFlush().as_bool() {return Err("Menu readback did not complete".into());}
            drop(source);
            let stride=(width as usize*4).div_ceil(outbox.row_alignment())*outbox.row_alignment();
            let mut pixels=vec![0u8;stride*height as usize];
            for row in 0..height as usize {
                let destination=&mut pixels[row*stride..row*stride+width as usize*4];
                std::ptr::copy_nonoverlapping(backing.pixels.add(row*width as usize*4),destination.as_mut_ptr(),destination.len());
                for pixel in destination.chunks_exact_mut(4) {pixel[3]=255;}
            }
            let digest:[u8;32]=Sha256::digest(&pixels).into();
            let mut origin=POINT::default();
            if !target.valid() || !IsWindowVisible(hwnd).as_bool() || !ClientToScreen(hwnd,&mut origin).as_bool() {break;}
            let mut current=RECT::default();GetWindowRect(hwnd,&mut current).map_err(error)?;
            if current!=rect {continue;}
            if previous!=Some(digest) {
                previous=Some(digest);sequence+=1;
                *target.geometry.lock().unwrap()=(generation,width,height,rect.left-origin.x,rect.top-origin.y);
                target.capture_frames.store(sequence,Ordering::Release);
                target.set_phase(Phase::Publishing);
                outbox.frame(&target.id,json!({"type":"frame","window":target.id,"sequence":sequence,"generation":generation,
                    "width":width,"height":height,"stride":stride,"bytes":pixels.len(),"capture":"menu-gdi",
                    "guestReadbackMilliseconds":started.elapsed().as_secs_f64()*1000.0}),pixels,None);
            }
            target.set_phase(Phase::Waiting);
            if let Some(delay)=Duration::from_millis(33).checked_sub(tick.elapsed()) {std::thread::sleep(delay);}
        }
        Ok(())
    }
}
