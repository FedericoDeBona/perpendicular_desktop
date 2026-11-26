use super::{icons, wire::Outbox};
use serde_json::{Value, json};
use std::{
    cell::Cell,
    sync::{Arc, atomic::Ordering, mpsc},
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::{CloseHandle, HANDLE, HMODULE, HWND, POINT, WAIT_FAILED},
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL_11_0},
            Direct3D11::{D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION, D3D11CreateDevice},
            Dxgi::{DXGI_OUTDUPL_FRAME_INFO, IDXGIDevice, IDXGIOutput1},
            Gdi::*,
        },
        System::{
            Com::{COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize},
            StationsAndDesktops::{
                CloseDesktop, DESKTOP_READOBJECTS, GetUserObjectInformationW, OpenInputDesktop,
                UOI_NAME,
            },
            Threading::{CreateEventW, SetEvent},
        },
        UI::{
            Accessibility::{HWINEVENTHOOK, SetWinEventHook, UnhookWinEvent},
            Magnification::*,
            WindowsAndMessaging::*,
        },
    },
    core::{Interface, PCWSTR},
};

const LEASE: Duration = Duration::from_millis(2500);
const SAMPLE: Duration = Duration::from_millis(25);

// The unnamed auto-reset event stays alive until both threads have stopped
// using it. It wakes the same wait that delivers the WinEvent callbacks.
struct WakeEvent(usize);

impl WakeEvent {
    fn new() -> Option<Self> {
        unsafe {
            CreateEventW(None, false, false, PCWSTR::null())
                .ok()
                .map(|event| Self(event.0 as usize))
        }
    }
    fn handle(&self) -> HANDLE {
        HANDLE(self.0 as _)
    }
    fn signal(&self) {
        unsafe {
            let _ = SetEvent(self.handle());
        }
    }
}

impl Drop for WakeEvent {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.handle());
        }
    }
}

type Update = (String, bool, Instant);

pub struct Monitor {
    updates: Option<mpsc::Sender<Update>>,
    wake: Option<Arc<WakeEvent>>,
}

impl Monitor {
    pub fn start(outbox: Arc<Outbox>) -> Self {
        let (updates, receiver) = mpsc::channel();
        let wake = WakeEvent::new().map(Arc::new);
        let waiter = wake.clone();
        std::thread::spawn(move || watch(receiver, outbox, waiter.as_deref()));
        Self {
            updates: Some(updates),
            wake,
        }
    }

    pub fn update(&self, id: &str, active: bool) {
        if let Some(updates) = &self.updates {
            let _ = updates.send((id.to_owned(), active, Instant::now() + LEASE));
        }
        if let Some(wake) = &self.wake {
            wake.signal();
        }
    }
}

impl Drop for Monitor {
    fn drop(&mut self) {
        self.updates.take();
        if let Some(wake) = &self.wake {
            wake.signal();
        }
    }
}

thread_local! {
    static CURSOR_CHANGED: Cell<bool> = const { Cell::new(false) };
}

unsafe extern "system" fn cursor_event(
    _: HWINEVENTHOOK,
    _: u32,
    _: HWND,
    object: i32,
    child: i32,
    _: u32,
    _: u32,
) {
    if object == OBJID_CURSOR.0 && child == 0 {
        CURSOR_CHANGED.set(true);
    }
}

struct HiddenCursor {
    hooks: [HWINEVENTHOOK; 2],
    compositor_attempts: u8,
}

impl HiddenCursor {
    fn acquire() -> Option<Self> {
        unsafe {
            if !MagInitialize().as_bool() {
                return None;
            }
            if !MagShowSystemCursor(false).as_bool() {
                let _ = MagUninitialize();
                return None;
            }
            let hooks = [EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_SHOW].map(|event| {
                SetWinEventHook(
                    event,
                    event,
                    None,
                    Some(cursor_event),
                    0,
                    0,
                    WINEVENT_SKIPOWNPROCESS,
                )
            });
            Some(Self {
                hooks,
                compositor_attempts: 2,
            })
        }
    }

    fn prepare_compositor(&mut self) {
        if self.compositor_attempts == 0 {
            return;
        }
        self.compositor_attempts -= 1;
        if refresh_pointer_compositor().is_some() {
            self.compositor_attempts = 0;
        }
    }
}

// VioGpu3D can leave the software pointer in the primary scanout after
// MagShowSystemCursor(false). One DXGI duplication frame makes Windows update
// its pointer composition. Release it immediately without mapping any pixels.
fn refresh_pointer_compositor() -> Option<()> {
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok().ok()?;
        let result = (|| {
            let mut device = None;
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&[D3D_FEATURE_LEVEL_11_0]),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                None,
            ).ok()?;
            let device = device?;
            let dxgi: IDXGIDevice = device.cast().ok()?;
            let output = dxgi.GetAdapter().ok()?.EnumOutputs(0).ok()?;
            if output.GetDesc().ok()?.Monitor != MonitorFromPoint(POINT::default(), MONITOR_DEFAULTTOPRIMARY) {
                return None;
            }
            let output: IDXGIOutput1 = output.cast().ok()?;
            let duplication = output.DuplicateOutput(&device).ok()?;
            let mut frame_info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut resource = None;
            duplication.AcquireNextFrame(500, &mut frame_info, &mut resource).ok()?;
            drop(resource);
            duplication.ReleaseFrame().ok()
        })();
        CoUninitialize();
        result
    }
}

