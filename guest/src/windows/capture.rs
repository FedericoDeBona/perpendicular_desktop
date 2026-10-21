use super::{catalogue, error, identity, wire::Outbox};
use serde_json::json;
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use windows::{
    Graphics::{
        Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession},
        DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
    },
    Win32::{
        Foundation::{HMODULE, HWND, POINT, RECT},
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE_WARP, D3D_FEATURE_LEVEL_11_0},
            Direct3D11::*,
            Dwm::{DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute},
            Dxgi::{Common::DXGI_FORMAT_B8G8R8A8_UNORM, IDXGIDevice},
            Gdi::ClientToScreen,
        },
        System::WinRT::{
            Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess},
            Graphics::Capture::IGraphicsCaptureItemInterop,
            RO_INIT_MULTITHREADED, RoInitialize,
        },
        UI::{
            HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext},
            WindowsAndMessaging::{GetClientRect, GetWindowRect, IsIconic},
        },
    },
    core::{Interface, factory},
};

pub struct Target {
    pub id: String,
    pub hwnd: usize,
    pub pid: u32,
    pub creation: u64,
    pub sid: String,
    pub session: u32,
    pub full_frame: bool,
    // Generation, dimensions, and image origin relative to the Windows client origin.
    pub geometry: Mutex<(u64, i32, i32, i32, i32)>,
}
impl Target {
    pub fn valid(&self) -> bool {
        identity::owner(HWND(self.hwnd as *mut _), &self.sid, self.session)
            == Some((self.pid, self.creation))
    }
}

pub fn spawn(target: Arc<Target>, outbox: Arc<Outbox>) -> Arc<AtomicBool> {
    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    std::thread::spawn(move || {
        if let Err(message) = unsafe { run(&target, &outbox, &flag) } {
            if !flag.load(Ordering::Acquire) {
                outbox.control(json!({"type":"window_error","window":target.id,"message":message}));
            }
        }
        outbox.retire(&target.id);
    });
    stop
}

