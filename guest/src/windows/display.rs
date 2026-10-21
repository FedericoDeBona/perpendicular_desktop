use serde_json::{Value, json};
use std::collections::BTreeSet;
use windows::{
    Win32::{
        Foundation::{HMODULE, POINT},
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL},
            Direct3D11::*,
            Dxgi::{DXGI_ADAPTER_DESC1, DXGI_ADAPTER_FLAG_SOFTWARE, IDXGIAdapter1, IDXGIDevice},
            Gdi::*,
        },
        UI::HiDpi::{
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForMonitor, MDT_EFFECTIVE_DPI,
            SetThreadDpiAwarenessContext,
        },
    },
    core::{Interface, PCWSTR},
};

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
        let describe = || -> windows::core::Result<DXGI_ADAPTER_DESC1> {
            let dxgi: IDXGIDevice = device.unwrap().cast()?;
            let adapter: IDXGIAdapter1 = dxgi.GetAdapter()?.cast()?;
            adapter.GetDesc1()
        };
        match describe() {
            Ok(adapter) => {
                // The primary Basic Render adapter can omit SOFTWARE even when
                // D3D_DRIVER_TYPE_HARDWARE succeeds. Its documented PCI IDs still
                // identify WARP: https://learn.microsoft.com/windows/win32/direct3ddxgi/d3d10-graphics-programming-guide-dxgi
                let software = adapter.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0
                    || (adapter.VendorId == 0x1414 && adapter.DeviceId == 0x008c);
                json!({"hardwareDevice":!software,"softwareAdapter":software,"adapterFlags":adapter.Flags,
                    "adapter":text(&adapter.Description),"vendor":adapter.VendorId,"device":adapter.DeviceId,
                    "featureLevel":level.0})
            }
            Err(error) => json!({"hardwareDevice":false,"message":error.to_string()}),
        }
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
                "dpi":dpi,"modes":modes.into_iter().map(|(w,h)|json!({"width":w,"height":h})).collect::<Vec<_>>()}));
        }
    }
    // Enumerating monitors must not initialize a possibly unhealthy graphics
    // driver on every connection. The hardware probe is an explicit operation.
    json!({"displays":displays})
}