impl Drop for HiddenCursor {
    fn drop(&mut self) {
        unsafe {
            for hook in self.hooks {
                if !hook.is_invalid() {
                    let _ = UnhookWinEvent(hook);
                }
            }
            let _ = MagShowSystemCursor(true);
            let _ = MagUninitialize();
        }
    }
}

fn default_input_desktop() -> bool {
    unsafe {
        let Ok(desktop) = OpenInputDesktop(Default::default(), false, DESKTOP_READOBJECTS) else {
            return false;
        };
        let mut name = [0u16; 32];
        let result = GetUserObjectInformationW(
            HANDLE(desktop.0),
            UOI_NAME,
            Some(name.as_mut_ptr().cast()),
            size_of_val(&name) as u32,
            None,
        );
        let _ = CloseDesktop(desktop);
        result.is_ok()
            && name
                .into_iter()
                .take_while(|unit| *unit != 0)
                .eq("Default".encode_utf16())
    }
}

fn next_update(
    receiver: &mpsc::Receiver<Update>,
    wake: Option<&WakeEvent>,
    active: bool,
) -> Result<Update, mpsc::RecvTimeoutError> {
    if !active {
        return receiver
            .recv()
            .map_err(|_| mpsc::RecvTimeoutError::Disconnected);
    }
    if let Some(wake) = wake {
        let result = unsafe {
            MsgWaitForMultipleObjectsEx(
                Some(&[wake.handle()]),
                SAMPLE.as_millis() as u32,
                QS_ALLINPUT,
                MWMO_INPUTAVAILABLE,
            )
        };
        if result != WAIT_FAILED {
            return receiver.try_recv().map_err(|error| match error {
                mpsc::TryRecvError::Empty => mpsc::RecvTimeoutError::Timeout,
                mpsc::TryRecvError::Disconnected => mpsc::RecvTimeoutError::Disconnected,
            });
        }
    }
    receiver.recv_timeout(SAMPLE)
}

fn dispatch_cursor_events() -> bool {
    unsafe {
        let mut message = MSG::default();
        while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
            let _ = DispatchMessageW(&message);
        }
    }
    CURSOR_CHANGED.replace(false)
}

fn watch(receiver: mpsc::Receiver<Update>, outbox: Arc<Outbox>, wake: Option<&WakeEvent>) {
    let mut lease: Option<(String, Instant)> = None;
    let mut hidden = None;
    let mut previous = None;
    while outbox.connected.load(Ordering::Acquire) {
        let update = next_update(&receiver, wake, lease.is_some());
        let mut renewed = false;
        match update {
            Ok((id, true, deadline)) if deadline > Instant::now() => {
                if lease.as_ref().is_none_or(|(old, _)| *old != id) {
                    previous = None;
                }
                lease = Some((id, deadline));
                renewed = true;
            }
            Ok((id, false, _)) if lease.as_ref().is_some_and(|(old, _)| *old == id) => {
                hidden.take();
                lease = None;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            _ => {}
        }
        let Some((id, deadline)) = &lease else {
            continue;
        };
        if Instant::now() >= *deadline || !outbox.connected.load(Ordering::Acquire) {
            hidden.take();
            lease = None;
            continue;
        }
        // A secure input desktop must retain Windows' own pointer. Recheck on
        // each renewal, and release immediately if cursor sampling fails.
        if renewed {
            if !default_input_desktop() {
                hidden.take();
            } else if hidden.is_none() {
                hidden = HiddenCursor::acquire();
                previous = None;
            }
        }
        let cursor_event = dispatch_cursor_events();
        let mut info = CURSORINFO {
            cbSize: size_of::<CURSORINFO>() as u32,
            ..Default::default()
        };
        if hidden.is_some() && unsafe { GetCursorInfo(&mut info) }.is_err() {
            hidden.take();
            previous = None;
            outbox.control(json!({"type":"desktop_cursor","lease":id,"hidden":false}));
            continue;
        }
        if hidden.is_none() {
            if renewed {
                outbox.control(json!({"type":"desktop_cursor","lease":id,"hidden":false}));
            }
            continue;
        }
        let key = (info.flags.0, info.hCursor.0 as usize);
        // Windows can redraw the cursor after hover changes. Reassert before
        // encoding the new shape, with sampling as a fallback for missed events.
        if (cursor_event || previous != Some(key) || renewed)
            && !unsafe { MagShowSystemCursor(false) }.as_bool()
        {
            hidden.take();
            previous = None;
            outbox.control(json!({"type":"desktop_cursor","lease":id,"hidden":false}));
            continue;
        }
        if previous != Some(key) {
            previous = Some(key);
            outbox.control(
                json!({"type":"desktop_cursor","lease":id,"hidden":true,"cursor":shape(info)}),
            );
        } else if renewed {
            outbox.control(json!({"type":"desktop_cursor","lease":id,"hidden":true}));
        }
        // Send the current shape before the bounded DXGI wait. Try again on
        // the next renewal if the display was still starting or resizing.
        if renewed {
            if let Some(hidden) = hidden.as_mut() {
                hidden.prepare_compositor();
            }
        }
    }
}

fn shape(info: CURSORINFO) -> Value {
    if info.flags.0 & CURSOR_SHOWING.0 == 0 || info.hCursor.is_invalid() {
        return json!({"name":"hidden"});
    }
    let system = [
        (IDC_ARROW, "arrow"),
        (IDC_HAND, "hand"),
        (IDC_IBEAM, "text"),
        (IDC_CROSS, "crosshair"),
        (IDC_NO, "forbidden"),
        (IDC_SIZEALL, "move"),
        (IDC_SIZEWE, "resizeHorizontal"),
        (IDC_SIZENS, "resizeVertical"),
        (IDC_SIZENWSE, "resizeNWSE"),
        (IDC_SIZENESW, "resizeNESW"),
    ];
    for (resource, name) in system {
        if unsafe { LoadCursorW(None, resource) }.ok() == Some(info.hCursor) {
            return json!({"name":name});
        }
    }
    unsafe { bitmap(info.hCursor) }.unwrap_or_else(|| json!({"name":"arrow"}))
}

struct Bitmap(HBITMAP);
impl Drop for Bitmap {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = DeleteObject(HGDIOBJ(self.0.0));
            }
        }
    }
}

