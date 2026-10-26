use super::{capture::Target, catalogue, error};
use serde_json::{Value, json};
use std::sync::{Mutex, OnceLock};
use std::sync::atomic::{AtomicBool,Ordering};
use windows::Win32::{
    Foundation::{HWND, LPARAM, POINT, RECT, WPARAM},
    Graphics::Gdi::{ClientToScreen, GetMonitorInfoW, MonitorFromWindow, MonitorFromRect,
        MONITORINFO, MONITOR_DEFAULTTONEAREST},
    UI::{HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi}, WindowsAndMessaging::*},
};

static APP_AREAS: OnceLock<Mutex<Vec<(RECT,RECT)>>> = OnceLock::new();
static NATIVE_APP_INPUT:AtomicBool=AtomicBool::new(false);

pub fn set_native_app_input(enabled:bool)->Result<(),String> {
    if enabled && APP_AREAS.get().and_then(|a|a.lock().ok()).is_none_or(|a|a.is_empty()) {
        return Err("App displays are not configured".into());
    }
    NATIVE_APP_INPUT.store(enabled,Ordering::Release);Ok(())
}
pub fn native_app_input_allowed(hwnd:HWND)->bool {
    if !NATIVE_APP_INPUT.load(Ordering::Acquire){return false;}
    let Some(bounds)=catalogue::frame_bounds(hwnd) else{return false;};
    let Some(areas)=APP_AREAS.get().and_then(|a|a.lock().ok()) else{return false;};
    unsafe {
        let monitor=MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST);
        let mut info=MONITORINFO{cbSize:size_of::<MONITORINFO>() as u32,..Default::default()};
        if !GetMonitorInfoW(monitor,&mut info).as_bool() || info.dwFlags & 1 != 0 {return false;}
        areas.iter().any(|(frame,_)|*frame==info.rcMonitor && bounds.left>=frame.left-1
            && bounds.top>=frame.top-1 && bounds.right<=frame.right+1 && bounds.bottom<=frame.bottom+1)
    }
}
pub fn native_app_input_configured()->bool {NATIVE_APP_INPUT.load(Ordering::Acquire)}

/// Limits of authenticated native app windows, separate from Explorer's
/// global work areas. Never move the taskbar or reserve space on the desktop.
pub fn set_app_work_areas(areas: Vec<(RECT,RECT)>) -> Result<(),String> {
    *APP_AREAS.get_or_init(||Mutex::new(Vec::new())).lock().map_err(|_|"App display state unavailable")?=areas;
    Ok(())
}
pub fn app_work_area(monitor:RECT,current:RECT)->RECT {
    let Some(areas)=APP_AREAS.get() else{return current};
    let Ok(areas)=areas.lock() else{return current};
    let Some((_,area))=areas.iter().find(|(frame,_)|*frame==monitor) else{return current};
    let result=RECT{left:current.left.max(area.left),top:current.top.max(area.top),
        right:current.right.min(area.right),bottom:current.bottom.min(area.bottom)};
    if result.right-result.left>=160 && result.bottom-result.top>=100 {result}else{current}
}

