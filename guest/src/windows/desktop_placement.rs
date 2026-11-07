//! Preserve only ordinary windows that were on the original Desktop before
//! its temporary hotplug. Never collect or reposition the independent app displays.
use super::{catalogue, error, identity};
use serde_json::{Value, json};
use std::{collections::HashSet, time::{Duration, Instant}};
use windows::Win32::{
    Foundation::{HWND, POINT, RECT},
    Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MonitorFromWindow,
        MONITORINFOEXW, MONITOR_DEFAULTTOPRIMARY, MONITOR_DEFAULTTONEAREST},
    UI::WindowsAndMessaging::*,
};

struct SavedWindow {
    raw: usize,
    owner: (u32, u64),
    class: String,
    frame: RECT,
    outer: RECT,
    placement: WINDOWPLACEMENT,
    attempted: bool,
}

pub struct Snapshot {
    token: String,
    device: String,
    started: Instant,
    windows: Vec<SavedWindow>,
    pass: Option<u32>,
}

fn primary(device: &str) -> Result<MONITORINFOEXW, String> {
    unsafe {
        let monitor=MonitorFromPoint(POINT::default(),MONITOR_DEFAULTTOPRIMARY);
        let mut info=MONITORINFOEXW::default();
        info.monitorInfo.cbSize=size_of::<MONITORINFOEXW>() as u32;
        if !GetMonitorInfoW(monitor,&mut info.monitorInfo).as_bool()
            || info.monitorInfo.dwFlags&1==0
            || info.monitorInfo.rcMonitor.left!=0 || info.monitorInfo.rcMonitor.top!=0 {
            return Err("Original Desktop monitor is not settled".into());
        }
        let count=info.szDevice.iter().position(|v|*v==0).unwrap_or(info.szDevice.len());
        if String::from_utf16_lossy(&info.szDevice[..count])!=device {
            return Err("Original Desktop monitor is not primary".into());
        }
        Ok(info)
    }
}

fn idle() -> Result<(), String> {
    unsafe {
        let mut gui=GUITHREADINFO{cbSize:size_of::<GUITHREADINFO>() as u32,..Default::default()};
        GetGUIThreadInfo(0,&mut gui).map_err(error)?;
        if !gui.hwndCapture.is_invalid() || gui.flags.0&0x1e!=0 {
            return Err("Finish the current Windows interaction before resizing the Desktop".into());
        }
    }
    Ok(())
}

fn fit(rect: RECT, work: RECT) -> RECT {
    let width=(rect.right-rect.left).clamp(1,(work.right-work.left).max(1));
    let height=(rect.bottom-rect.top).clamp(1,(work.bottom-work.top).max(1));
    let left=rect.left.clamp(work.left,work.right-width);
    let top=rect.top.clamp(work.top,work.bottom-height);
    RECT{left,top,right:left+width,bottom:top+height}
}

