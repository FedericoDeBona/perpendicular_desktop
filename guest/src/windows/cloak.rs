//! Per-window, same-user ARM64 helper. Global mouse hit testing cannot address
//! a DWM-cloaked window. The helper resolves children in the owning UI thread.
use super::{capture::Target, error};
use std::{ffi::c_void, path::Path, sync::Arc};
use windows::core::w;

const DLL: &[u8] = include_bytes!(env!("PERP_WINDOW_HOOK_DLL"));
type Hook = unsafe extern "system" fn(i32, usize, isize) -> isize;
#[link(name="user32")]
unsafe extern "system" {
    fn SetWindowsHookExW(id:i32, callback:Option<Hook>, module:*mut c_void, thread:u32)->*mut c_void;
    fn UnhookWindowsHookEx(hook:*mut c_void)->i32;
    fn RegisterWindowMessageW(name:*const u16)->u32;
    fn GetWindowThreadProcessId(hwnd:*mut c_void,pid:*mut u32)->u32;
    fn GetPropW(hwnd:*mut c_void,name:*const u16)->*mut c_void;
    fn SetPropW(hwnd:*mut c_void,name:*const u16,value:*mut c_void)->i32;
    fn RemovePropW(hwnd:*mut c_void,name:*const u16)->*mut c_void;
    fn SendMessageTimeoutW(hwnd:*mut c_void,msg:u32,w:usize,l:isize,flags:u32,timeout:u32,result:*mut usize)->isize;
}
#[link(name="kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(name:*const u16)->*mut c_void;
    fn FreeLibrary(module:*mut c_void)->i32;
    fn GetProcAddress(module:*mut c_void,name:*const u8)->*mut c_void;
    fn GetCurrentProcessId()->u32;
    fn GetTickCount64()->u64;
}

pub fn install(directory:&Path)->Result<(),String> {
    let path=directory.join("perpendicular-window-hook.dll");
    if std::fs::read(&path).ok().as_deref()!=Some(DLL) { std::fs::write(path,DLL).map_err(error)?; }
    Ok(())
}

