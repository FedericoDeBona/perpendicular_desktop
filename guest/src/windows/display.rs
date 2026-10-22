use serde_json::{Value, json};
use std::{
    cell::Cell,
    collections::BTreeSet,
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{HINSTANCE, HMODULE, HWND, LPARAM, LRESULT, POINT, WPARAM},
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL},
            Direct3D11::*,
            Dxgi::{DXGI_ADAPTER_DESC1, DXGI_ADAPTER_FLAG_SOFTWARE, IDXGIAdapter1, IDXGIDevice},
            Gdi::*,
        },
        System::LibraryLoader::GetModuleHandleW,
        UI::{
            HiDpi::{
                DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForMonitor, MDT_EFFECTIVE_DPI,
                SetThreadDpiAwarenessContext,
            },
            WindowsAndMessaging::*,
        },
    },
    core::{Interface, PCWSTR, w},
};

/// Owned by the worker thread, whose message pump dispatches display broadcasts.
/// A hidden top-level window receives these broadcasts; a message-only window would not.
pub struct Observer {
    hwnd: HWND,
    instance: HINSTANCE,
    changed: Box<Cell<Option<Instant>>>,
}

impl Observer {
    pub fn new() -> Result<Self, String> {
        unsafe {
            let instance = HINSTANCE(GetModuleHandleW(None).map_err(|e| e.to_string())?.0);
            let class = WNDCLASSW {
                lpfnWndProc: Some(display_window_proc),
                hInstance: instance,
                lpszClassName: w!("PerpendicularDisplayObserver"),
                ..Default::default()
            };
            if RegisterClassW(&class) == 0 {
                return Err(windows::core::Error::from_thread().to_string());
            }
            let changed = Box::new(Cell::new(None));
            let hwnd = match CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                class.lpszClassName,
                w!(""),
                WS_POPUP,
                0,
                0,
                0,
                0,
                None,
                None,
                Some(instance),
                Some((&*changed as *const Cell<Option<Instant>>).cast()),
            ) {
                Ok(hwnd) => hwnd,
                Err(error) => {
                    let _ = UnregisterClassW(class.lpszClassName, Some(instance));
                    return Err(error.to_string());
                }
            };
            Ok(Self {
                hwnd,
                instance,
                changed,
            })
        }
    }

    /// Coalesce a burst of broadcasts without querying adapters or display modes.
    pub fn take_changed(&self) -> bool {
        if self
            .changed
            .get()
            .is_some_and(|time| time.elapsed() >= Duration::from_millis(200))
        {
            self.changed.set(None);
            true
        } else {
            false
        }
    }
}

impl Drop for Observer {
    fn drop(&mut self) {
        unsafe {
            let _ = DestroyWindow(self.hwnd);
            let _ = UnregisterClassW(w!("PerpendicularDisplayObserver"), Some(self.instance));
        }
    }
}

unsafe extern "system" fn display_window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    unsafe {
        match message {
            WM_NCCREATE => {
                let create = &*(lparam.0 as *const CREATESTRUCTW);
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
            }
            WM_DISPLAYCHANGE | WM_SETTINGCHANGE => {
                let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const Cell<Option<Instant>>;
                if let Some(changed) = state.as_ref() {
                    changed.set(Some(Instant::now()));
                }
            }
            WM_NCDESTROY => {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            }
            _ => {}
        }
        DefWindowProcW(hwnd, message, wparam, lparam)
    }
}

fn text(value: &[u16]) -> String {
    String::from_utf16_lossy(&value[..value.iter().position(|v| *v == 0).unwrap_or(value.len())])
}

/// Read the real adapter before admitting a graphics upgrade. A successful
/// hardware-device call is reported separately from capture and presentation.
pub fn graphics() -> Value {
    unsafe {
        let mut device = None;
        let mut level = D3D_FEATURE_LEVEL::default();
        if let Err(error) = D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            Some(&mut level),
            None,
        ) {
            return json!({"hardwareDevice":false,"message":error.to_string()});
        }
        match device.ok_or_else(windows::core::Error::from_thread).and_then(|device| device_description(&device)) {
            Ok(description) => description,
            Err(error) => json!({"hardwareDevice":false,"message":error.to_string()}),
        }
    }
}

/// Describe this exact device, including capture devices rather than a separate
/// probe. Basic Render may omit SOFTWARE; its PCI identity still denotes WARP.
pub fn device_description(device: &ID3D11Device) -> windows::core::Result<Value> {
    unsafe {
        let dxgi: IDXGIDevice = device.cast()?;
        let adapter: IDXGIAdapter1 = dxgi.GetAdapter()?.cast()?;
        let adapter: DXGI_ADAPTER_DESC1 = adapter.GetDesc1()?;
        let software = adapter.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0
            || (adapter.VendorId == 0x1414 && adapter.DeviceId == 0x008c);
        Ok(json!({"hardwareDevice":!software,"softwareAdapter":software,"adapterFlags":adapter.Flags,
            "adapter":text(&adapter.Description),"vendor":adapter.VendorId,"device":adapter.DeviceId,
            "featureLevel":device.GetFeatureLevel().0}))
    }
}