impl Snapshot {
    pub fn begin(token: &str, device: &str, sid: &str, session: u32,
                 excluded: &HashSet<usize>) -> Result<Self,String> {
        if token.is_empty() || token.len()>64 {return Err("Invalid Desktop resize identity".into());}
        let info=primary(device)?;
        idle()?;
        let mut windows=Vec::new();
        for raw in catalogue::windows() {
            if excluded.contains(&raw) || catalogue::shell_surface(raw) {continue;}
            let hwnd=HWND(raw as _);
            let Some(meta)=catalogue::details(raw,sid,session) else{continue};
            if meta["visible"]!=true || meta["minimized"]==true || catalogue::transient(&meta) {continue;}
            unsafe {
                if GetWindowLongPtrW(hwnd,GWL_EXSTYLE) as u32 & (WS_EX_TOOLWINDOW.0|WS_EX_NOACTIVATE.0)!=0 {continue;}
                let monitor=MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST);
                let mut current=MONITORINFOEXW::default();
                current.monitorInfo.cbSize=size_of::<MONITORINFOEXW>() as u32;
                if !GetMonitorInfoW(monitor,&mut current.monitorInfo).as_bool()
                    || current.szDevice!=info.szDevice {continue;}
                let Some(owner)=identity::owner(hwnd,sid,session) else{continue};
                let Some(frame)=catalogue::frame_bounds(hwnd) else{continue};
                let mut outer=RECT::default();
                let mut placement=WINDOWPLACEMENT{length:size_of::<WINDOWPLACEMENT>() as u32,..Default::default()};
                if GetWindowRect(hwnd,&mut outer).is_err() || GetWindowPlacement(hwnd,&mut placement).is_err() {continue;}
                if windows.len()==128 {return Err("Too many Desktop windows to preserve".into());}
                windows.push(SavedWindow{raw,owner,class:meta["class"].as_str().unwrap_or("").to_owned(),
                    frame,outer,placement,attempted:false});
            }
        }
        Ok(Self{token:token.to_owned(),device:device.to_owned(),started:Instant::now(),windows,pass:None})
    }

    pub fn matches(&self, token: &str) -> bool {
        self.token==token && self.started.elapsed()<Duration::from_secs(120)
    }

    pub fn count(&self) -> usize {self.windows.len()}

    pub fn restore(&mut self, value: &Value, sid: &str, session: u32,
                   excluded: &HashSet<usize>) -> Result<Value,String> {
        let token=value["token"].as_str().ok_or("Missing Desktop resize identity")?;
        if !self.matches(token) {return Err("Desktop resize identity expired or changed".into());}
        let info=primary(&self.device)?;
        let work=info.monitorInfo.rcWork;
        idle()?;
        let pass=value["pass"].as_u64().and_then(|v|u32::try_from(v).ok()).ok_or("Missing resize pass")?;
        if self.pass!=Some(pass) {
            for saved in &mut self.windows {saved.attempted=false;}
            self.pass=Some(pass);
        }
        let (mut restored,mut skipped,mut pending)=(0,0,0);
        let mut move_foreground=None;
        for saved in &mut self.windows {
            let hwnd=HWND(saved.raw as _);
            // Revalidate exact same-user/session process creation, HWND class
            // and current ownership. Never resurrect closed/minimized windows.
            if excluded.contains(&saved.raw) || identity::owner(hwnd,sid,session)!=Some(saved.owner)
                || catalogue::window_class(saved.raw)!=saved.class {skipped+=1;continue;}
            let Some(meta)=catalogue::details(saved.raw,sid,session) else{skipped+=1;continue;};
            if meta["visible"]!=true || meta["minimized"]==true {skipped+=1;continue;}
            unsafe {
                let monitor=MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST);
                let mut current=MONITORINFOEXW::default();
                current.monitorInfo.cbSize=size_of::<MONITORINFOEXW>() as u32;
                if !GetMonitorInfoW(monitor,&mut current.monitorInfo).as_bool() {pending+=1;continue;}
                let bounds=catalogue::frame_bounds(hwnd);
                let contained=bounds.is_some_and(|r|r.left>=work.left-1 && r.top>=work.top-1
                    && r.right<=work.right+1 && r.bottom<=work.bottom+1);
                let show_matches=saved.placement.showCmd!=SW_SHOWMAXIMIZED.0 as u32 || IsZoomed(hwnd).as_bool();
                if current.szDevice==info.szDevice && contained && show_matches {restored+=1;continue;}
                pending+=1;
                if saved.attempted {
                    // Some maximized UWP frames acknowledge positioning but
                    // remain on the old output. Only the exact, already focused
                    // saved window can authorize the existing device shortcut.
                    if current.szDevice!=info.szDevice && GetAncestor(GetForegroundWindow(),GA_ROOT)==hwnd {
                        if let Some(r)=bounds {move_foreground=Some(format!("{}:{},{},{},{}",saved.raw,r.left,r.top,r.right,r.bottom));}
                    }
                    continue;
                }
                let mut placement=saved.placement;
                // WINDOWPLACEMENT uses workspace coordinates, unlike SetWindowPos.
                // Both snapshots refer to this same primary (origin zero).
                let workspace=RECT{left:0,top:0,right:work.right-work.left,bottom:work.bottom-work.top};
                placement.rcNormalPosition=fit(placement.rcNormalPosition,workspace);
                placement.flags=WPF_ASYNCWINDOWPLACEMENT;
                // Preserve the existing show state without activating a window.
                placement.showCmd=SW_SHOWNA.0 as u32;
                SetWindowPlacement(hwnd,&placement).map_err(error)?;
                let frame=if saved.placement.showCmd==SW_SHOWMAXIMIZED.0 as u32 {work}else{fit(saved.frame,work)};
                let left=frame.left+saved.outer.left-saved.frame.left;
                let top=frame.top+saved.outer.top-saved.frame.top;
                let width=frame.right-frame.left+(saved.outer.right-saved.outer.left)-(saved.frame.right-saved.frame.left);
                let height=frame.bottom-frame.top+(saved.outer.bottom-saved.outer.top)-(saved.frame.bottom-saved.frame.top);
                SetWindowPos(hwnd,None,left,top,width,height,
                    SWP_NOACTIVATE|SWP_NOZORDER|SWP_NOOWNERZORDER|SWP_ASYNCWINDOWPOS).map_err(error)?;
                saved.attempted=true;
            }
        }
        Ok(json!({"complete":pending==0,"total":self.windows.len(),"onDesktop":restored,"skipped":skipped,"pending":pending,
            "moveForegroundRect":move_foreground,"maxMoves":unsafe{GetSystemMetrics(SM_CMONITORS).clamp(1,8)}}))
    }
}