unsafe fn bitmap(cursor: HCURSOR) -> Option<Value> {
    unsafe {
        let icon = HICON(cursor.0);
        let mut details = ICONINFO::default();
        GetIconInfo(icon, &mut details).ok()?;
        let mask = Bitmap(details.hbmMask);
        let color = Bitmap(details.hbmColor);
        let monochrome = color.0.is_invalid();
        let source = if monochrome { &mask } else { &color };
        let mut geometry = BITMAP::default();
        if GetObjectW(
            HGDIOBJ(source.0.0),
            size_of::<BITMAP>() as i32,
            Some((&mut geometry as *mut BITMAP).cast()),
        ) == 0
        {
            return None;
        }
        let width = geometry.bmWidth;
        let height = if monochrome {
            geometry.bmHeight / 2
        } else {
            geometry.bmHeight
        };
        if !(1..=128).contains(&width)
            || !(1..=128).contains(&height)
            || details.xHotspot >= width as u32
            || details.yHotspot >= height as u32
        {
            return None;
        }
        let mut format = BITMAPINFO::default();
        format.bmiHeader = BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let mut address = std::ptr::null_mut();
        let target =
            Bitmap(CreateDIBSection(None, &format, DIB_RGB_COLORS, &mut address, None, 0).ok()?);
        if address.is_null() {
            return None;
        }
        let dc = CreateCompatibleDC(None);
        if dc.is_invalid() {
            return None;
        }
        let saved = SelectObject(dc, HGDIOBJ(target.0.0));
        if saved.is_invalid() {
            let _ = DeleteDC(dc);
            return None;
        }
        let pixels =
            std::slice::from_raw_parts_mut(address.cast::<u8>(), (width * height * 4) as usize);
        // Rendering over black and white also recovers the alpha of legacy
        // mask cursors. Destination-inverting pixels are approximated as white.
        pixels.fill(0);
        let black = DrawIconEx(dc, 0, 0, icon, width, height, 0, None, DI_NORMAL);
        let _ = GdiFlush();
        let mut image = pixels.to_vec();
        pixels.fill(255);
        let white = DrawIconEx(dc, 0, 0, icon, width, height, 0, None, DI_NORMAL);
        let _ = GdiFlush();
        let _ = SelectObject(dc, saved);
        let _ = DeleteDC(dc);
        black.ok()?;
        white.ok()?;
        for (black, white) in image.chunks_exact_mut(4).zip(pixels.chunks_exact(4)) {
            let difference = white[..3]
                .iter()
                .zip(&black[..3])
                .map(|(w, b)| w.saturating_sub(*b))
                .max()?;
            black[3] = 255 - difference;
            let alpha = black[3];
            for channel in &mut black[..3] {
                *channel = (*channel).min(alpha);
            }
        }
        Some(json!({"name":"image","width":width,"height":height,
            "x":details.xHotspot,"y":details.yHotspot,"bgra":icons::base64(&image)}))
    }
}