fn work_area(hwnd: HWND, requested: Option<&RECT>) -> RECT {
    unsafe {
        let monitor = match requested {
            Some(rect) => MonitorFromRect(rect, MONITOR_DEFAULTTONEAREST),
            None => MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
        };
        let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
        if GetMonitorInfoW(monitor, &mut info).as_bool() { return app_work_area(info.rcMonitor,info.rcWork); }
        let mut area = RECT::default();
        if SystemParametersInfoW(
            SPI_GETWORKAREA,
            0,
            Some((&mut area as *mut RECT).cast()),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
        .is_err()
        {
            area.right = GetSystemMetrics(SM_CXSCREEN);
            area.bottom = GetSystemMetrics(SM_CYSCREEN);
        }
        area
    }
}

/// Ask only admitted app windows, with a bounded cross-process system message.
/// MINMAXINFO describes the outer HWND; the host displays the captured surface.
pub fn minimum_size(hwnd: HWND, full: bool) -> Option<(i32, i32)> {
    unsafe {
        let dpi = GetDpiForWindow(hwnd).max(96);
        let area = work_area(hwnd, None);
        let mut info = MINMAXINFO {
            ptMaxPosition: POINT { x: area.left, y: area.top },
            ptMaxSize: POINT { x: area.right-area.left, y: area.bottom-area.top },
            ptMinTrackSize: POINT {
                x: GetSystemMetricsForDpi(SM_CXMINTRACK, dpi),
                y: GetSystemMetricsForDpi(SM_CYMINTRACK, dpi),
            },
            ptMaxTrackSize: POINT {
                x: GetSystemMetricsForDpi(SM_CXMAXTRACK, dpi),
                y: GetSystemMetricsForDpi(SM_CYMAXTRACK, dpi),
            },
            ..Default::default()
        };
        if SendMessageTimeoutW(hwnd, WM_GETMINMAXINFO, WPARAM(0),
            LPARAM((&mut info as *mut MINMAXINFO) as isize),
            SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT, 25, None).0 == 0 {
            return None;
        }
        let mut outer = RECT::default();
        GetWindowRect(hwnd, &mut outer).ok()?;
        let surface = if full { catalogue::frame_bounds(hwnd)? } else {
            let mut client = RECT::default();
            GetClientRect(hwnd, &mut client).ok()?;
            client
        };
        let width = info.ptMinTrackSize.x - ((outer.right-outer.left)-(surface.right-surface.left));
        let height = info.ptMinTrackSize.y - ((outer.bottom-outer.top)-(surface.bottom-surface.top));
        ((1..=32768).contains(&width) && (1..=32768).contains(&height)).then_some((width,height))
    }
}

pub fn describe_minimum(metadata: &mut Value) {
    let minimum = if metadata["resizable"] == true && !catalogue::transient(metadata) {
        metadata["hwnd"].as_u64().and_then(|raw|
            minimum_size(HWND(raw as usize as *mut _), metadata["role"] != "dialog"))
    } else { None };
    metadata["minWidth"] = minimum.map(|m| json!(m.0)).unwrap_or(Value::Null);
    metadata["minHeight"] = minimum.map(|m| json!(m.1)).unwrap_or(Value::Null);
}

pub fn limits(hwnd: HWND, full: bool) -> (i32, i32) {
    limits_in(hwnd, full, work_area(hwnd, None))
}

fn limits_in(hwnd: HWND, full: bool, area: RECT) -> (i32, i32) {
    unsafe {
        let mut outer = RECT::default();
        let _ = GetWindowRect(hwnd, &mut outer);
        let mut client = RECT::default();
        let _ = GetClientRect(hwnd, &mut client);
        let surface = if full {
            catalogue::frame_bounds(hwnd).unwrap_or(outer)
        } else {
            client
        };
        // Invisible DWM borders are not part of a full-window capture.
        let trim_x = if full {
            0
        } else {
            (outer.right - outer.left) - (surface.right - surface.left)
        };
        let trim_y = if full {
            0
        } else {
            (outer.bottom - outer.top) - (surface.bottom - surface.top)
        };
        (
            (area.right - area.left - trim_x).max(160),
            (area.bottom - area.top - trim_y).max(100),
        )
    }
}

pub fn state(target: &Target) -> Result<Value, String> {
    let hwnd = HWND(target.hwnd as *mut _);
    let mut details =
        catalogue::details(target.hwnd, &target.sid, target.session).ok_or("Window retired")?;
    describe_minimum(&mut details);
    let (max_width, max_height) = limits(hwnd, target.full_frame);
    Ok(json!({"x":details["x"],"y":details["y"],
        "width":details["width"],"height":details["height"],
        "maxWidth":max_width,"maxHeight":max_height,
        "minWidth":details["minWidth"],"minHeight":details["minHeight"]}))
}

/// Coordinates describe the captured surface: DWM frame for main windows and
/// client area for dialogs. The invisible Windows borders remain on the guest.
/// Acceptance is distinct from completion; `state` reads the resulting geometry.
pub fn set_geometry(target: &Target, value: &Value) -> Result<Value, String> {
    let gesture = value["gesture"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 64 && s.is_ascii())
        .ok_or("Missing geometry interaction identity")?;
    let serial = value["serial"]
        .as_u64()
        .filter(|v| *v > 0)
        .ok_or("Invalid geometry request serial")?;
    let coordinate = |name: &str| {
        value[name]
            .as_i64()
            .and_then(|v| i32::try_from(v).ok())
            .filter(|v| (-1_000_000..=1_000_000).contains(v))
            .ok_or_else(|| format!("Invalid window {name}"))
    };
    let requested_x = coordinate("x")?;
    let requested_y = coordinate("y")?;
    let width = value["width"]
        .as_i64()
        .filter(|v| (160..=4096).contains(v))
        .ok_or("Invalid window width")? as i32;
    let height = value["height"]
        .as_i64()
        .filter(|v| (100..=4096).contains(v))
        .ok_or("Invalid window height")? as i32;
    unsafe {
        let hwnd = HWND(target.hwnd as *mut _);
        let requested = RECT { left: requested_x, top: requested_y,
            right: requested_x + width, bottom: requested_y + height };
        let area = work_area(hwnd, Some(&requested));
        let (max_width, max_height) = limits_in(hwnd, target.full_frame, area);
        let (width, height) = (width.min(max_width), height.min(max_height));
        let mut outer = RECT::default();
        GetWindowRect(hwnd, &mut outer).map_err(error)?;
        let surface = if target.full_frame {
            catalogue::frame_bounds(hwnd).ok_or("Window geometry unavailable")?
        } else {
            let mut client = RECT::default();
            GetClientRect(hwnd, &mut client).map_err(error)?;
            let mut origin = POINT::default();
            if !ClientToScreen(hwnd, &mut origin).as_bool() {
                return Err("Window geometry unavailable".into());
            }
            RECT {
                left: origin.x,
                top: origin.y,
                right: origin.x + client.right,
                bottom: origin.y + client.bottom,
            }
        };
        let extra_x = outer.right - outer.left - (surface.right - surface.left);
        let extra_y = outer.bottom - outer.top - (surface.bottom - surface.top);
        let offset_x = surface.left - outer.left;
        let offset_y = surface.top - outer.top;
        let (x, y) = if target.full_frame {
            (
                requested_x.clamp(area.left, (area.right - width).max(area.left)) - offset_x,
                requested_y.clamp(area.top, (area.bottom - height).max(area.top)) - offset_y,
            )
        } else {
            (
                (requested_x - offset_x)
                    .clamp(area.left, (area.right - width - extra_x).max(area.left)),
                (requested_y - offset_y)
                    .clamp(area.top, (area.bottom - height - extra_y).max(area.top)),
            )
        };
        if IsZoomed(hwnd).as_bool() {
            let _ = ShowWindowAsync(hwnd, SW_RESTORE);
        }
        SetWindowPos(
            hwnd,
            None,
            x,
            y,
            width + extra_x,
            height + extra_y,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS,
        )
        .map_err(error)?;
        // This is the requested surface after the known work-area clamp,
        // not proof that the target thread has processed SetWindowPos yet.
        Ok(json!({"accepted":true,"gesture":gesture,"serial":serial,
            "x":x+offset_x,"y":y+offset_y,"width":width,"height":height}))
    }
}

pub fn hit_test(target: &Target, value: &Value) -> Result<Value, String> {
    unsafe {
        if !target.valid() { return Err("Window retired".into()); }
        let (generation, width, height, offset_x, offset_y) = *target.geometry.lock().unwrap();
        if value["generation"].as_u64() != Some(generation) {
            return Err("Window geometry is updating".into());
        }
        let x = value["x"]
            .as_i64()
            .filter(|x| *x >= 0 && *x < i64::from(width))
            .ok_or("Pointer outside window")? as i32;
        let y = value["y"]
            .as_i64()
            .filter(|y| *y >= 0 && *y < i64::from(height))
            .ok_or("Pointer outside window")? as i32;
        let hwnd = HWND(target.hwnd as *mut _);
        let mut point = POINT {
            x: x + offset_x,
            y: y + offset_y,
        };
        if !ClientToScreen(hwnd, &mut point).as_bool() {
            return Err("Pointer transform unavailable".into());
        }
        if native_app_input_allowed(hwnd) {
            let hit=WindowFromPoint(point);
            if !hit.is_invalid() && hit != hwnd && GetAncestor(hit,GA_ROOT)==hwnd {
                // Windows owns hit testing of the real child/control. Do not
                // convert its custom caption band into a synthetic Mac drag.
                return Ok(json!({"hit":1,"nativeChild":true}));
            }
        }
        let mut receiver = hwnd;
        if let Some(content) = &target.hosted {
            let child = HWND(content.hwnd as *mut _);
            let mut client = RECT::default();
            GetClientRect(child, &mut client).map_err(error)?;
            if client.right <= client.left || client.bottom <= client.top {
                return Err("Window geometry unavailable".into());
            }
            let mut origin = POINT { x: client.left, y: client.top };
            if !ClientToScreen(child, &mut origin).as_bool() {
                return Err("Pointer transform unavailable".into());
            }
            // WinUI controls can occupy the frame host's caption region.
            // Only the authenticated child decides its own client-area hit.
            if point.x >= origin.x && point.x < origin.x + client.right - client.left
                && point.y >= origin.y && point.y < origin.y + client.bottom - client.top
            {
                receiver = child;
            }
        }
        if !target.valid() { return Err("Window retired".into()); }
        let coordinates = (point.x as u16 as u32) | ((point.y as u16 as u32) << 16);
        let mut hit = 0usize;
        if SendMessageTimeoutW(
            receiver,
            WM_NCHITTEST,
            WPARAM(0),
            LPARAM(coordinates as isize),
            SMTO_ABORTIFHUNG | SMTO_BLOCK,
            80,
            Some(&mut hit),
        )
        .0 == 0
        {
            return Err("Window did not respond".into());
        }
        if !target.valid() { return Err("Window retired".into()); }
        Ok(json!({"hit":hit as i32}))
    }
}

pub fn cancel(hwnd: HWND) {
    unsafe {
        let _ = PostMessageW(Some(hwnd), WM_CANCELMODE, WPARAM(0), LPARAM(0));
    }
}

pub fn resize(target: &Target, value: &Value) -> Result<Value, String> {
    unsafe {
        let hwnd = HWND(target.hwnd as *mut _);
        let (max_width, max_height) = limits(hwnd, target.full_frame);
        let width = value["width"]
            .as_i64()
            .filter(|v| (160..=4096).contains(v))
            .ok_or("Invalid window width")? as i32;
        let height = value["height"]
            .as_i64()
            .filter(|v| (100..=4096).contains(v))
            .ok_or("Invalid window height")? as i32;
        let width = width.min(max_width);
        let height = height.min(max_height);
        let mut outer = RECT::default();
        GetWindowRect(hwnd, &mut outer).map_err(error)?;
        let surface = if target.full_frame {
            catalogue::frame_bounds(hwnd).ok_or("Window geometry unavailable")?
        } else {
            let mut r = RECT::default();
            GetClientRect(hwnd, &mut r).map_err(error)?;
            r
        };
        let extra_x = outer.right - outer.left - (surface.right - surface.left);
        let extra_y = outer.bottom - outer.top - (surface.bottom - surface.top);
        let area = work_area(hwnd, None);
        let visible = catalogue::frame_bounds(hwnd).unwrap_or(outer);
        let full_width = if target.full_frame {
            width
        } else {
            width + extra_x
        };
        let full_height = if target.full_frame {
            height
        } else {
            height + extra_y
        };
        let x = visible
            .left
            .clamp(area.left, (area.right - full_width).max(area.left))
            - (visible.left - outer.left);
        let y = visible
            .top
            .clamp(area.top, (area.bottom - full_height).max(area.top))
            - (visible.top - outer.top);
        cancel(hwnd);
        // No guest mouse drag: apply one bounded request after the Mac resize ends.
        if IsZoomed(hwnd).as_bool() {
            let _ = ShowWindowAsync(hwnd, SW_RESTORE);
        }
        SetWindowPos(
            hwnd,
            None,
            x,
            y,
            width + extra_x,
            height + extra_y,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS,
        )
        .map_err(error)?;
        Ok(json!({"accepted":true,"width":width,"height":height}))
    }
}