pub struct Window {
    target:Arc<Target>, module:*mut c_void, call_hook:*mut c_void, message_hook:*mut c_void,
    active:bool, native_input:bool,last:(i32,i32), buttons:u32,
}
impl Window {
    pub fn new(target:Arc<Target>)->Result<Self,String> {
        if !target.valid(){return Err("Window retired".into());}
        let path=std::env::current_exe().map_err(error)?.with_file_name("perpendicular-window-hook.dll");
        if std::fs::read(&path).map_err(error)?.as_slice()!=DLL {return Err("Window helper differs from this guest version".into());}
        let wide:Vec<u16>=path.as_os_str().to_string_lossy().encode_utf16().chain([0]).collect();
        unsafe {
            let mut pid=0;
            let thread=GetWindowThreadProcessId(target.hwnd as _,&mut pid);
            if pid!=target.pid || thread==0 {return Err("Window identity changed".into());}
            let module=LoadLibraryW(wide.as_ptr());
            if module.is_null(){return Err(format!("Load window helper: {}",std::io::Error::last_os_error()));}
            let mut value=Self{target,module,call_hook:std::ptr::null_mut(),message_hook:std::ptr::null_mut(),active:false,native_input:false,last:(0,0),buttons:0};
            let call=GetProcAddress(module,c"PerpendicularWindowHook".as_ptr().cast());
            let message=GetProcAddress(module,c"PerpendicularMessageHook".as_ptr().cast());
            if call.is_null()||message.is_null(){return Err("Missing window helper entry point".into());}
            value.call_hook=SetWindowsHookExW(4,Some(std::mem::transmute::<*mut c_void,Hook>(call)),module,thread);
            value.message_hook=SetWindowsHookExW(3,Some(std::mem::transmute::<*mut c_void,Hook>(message)),module,thread);
            if value.call_hook.is_null()||value.message_hook.is_null(){return Err(format!("Window input helper unavailable: {}",std::io::Error::last_os_error()));}
            Ok(value)
        }
    }
    pub fn active(&self)->bool {self.active && unsafe {GetPropW(self.target.hwnd as _,w!("Perpendicular.Window.Controller").as_ptr()) as usize==GetCurrentProcessId() as usize}}
    pub fn native_input(&self)->bool {self.active() && self.native_input}
    pub fn set_native_input(&mut self,enabled:bool)->Result<(),String> {
        if self.native_input==enabled{return Ok(());}
        self.command(if enabled{11}else{1},0,0,0)?;
        self.native_input=enabled;Ok(())
    }
    pub fn touch(&self) {
        if self.active() {unsafe {SetPropW(self.target.hwnd as _,w!("Perpendicular.Window.Beat").as_ptr(),GetTickCount64() as usize as _);}}
    }
    pub fn hide(&mut self)->Result<(),String> {
        unsafe {SetPropW(self.target.hwnd as _,w!("Perpendicular.Window.Controller").as_ptr(),GetCurrentProcessId() as usize as _);}
        self.active=true;self.touch();
        if let Err(message)=self.command(1,0,0,0) {self.show();return Err(message);}
        Ok(())
    }
    pub fn show(&mut self) {
        if self.active {
            self.cancel();let _=self.command(2,0,0,0);
            self.active=false;self.buttons=0;
        }
    }
    pub fn pointer(&mut self,kind:&str,button:&str,down:bool,x:i32,y:i32,delta:i32)->Result<(),String> {
        if !self.active(){return Err("Window isolation is no longer active".into());}
        let op=match (kind,button,down) {
            ("pointer",_,_)=>3,("button","left",true)=>4,("button","left",false)=>5,
            ("button","right",true)=>6,("button","right",false)=>7,("scroll",_,_)=>8,
            _=>return Err("Unsupported hidden window input".into()),
        };
        if kind=="button" {let mask=if button=="left"{1}else{2};if down{self.buttons|=mask}else{self.buttons&=!mask}}
        self.last=(x,y);self.command(op,x,y,delta)
    }
    pub fn release(&mut self,button:&str)->Result<(),String> {
        let mask=if button=="left"{1}else{2};
        if self.buttons&mask!=0 {self.pointer("button",button,false,self.last.0,self.last.1,0)?;}
        Ok(())
    }
    pub fn activate(&self)->Result<(),String> {self.command(10,0,0,0)}
    pub fn cancel(&mut self) {
        let _=self.release("left");let _=self.release("right");let _=self.command(9,0,0,0);
    }
    fn command(&self,op:u32,x:i32,y:i32,delta:i32)->Result<(),String> {
        if !self.target.valid(){return Err("Window retired".into());}
        self.touch();
        unsafe {
            let h=self.target.hwnd as *mut c_void;
            let mut guid=windows::core::GUID::default();
            windows::Win32::System::Com::CoCreateGuid().map(|value|guid=value).map_err(error)?;
            let nonce=(guid.to_u128() as usize)|1;
            if !GetPropW(h,w!("Perpendicular.Window.Request").as_ptr()).is_null(){return Err("Window helper is busy".into());}
            struct Request(*mut c_void);
            impl Drop for Request {fn drop(&mut self){unsafe {RemovePropW(self.0,w!("Perpendicular.Window.Request").as_ptr());RemovePropW(self.0,w!("Perpendicular.Window.Result").as_ptr());}}}
            let _cleanup=Request(h);
            if SetPropW(h,w!("Perpendicular.Window.Operation").as_ptr(),op as usize as _)==0 ||
                SetPropW(h,w!("Perpendicular.Window.Buttons").as_ptr(),self.buttons as usize as _)==0 ||
                SetPropW(h,w!("Perpendicular.Window.Delta").as_ptr(),delta as u32 as usize as _)==0 ||
                SetPropW(h,w!("Perpendicular.Window.Request").as_ptr(),nonce as _)==0 {
                return Err("Cannot publish window input".into());
            }
            let message=RegisterWindowMessageW(w!("Perpendicular.Window.83cf5732-02d7-48a2-b121-ef5973d04b95").as_ptr());
            let packed=((x as u32 as u64)|((y as u32 as u64)<<32)) as isize;
            let mut ignored=0;
            if message==0 || SendMessageTimeoutW(h,message,nonce,packed,3,500,&mut ignored)==0 {
                return Err("Window input helper timed out".into());
            }
            let answer=GetPropW(h,w!("Perpendicular.Window.Result").as_ptr()) as usize;
            if answer!=1 {return Err(format!("Hidden window input rejected: {:#x}",answer.wrapping_sub(1)));}
            Ok(())
        }
    }
}
impl Drop for Window {
    fn drop(&mut self) {self.show();unsafe {
        if !self.call_hook.is_null(){UnhookWindowsHookEx(self.call_hook);}
        if !self.message_hook.is_null(){UnhookWindowsHookEx(self.message_hook);}
        if !self.module.is_null(){FreeLibrary(self.module);}
    }}
}
