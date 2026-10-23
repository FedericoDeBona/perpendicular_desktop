// Install before the GPU DLL is loaded: its native CRT initializes stderr from
// the process handle. The service starts this user worker without a console.
use std::{fs::{File,OpenOptions},io::{Read,Write},os::windows::io::{AsRawHandle,FromRawHandle},path::Path};
use windows::Win32::{Foundation::HANDLE,System::{Console::{GetStdHandle,SetStdHandle,STD_ERROR_HANDLE},Pipes::CreatePipe}};

const LIMIT:usize=512*1024;

pub struct Sink { previous:HANDLE, _writer:File }
impl Drop for Sink {
    fn drop(&mut self) {
        // Restore the previous standard handle before closing the owned writer.
        let _=unsafe {SetStdHandle(STD_ERROR_HANDLE,self.previous)};
    }
}

pub fn start(path:&Path)->Result<Sink,String> {
    if let Some(parent)=path.parent(){std::fs::create_dir_all(parent).map_err(super::error)?;}
    // A fresh epoch names the file; never truncate an existing user file.
    let mut log=OpenOptions::new().write(true).create_new(true).open(path).map_err(super::error)?;
    let header=b"Perpendicular native GPU stderr; capped at 512 KiB for this worker.\r\n";
    log.write_all(header).map_err(super::error)?;
    let (mut input,mut output)=(HANDLE::default(),HANDLE::default());
    // Non-inheritable: execute retains its own explicit stdout/stderr pipes.
    unsafe {CreatePipe(&mut input,&mut output,None,0)}.map_err(super::error)?;
    let (mut reader,writer)=unsafe {(File::from_raw_handle(input.0),File::from_raw_handle(output.0))};
    std::thread::Builder::new().name("gpu-stderr".into()).spawn(move || {
        let mut remaining=LIMIT-header.len();
        let mut bytes=[0u8;4096];
        loop {
            let count=match reader.read(&mut bytes) {
                Ok(0)=>break,Ok(count)=>count,
                Err(error) if error.kind()==std::io::ErrorKind::Interrupted=>continue,
                Err(_)=>break,
            };
            let keep=count.min(remaining);
            if keep>0 {
                if log.write_all(&bytes[..keep]).is_err(){remaining=0;}
                else {remaining-=keep;}
            }
            // Continue draining after the cap or a disk error. Native logging
            // must not block the GPU waiting for an abandoned/full pipe.
        }
    }).map_err(super::error)?;
    let previous=unsafe {GetStdHandle(STD_ERROR_HANDLE)}.unwrap_or_default();
    unsafe {SetStdHandle(STD_ERROR_HANDLE,HANDLE(writer.as_raw_handle()))}.map_err(super::error)?;
    Ok(Sink{previous,_writer:writer})
}