pub fn snapshot() -> Value {
    let mut displays = Vec::new();
    unsafe {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        for index in 0..16 {
            let mut device = DISPLAY_DEVICEW {
                cb: size_of::<DISPLAY_DEVICEW>() as u32,
                ..Default::default()
            };
            if !EnumDisplayDevicesW(None, index, &mut device, 0).as_bool() {
                break;
            }
            if !device
                .StateFlags
                .contains(DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)
                || device.StateFlags.contains(DISPLAY_DEVICE_MIRRORING_DRIVER)
            {
                continue;
            }
            let name = PCWSTR(device.DeviceName.as_ptr());
            let mut current = DEVMODEW {
                dmSize: size_of::<DEVMODEW>() as u16,
                ..Default::default()
            };
            if !EnumDisplaySettingsExW(name, ENUM_CURRENT_SETTINGS, &mut current, EDS_RAWMODE)
                .as_bool()
            {
                continue;
            }
            let position = current.Anonymous1.Anonymous2.dmPosition;
            let monitor = MonitorFromPoint(
                POINT {
                    x: position.x + 1,
                    y: position.y + 1,
                },
                MONITOR_DEFAULTTONULL,
            );
            let (mut dpi_x, mut dpi_y) = (0, 0);
            let dpi = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y)
                .ok()
                .map(|_| dpi_x);
            let mut info = MONITORINFO {
                cbSize: size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            let work_area = GetMonitorInfoW(monitor, &mut info).as_bool().then(|| {
                json!({"x":info.rcWork.left,"y":info.rcWork.top,
                    "width":info.rcWork.right-info.rcWork.left,
                    "height":info.rcWork.bottom-info.rcWork.top})
            });
            let mut modes = BTreeSet::new();
            for mode_index in 0..512 {
                let mut mode = DEVMODEW {
                    dmSize: size_of::<DEVMODEW>() as u16,
                    ..Default::default()
                };
                if !EnumDisplaySettingsExW(
                    name,
                    ENUM_DISPLAY_SETTINGS_MODE(mode_index),
                    &mut mode,
                    ENUM_DISPLAY_SETTINGS_FLAGS(0),
                )
                .as_bool()
                {
                    break;
                }
                modes.insert((mode.dmPelsWidth, mode.dmPelsHeight));
            }
            displays.push(json!({"device":text(&device.DeviceName),"adapter":text(&device.DeviceString),
                "primary":device.StateFlags.contains(DISPLAY_DEVICE_PRIMARY_DEVICE),
                "x":position.x,"y":position.y,"width":current.dmPelsWidth,"height":current.dmPelsHeight,
                "dpi":dpi,"workArea":work_area,
                "modes":modes.into_iter().map(|(w,h)|json!({"width":w,"height":h})).collect::<Vec<_>>()}));
        }
    }
    // Enumerating monitors must not initialize a possibly unhealthy graphics
    // driver on every connection. The hardware probe is an explicit operation.
    json!({"displays":displays})
}

/// Apply a mode advertised by the current primary display. RFB updates the
/// virtual monitor's preferred size; Windows still needs an explicit mode set.
pub fn configure(value: &Value) -> Result<Value, String> {
    let width = value["width"]
        .as_u64()
        .filter(|v| (640..=4096).contains(v))
        .ok_or("Invalid display width")? as u32;
    let height = value["height"]
        .as_u64()
        .filter(|v| (480..=4096).contains(v))
        .ok_or("Invalid display height")? as u32;
    if u64::from(width) * u64::from(height) > 8_388_608 {
        return Err("Display exceeds the current frame limit".into());
    }
    unsafe {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        for index in 0..16 {
            let mut display = DISPLAY_DEVICEW {
                cb: size_of::<DISPLAY_DEVICEW>() as u32,
                ..Default::default()
            };
            if !EnumDisplayDevicesW(None, index, &mut display, 0).as_bool() {
                break;
            }
            if !display
                .StateFlags
                .contains(DISPLAY_DEVICE_PRIMARY_DEVICE | DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)
            {
                continue;
            }
            let name = PCWSTR(display.DeviceName.as_ptr());
            let mut mode = DEVMODEW {
                dmSize: size_of::<DEVMODEW>() as u16,
                ..Default::default()
            };
            if !EnumDisplaySettingsExW(name, ENUM_CURRENT_SETTINGS, &mut mode, EDS_RAWMODE)
                .as_bool()
            {
                return Err("Cannot read the primary display mode".into());
            }
            let mut saved = DEVMODEW {
                dmSize: size_of::<DEVMODEW>() as u16,
                ..Default::default()
            };
            let saved_matches = EnumDisplaySettingsExW(
                name, ENUM_REGISTRY_SETTINGS, &mut saved, EDS_RAWMODE,
            ).as_bool() && saved.dmPelsWidth == width && saved.dmPelsHeight == height;
            if mode.dmPelsWidth == width && mode.dmPelsHeight == height && saved_matches {
                return Ok(snapshot());
            }
            mode.dmPelsWidth = width;
            mode.dmPelsHeight = height;
            mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
            let valid = ChangeDisplaySettingsExW(name, Some(&mode), None, CDS_TEST, None);
            if valid != DISP_CHANGE_SUCCESSFUL {
                return Err(format!(
                    "Windows does not support the requested display mode ({})",
                    valid.0
                ));
            }
            // The topology belongs to this user's monitor configuration. Keep
            // the saved mode consistent so a later desktop reset cannot restore
            // the old size merely because our change was only dynamic.
            let applied = ChangeDisplaySettingsExW(name, Some(&mode), None, CDS_UPDATEREGISTRY, None);
            if applied != DISP_CHANGE_SUCCESSFUL {
                return Err(format!(
                    "Windows could not apply the display mode ({})",
                    applied.0
                ));
            }
            return Ok(snapshot());
        }
    }
    Err("No active primary display".into())
}
