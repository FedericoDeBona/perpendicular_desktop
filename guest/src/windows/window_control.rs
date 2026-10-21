use super::{capture::Target, catalogue, error};
use serde_json::{Value, json};
use windows::Win32::{
    Foundation::{HWND, LPARAM, POINT, RECT, WPARAM},
    Graphics::Gdi::ClientToScreen,
    UI::WindowsAndMessaging::*,
};

fn work_area() -> RECT {
    unsafe {
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

pub fn limits(hwnd: HWND, full: bool) -> (i32, i32) {
    unsafe {
        let area = work_area();
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
    let details =
        catalogue::details(target.hwnd, &target.sid, target.session).ok_or("Window retired")?;
    let (max_width, max_height) = limits(hwnd, target.full_frame);
    Ok(json!({"width":details["width"],"height":details["height"],
        "maxWidth":max_width,"maxHeight":max_height}))
}

pub fn hit_test(target: &Target, value: &Value) -> Result<Value, String> {
    unsafe {
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
        let coordinates = (point.x as u16 as u32) | ((point.y as u16 as u32) << 16);
        let mut hit = 0usize;
        if SendMessageTimeoutW(
            hwnd,
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
        let area = work_area();
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
