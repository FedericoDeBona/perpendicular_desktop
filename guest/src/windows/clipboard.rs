//! Text is exchanged only for an explicit copy/cut/paste command. No polling,
//! clipboard logging or clipboard contents in process arguments or files.
use super::error;
use std::{sync::{atomic::{AtomicBool, Ordering}, mpsc}, time::{Duration, Instant}};
static READING:AtomicBool=AtomicBool::new(false);
use windows::{core::w, Win32::{
    Foundation::{GlobalFree, HANDLE, HGLOBAL, HWND},
    System::{DataExchange::*, Memory::*},
    UI::WindowsAndMessaging::*,
}};

const TEXT_FORMAT:u32=13; // CF_UNICODETEXT.
pub const MAX_TEXT:usize=262_144;

struct Clipboard {window:HWND,opened:bool}
impl Clipboard {
    fn open()->Result<Self,String> {
        unsafe {
            // A real window owned by this thread is required by EmptyClipboard.
            let window=CreateWindowExW(WS_EX_NOACTIVATE,w!("STATIC"),None,WS_POPUP,
                0,0,0,0,None,None,None,None).map_err(error)?;
            let mut clipboard=Self {window,opened:false};
            let until=Instant::now()+Duration::from_millis(200);
            loop {
                if OpenClipboard(Some(window)).is_ok(){clipboard.opened=true;return Ok(clipboard);}
                if Instant::now()>=until{return Err("Gli appunti Windows sono occupati. Riprova.".into());}
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
}
impl Drop for Clipboard {
    fn drop(&mut self){unsafe {
        if self.opened {let _=CloseClipboard();}
        let _=DestroyWindow(self.window);
    }}
}
struct OwnedMemory(HGLOBAL);
impl Drop for OwnedMemory {fn drop(&mut self){if !self.0.is_invalid(){unsafe {let _=GlobalFree(Some(self.0));}}}}

pub fn sequence()->u32 {unsafe {GetClipboardSequenceNumber()}}

pub fn write(text:&str)->Result<(),String> {
    if text.len()>MAX_TEXT || text.contains('\0'){return Err("Gli appunti devono contenere testo fino a 256 KB.".into());}
    let normalized=text.replace("\r\n","\n").replace('\r',"\n").replace('\n',"\r\n");
    let units:Vec<u16>=normalized.encode_utf16().chain(Some(0)).collect();
    unsafe {
        let mut memory=OwnedMemory(GlobalAlloc(GMEM_MOVEABLE,units.len()*2).map_err(error)?);
        let pointer=GlobalLock(memory.0);
        if pointer.is_null(){return Err("Cannot allocate Windows clipboard text".into());}
        std::ptr::copy_nonoverlapping(units.as_ptr(),pointer.cast::<u16>(),units.len());
        let _=GlobalUnlock(memory.0);
        let _clipboard=Clipboard::open()?;
        EmptyClipboard().map_err(error)?;
        SetClipboardData(TEXT_FORMAT,Some(HANDLE(memory.0.0))).map_err(error)?;
        // Ownership transferred to Windows, including after this window closes.
        memory.0=HGLOBAL::default();
    }
    Ok(())
}

fn read()->Result<String,String> {
    let _clipboard=Clipboard::open()?;
    unsafe {
        let handle=GetClipboardData(TEXT_FORMAT).map_err(|_|"La selezione Windows non contiene testo.".to_string())?;
        let memory=HGLOBAL(handle.0);
        let size=GlobalSize(memory);
        if size<2 || size>1_048_576 || size%2!=0 {return Err("Invalid or oversized Windows clipboard text".into());}
        let pointer=GlobalLock(memory);
        if pointer.is_null(){return Err("Cannot read Windows clipboard text".into());}
        let units=std::slice::from_raw_parts(pointer.cast::<u16>(),size/2);
        let result=(|| {
            let end=units.iter().position(|v|*v==0).ok_or("Unterminated Windows clipboard text")?;
            let text=String::from_utf16(&units[..end]).map_err(|_|"Invalid Windows clipboard Unicode")?;
            if text.len()>MAX_TEXT{return Err("Il testo Windows supera 256 KB.");}
            Ok(text.replace("\r\n","\n"))
        })().map_err(String::from);
        let _=GlobalUnlock(memory);
        result
    }
}

pub fn read_after(previous:u32)->Result<String,String> {
    // Delayed clipboard rendering belongs to another application and can hang
    // GetClipboardData. Keep that call off the worker and permit only one such
    // reader. A late result has no receiver and can never update Mac clipboard.
    if READING.swap(true,Ordering::AcqRel) {return Err("La lettura degli appunti Windows è ancora occupata.".into());}
    let (sender,receiver)=mpsc::sync_channel(1);
    if let Err(e)=std::thread::Builder::new().name("clipboard-read".into()).spawn(move || {
        let result=read_changed(previous);
        READING.store(false,Ordering::Release);
        let _=sender.send(result);
    }) {READING.store(false,Ordering::Release);return Err(error(e));}
    receiver.recv_timeout(Duration::from_millis(1200)).map_err(|_|"Windows non ha restituito gli appunti in tempo.".to_string())?
}
fn read_changed(previous:u32)->Result<String,String> {
    let until=Instant::now()+Duration::from_millis(750);
    while sequence()==previous {
        if Instant::now()>=until{return Err("Windows non ha copiato nuovo testo. Seleziona il testo e riprova.".into());}
        std::thread::sleep(Duration::from_millis(5));
    }
    let text=read()?;
    if serde_json::to_vec(&text).map_err(error)?.len()>1_000_000 {return Err("Clipboard text exceeds the message limit".into());}
    Ok(text)
}