unsafe fn run(target: &Target, outbox: &Outbox, stop: &AtomicBool) -> Result<(), String> {
    unsafe {
        RoInitialize(RO_INIT_MULTITHREADED).map_err(error)?;
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        if !GraphicsCaptureSession::IsSupported().map_err(error)? {
            return Err("Window capture is unsupported".into());
        }
        let mut device = None;
        let mut context = None;
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_WARP,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            Some(&[D3D_FEATURE_LEVEL_11_0]),
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )
        .map_err(error)?;
        let device = device.ok_or("Missing capture device")?;
        let context = context.ok_or("Missing capture context")?;
        let dxgi: IDXGIDevice = device.cast().map_err(error)?;
        let runtime: IDirect3DDevice = CreateDirect3D11DeviceFromDXGIDevice(&dxgi)
            .map_err(error)?
            .cast()
            .map_err(error)?;
        let interop: IGraphicsCaptureItemInterop =
            factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(error)?;
        // A minimized HWND can initially report a tiny backing surface. Wait for a
        // normal window before allocating its capture pool, including after reconnect.
        while IsIconic(HWND(target.hwnd as *mut _)).as_bool() {
            if stop.load(Ordering::Acquire)
                || !outbox.connected.load(Ordering::Acquire)
                || !target.valid()
            {
                windows::Win32::System::WinRT::RoUninitialize();
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(75));
        }
        let item: GraphicsCaptureItem = interop
            .CreateForWindow(HWND(target.hwnd as *mut _))
            .map_err(error)?;
        let mut size = item.Size().map_err(error)?;
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            &runtime,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2,
            size,
        )
        .map_err(error)?;
        let session = pool.CreateCaptureSession(&item).map_err(error)?;
        let _ = session.SetIsCursorCaptureEnabled(false);
        // Capture each surface independently: popups may extend beyond the document,
        // and real dialogs must not also be baked into the document's pixels.
        let _ = session.SetIncludeSecondaryWindows(false);
        session.StartCapture().map_err(error)?;
        let result = (|| -> Result<(), String> {
            let mut sequence = 0u64;
            let mut generation = 1u64;
            let mut previous = [0; 6];
            let mut staging: Option<ID3D11Texture2D> = None;
            let mut staging_size = (0, 0);
            while !stop.load(Ordering::Acquire) && outbox.connected.load(Ordering::Acquire) {
                let started = Instant::now();
                if !target.valid() {
                    break;
                }
                if IsIconic(HWND(target.hwnd as *mut _)).as_bool() {
                    std::thread::sleep(Duration::from_millis(100));
                    continue;
                }
                let Ok(frame) = pool.TryGetNextFrame() else {
                    std::thread::sleep(Duration::from_millis(15));
                    continue;
                };
                let current = frame.ContentSize().map_err(error)?;
                if current.Width <= 0
                    || current.Height <= 0
                    || i64::from(current.Width) * i64::from(current.Height) > 4_194_304
                {
                    let _ = frame.Close();
                    return Err("Window exceeds the initial capture limit".into());
                }
                if current != size {
                    frame.Close().map_err(error)?;
                    size = current;
                    generation += 1;
                    staging = None;
                    pool.Recreate(
                        &runtime,
                        DirectXPixelFormat::B8G8R8A8UIntNormalized,
                        2,
                        size,
                    )
                    .map_err(error)?;
                    continue;
                }
                let access: IDirect3DDxgiInterfaceAccess =
                    frame.Surface().map_err(error)?.cast().map_err(error)?;
                let texture: ID3D11Texture2D = access.GetInterface().map_err(error)?;
                let mut desc = D3D11_TEXTURE2D_DESC::default();
                texture.GetDesc(&mut desc);
                // ContentSize can precede the resized backing texture during restore.
                // Never read rows outside that texture, or end a healthy capture for it.
                if desc.Width < current.Width as u32 || desc.Height < current.Height as u32 {
                    frame.Close().map_err(error)?;
                    staging = None;
                    pool.Recreate(
                        &runtime,
                        DirectXPixelFormat::B8G8R8A8UIntNormalized,
                        2,
                        size,
                    )
                    .map_err(error)?;
                    continue;
                }
                if staging_size != (desc.Width, desc.Height) {
                    staging = None;
                    staging_size = (desc.Width, desc.Height);
                }
                let hwnd = HWND(target.hwnd as *mut _);
                let (x, y, width, height) = if target.full_frame {
                    (0, 0, size.Width, size.Height)
                } else {
                    client(hwnd, size.Width, size.Height)?
                };
                let geometry = [size.Width, size.Height, x, y, width, height];
                if geometry != previous {
                    generation += 1;
                    previous = geometry;
                }
                if staging.is_none() {
                    desc.Usage = D3D11_USAGE_STAGING;
                    desc.BindFlags = 0;
                    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
                    desc.MiscFlags = 0;
                    desc.MipLevels = 1;
                    desc.ArraySize = 1;
                    if desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM || desc.SampleDesc.Count != 1 {
                        return Err("Unsupported capture format".into());
                    }
                    device
                        .CreateTexture2D(&desc, None, Some(&mut staging))
                        .map_err(error)?;
                }
                let backing = staging.as_ref().ok_or("Missing readback resource")?;
                context.CopyResource(backing, &texture);
                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                context
                    .Map(backing, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
                    .map_err(error)?;
                let mut pixels = vec![0u8; (width * height * 4) as usize];
                let valid =
                    !mapped.pData.is_null() && mapped.RowPitch as i64 >= i64::from(x + width) * 4;
                if valid {
                    for row in 0..height as usize {
                        std::ptr::copy_nonoverlapping(
                            (mapped.pData as *const u8).add(
                                (row + y as usize) * mapped.RowPitch as usize + x as usize * 4,
                            ),
                            pixels.as_mut_ptr().add(row * width as usize * 4),
                            width as usize * 4,
                        );
                    }
                }
                context.Unmap(backing, 0);
                frame.Close().map_err(error)?;
                if !valid {
                    return Err("Invalid capture stride".into());
                }
                sequence += 1;
                let bounds = catalogue::frame_bounds(hwnd).ok_or("Window geometry unavailable")?;
                let mut origin = POINT::default();
                if !ClientToScreen(hwnd, &mut origin).as_bool() {
                    return Err("Window geometry unavailable".into());
                }
                let offset = if target.full_frame {
                    (bounds.left - origin.x, bounds.top - origin.y)
                } else {
                    (0, 0)
                };
                *target.geometry.lock().unwrap() = (generation, width, height, offset.0, offset.1);
                outbox.frame(&target.id,json!({"type":"frame","window":target.id,"sequence":sequence,"generation":generation,
                    "width":width,"height":height,"bytes":pixels.len(),"capture":"software"}),pixels);
                if let Some(delay) = Duration::from_millis(40).checked_sub(started.elapsed()) {
                    std::thread::sleep(delay);
                }
            }
            Ok(())
        })();
        let _ = session.Close();
        let _ = pool.Close();
        windows::Win32::System::WinRT::RoUninitialize();
        result
    }
}

unsafe fn client(hwnd: HWND, width: i32, height: i32) -> Result<(i32, i32, i32, i32), String> {
    unsafe {
        let mut bounds = RECT::default();
        if DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            (&mut bounds as *mut RECT).cast(),
            size_of::<RECT>() as u32,
        )
        .is_err()
            || bounds.right - bounds.left != width
            || bounds.bottom - bounds.top != height
        {
            GetWindowRect(hwnd, &mut bounds).map_err(error)?;
        }
        let mut area = RECT::default();
        GetClientRect(hwnd, &mut area).map_err(error)?;
        let mut origin = POINT::default();
        if !ClientToScreen(hwnd, &mut origin).as_bool() {
            return Err("Window geometry unavailable".into());
        }
        let x = (origin.x - bounds.left).max(0);
        let y = (origin.y - bounds.top).max(0);
        let right = (origin.x - bounds.left + area.right).min(width);
        let bottom = (origin.y - bounds.top + area.bottom).min(height);
        if right <= x || bottom <= y {
            return Err("Window geometry changed during capture".into());
        }
        Ok((x, y, right - x, bottom - y))
    }
}
