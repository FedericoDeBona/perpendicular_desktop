use super::{catalogue, error, identity, wire::Outbox};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use windows::{
    Foundation::TypedEventHandler,
    Graphics::{
        Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession, GraphicsCaptureDirtyRegionMode},
        DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
    },
    Win32::{
        Foundation::{HMODULE, HWND, POINT, RECT, SetLastError, GetLastError, WIN32_ERROR},
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE, D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP, D3D_FEATURE_LEVEL_11_0},
            Direct3D11::*,
            Dwm::{DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute, DwmIsCompositionEnabled},
            Dxgi::{Common::DXGI_FORMAT_B8G8R8A8_UNORM, IDXGIDevice},
            Gdi::{ClientToScreen, RedrawWindow, RDW_INVALIDATE, RDW_ERASE, RDW_ALLCHILDREN, RDW_FRAME},
        },
        System::WinRT::{
            Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess},
            Graphics::Capture::IGraphicsCaptureItemInterop,
            RO_INIT_MULTITHREADED, RoInitialize,
        },
        UI::{
            Input::KeyboardAndMouse::IsWindowEnabled,
            HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext, GetDpiForWindow},
            WindowsAndMessaging::{GetClientRect, GetWindowRect, IsIconic, IsWindowVisible,
                GetAncestor, GetWindow, GetWindowDisplayAffinity, GetWindowLongPtrW, SetWindowLongPtrW,
                GetWindowThreadProcessId, GetForegroundWindow, GetLastActivePopup,
                GA_ROOT, GW_OWNER, GWL_EXSTYLE, GWL_STYLE, WS_CAPTION, WS_CHILD,
                WS_EX_APPWINDOW, WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE},
        },
    },
    core::{Interface, factory},
};

#[repr(u8)]
pub enum Phase {
    Starting, Validating, Waiting, Reading, Mapping, Publishing,
    Recreating, Closing, Ended, Error, Invalidated, Backpressure,
}

// Per-run observations; callbacks never lock the capture or control thread.
#[derive(Default)]
pub struct Progress {
    starts: AtomicU64,
    callbacks: AtomicU64,
    acquired: AtomicU64,
    recreates: AtomicU64,
    // Observation only: an empty pool returns null; code 0 is not a GPU fault.
    dequeue_hresult: AtomicU32,
    enabled_at_start: AtomicBool,
    deferred_for_modal: AtomicBool,
}
impl Progress {
    pub fn snapshot(&self)->Value {
        json!({"sessionStarts":self.starts.load(Ordering::Relaxed),
            "callbacks":self.callbacks.load(Ordering::Relaxed),
            "acquired":self.acquired.load(Ordering::Relaxed),
            "poolRecreates":self.recreates.load(Ordering::Relaxed),
            "lastDequeueFailureHRESULT":format!("{:#010x}",self.dequeue_hresult.load(Ordering::Relaxed)),
            "enabledAtStart":self.enabled_at_start.load(Ordering::Relaxed),
            "deferredForModal":self.deferred_for_modal.load(Ordering::Relaxed)})
    }
}

pub struct Target {
    pub id: String,
    pub hwnd: usize,
    pub pid: u32,
    pub creation: u64,
    pub sid: String,
    pub session: u32,
    pub full_frame: bool,
    pub hosted: Option<catalogue::HostedContent>,
    // Shared only for creation on this HWND, including overlapping reconnects.
    // Frame progress and geometry below remain private to each capture run.
    pub item_creation: Arc<Mutex<()>>,
    pub capture_phase: AtomicU8,
    pub capture_frames: AtomicU64,
    pub progress: Arc<Progress>,
    pub capture_device: Mutex<Option<Value>>,
    pub readback_device_lost: AtomicBool,
    pub refresh_requested: AtomicBool,
    // Generation, dimensions, and image origin relative to the Windows client origin.
    pub geometry: Mutex<(u64, i32, i32, i32, i32)>,
}
impl Target {
    /// The HWND identity survives a reconnect; capture progress and geometry do
    /// not. A retiring thread keeps its own Target and cannot overwrite this run.
    pub fn fresh_capture(&self) -> Self {
        Self {
            id: self.id.clone(), hwnd: self.hwnd, pid: self.pid, creation: self.creation,
            sid: self.sid.clone(), session: self.session, full_frame: self.full_frame,
            hosted: self.hosted.clone(),
            item_creation:self.item_creation.clone(),
            capture_phase: AtomicU8::new(Phase::Starting as u8),
            capture_frames: AtomicU64::new(0),
            progress: Arc::new(Progress::default()),
            capture_device: Mutex::new(None),
            readback_device_lost: AtomicBool::new(false),
            refresh_requested: AtomicBool::new(false),
            geometry: Mutex::new((self.geometry.lock().unwrap().0.saturating_add(1), 0, 0, 0, 0)),
        }
    }
    pub(super) fn set_phase(&self, phase: Phase) {
        self.capture_phase.store(phase as u8, Ordering::Release);
    }
    pub fn capture_phase_name(&self) -> &'static str {
        match self.capture_phase.load(Ordering::Acquire) {
            0 => "starting", 1 => "validating", 2 => "waiting", 3 => "reading",
            4 => "mapping", 5 => "publishing", 6 => "recreating", 7 => "closing",
            8 => "ended", 9 => "error", 10 => "invalidated", 11 => "backpressure", _ => "unknown",
        }
    }
    pub fn valid(&self) -> bool {
        identity::owner(HWND(self.hwnd as *mut _), &self.sid, self.session)
            == Some((self.pid, self.creation))
            && match &self.hosted {
                Some(content) => content.valid(self.hwnd, &self.sid, self.session),
                None => catalogue::window_class(self.hwnd) != "ApplicationFrameWindow"
                    && catalogue::host_frame(self.hwnd, &self.sid, self.session).is_none(),
            }
    }
}

pub fn spawn(target: Arc<Target>, outbox: Arc<Outbox>) -> Arc<AtomicBool> {
    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    target.set_phase(Phase::Starting);
    std::thread::spawn(move || {
        unsafe {SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);}
        let class = catalogue::window_class(target.hwnd);
        let tooltip = class.eq_ignore_ascii_case("tooltips_class32") || class == "MicrosoftWindowsTooltip";
        let result = if class == "#32768" && !super::window_control::native_app_input_allowed(HWND(target.hwnd as _)) {
            Err("Solo GPU: il menu classico non dispone ancora di una superficie GPU esportabile.".into())
        } else {
            loop {
                match unsafe {run(&target,&outbox,&flag,D3D_DRIVER_TYPE_HARDWARE,None)} {
                    Ok(true) if !flag.load(Ordering::Acquire) && outbox.connected.load(Ordering::Acquire) && target.valid() => continue,
                    Ok(_) => break Ok(()),
                    Err(message) => break Err(message),
                }
            }
        };
        if let Err(message) = result {
            let mut description = target.capture_device.lock().unwrap();
            let description = description.get_or_insert_with(|| json!({}));
            description["failurePhase"] = json!(target.capture_phase_name());
            description["failure"] = json!(message);
            target.set_phase(Phase::Error);
            if !flag.load(Ordering::Acquire) && target.valid() {
                outbox.control(json!({"type":"window_error","window":target.id,"message":message,
                    "role":if tooltip {"tooltip"} else {"window"}}));
            }
        } else if target.capture_phase.load(Ordering::Acquire) != Phase::Invalidated as u8 {
            target.set_phase(Phase::Ended);
        }
        outbox.retire(&target.id);
        flag.store(true, Ordering::Release);
    });
    stop
}

struct DialogAdmission<'a> { target: &'a Target, active: bool }
impl DialogAdmission<'_> {
    unsafe fn restore(&mut self) -> Result<(), String> {
        if !self.active { return Ok(()); }
        if !self.target.valid() { self.active=false;return Ok(()); }
        let hwnd=HWND(self.target.hwnd as *mut _);
        unsafe {
            let current=GetWindowLongPtrW(hwnd,GWL_EXSTYLE);
            let bit=WS_EX_APPWINDOW.0 as isize;
            // Clear only our bit; preserve other attributes changed by the app.
            if current & bit != 0 {
                SetLastError(WIN32_ERROR(0));
                let previous=SetWindowLongPtrW(hwnd,GWL_EXSTYLE,current & !bit);
                if previous==0 && GetLastError().0!=0 { return Err("Could not restore dialog capture admission".into()); }
            }
            if GetWindowLongPtrW(hwnd,GWL_EXSTYLE) & bit != 0 { return Err("Dialog capture admission was not restored".into()); }
        }
        self.active=false;Ok(())
    }
}
impl Drop for DialogAdmission<'_> {
    fn drop(&mut self) { let _=unsafe {self.restore()}; }
}

// Read only, and only after item rejection: no titles, pixels, extra capture
// device or retry. DWM composition enabled does not imply this HWND is drawn.
unsafe fn item_window_state(hwnd:HWND)->Value {
    unsafe {
        let mut pid=0;let thread=GetWindowThreadProcessId(hwnd,Some(&mut pid));
        let mut affinity=0;let affinity=GetWindowDisplayAffinity(hwnd,&mut affinity).ok().map(|_|affinity);
        let mut cloaked=0u32;
        let cloaked=DwmGetWindowAttribute(hwnd,DWMWA_CLOAKED,(&mut cloaked as *mut u32).cast(),size_of::<u32>() as u32)
            .ok().map(|_|cloaked);
        let mut rect=RECT::default();let rect=GetWindowRect(hwnd,&mut rect).ok().map(|_|[rect.left,rect.top,rect.right,rect.bottom]);
        let mut client=RECT::default();let client=GetClientRect(hwnd,&mut client).ok().map(|_|[client.left,client.top,client.right,client.bottom]);
        json!({"hwnd":hwnd.0 as usize,"pid":pid,"thread":thread,"class":catalogue::window_class(hwnd.0 as usize),
            "root":GetAncestor(hwnd,GA_ROOT).0 as usize,"owner":GetWindow(hwnd,GW_OWNER).unwrap_or_default().0 as usize,
            "style":format!("{:#010x}",GetWindowLongPtrW(hwnd,GWL_STYLE) as u32),
            "exStyle":format!("{:#010x}",GetWindowLongPtrW(hwnd,GWL_EXSTYLE) as u32),
            "visible":IsWindowVisible(hwnd).as_bool(),"enabled":IsWindowEnabled(hwnd).as_bool(),
            "cloaked":cloaked,"affinity":affinity,"dpi":GetDpiForWindow(hwnd),"rect":rect,"clientRect":client})
    }
}
fn item_admission(target:&Target,report:&Value) {
    let mut description=target.capture_device.lock().unwrap();
    description.get_or_insert_with(||json!({}))["itemAdmission"]=report.clone();
}

unsafe fn create_item(target:&Target,interop:&IGraphicsCaptureItemInterop)->Result<GraphicsCaptureItem,String> {
    let _creation=target.item_creation.lock().map_err(|_| "Capture item creation interrupted")?;
    let started=Instant::now();
    let mut report:Option<Value>=None;
    let result=(|| unsafe {
        if !target.valid() {return Err("Window retired before capture".into());}
        let hwnd=HWND(target.hwnd as *mut _);
        if let Some(description)=target.capture_device.lock().unwrap().as_mut() {
            if let Some(object)=description.as_object_mut() {object.remove("itemAdmission");}
        }
        let initial=match interop.CreateForWindow::<GraphicsCaptureItem>(hwnd) {
            Ok(item)=>return Ok(item),
            Err(e)=>e,
        };
        report=Some(json!({"initialHRESULT":format!("{:#010x}",initial.code().0 as u32),
            "initialFailureMilliseconds":started.elapsed().as_secs_f64()*1000.0,
            "expectedPid":target.pid,"expectedCreation":target.creation.to_string(),"session":target.session,
            "admissionAttempted":false}));
        if initial.code()==windows::core::HRESULT(0x80070057u32 as i32) && target.full_frame {
            let restored=super::cloak::restore_capture_eligibility(target)?;
            if let Some(report)=report.as_mut() {report["taskbarRestoredForCapture"]=json!(restored);}
            if restored {
                if !target.valid(){return Err("Window retired during capture admission".into());}
                return interop.CreateForWindow::<GraphicsCaptureItem>(hwnd)
                    .map_err(|e|format!("CreateForWindow after taskbar restoration: {e}"));
            }
        }
        // This is a single, cause-specific admission for authenticated classic
        // dialogs. Do not alter tooltips, children or capture-excluded windows.
        if initial.code()!=windows::core::HRESULT(0x80070057u32 as i32)
            || target.full_frame || catalogue::window_class(target.hwnd)!="#32770"
            || !IsWindowVisible(hwnd).as_bool() || GetAncestor(hwnd,GA_ROOT)!=hwnd {
            return Err(format!("CreateForWindow: {initial}"));
        }
        let owner=GetWindow(hwnd,GW_OWNER).map_err(error)?;
        let style=GetWindowLongPtrW(hwnd,GWL_STYLE) as u32;
        let original=GetWindowLongPtrW(hwnd,GWL_EXSTYLE);
        let bit=WS_EX_APPWINDOW.0 as isize;
        let mut affinity=0u32;let mut owner_affinity=0u32;
        if identity::owner(owner,&target.sid,target.session)!=Some((target.pid,target.creation))
            || style & WS_CHILD.0 != 0 || style & WS_CAPTION.0 != WS_CAPTION.0
            || original & (WS_EX_APPWINDOW.0 | WS_EX_TOOLWINDOW.0 | WS_EX_NOACTIVATE.0) as isize != 0
            || GetWindowDisplayAffinity(hwnd,&mut affinity).is_err() || affinity!=0
            || GetWindowDisplayAffinity(owner,&mut owner_affinity).is_err() || owner_affinity!=0
            || !target.valid() {
            return Err(format!("CreateForWindow: {initial}"));
        }
        if let Some(report)=report.as_mut() {
            report["before"]=json!({"owner":owner.0 as usize,"style":format!("{style:#010x}"),
                "exStyle":format!("{:#010x}",original as u32),"affinity":affinity,"ownerAffinity":owner_affinity});
        }
        SetLastError(WIN32_ERROR(0));
        let previous=SetWindowLongPtrW(hwnd,GWL_EXSTYLE,original | bit);
        if previous==0 && GetLastError().0!=0 {return Err(format!("Dialog capture admission: {}",windows::core::Error::from_thread()));}
        let mut admission=DialogAdmission {target,active:true};
        if !target.valid() || GetWindowLongPtrW(hwnd,GWL_EXSTYLE) & bit == 0 {
            return Err("Dialog retired before capture admission".into());
        }
        if let Some(report)=report.as_mut() {
            report["admissionAttempted"]=json!(true);report["appWindowConfirmed"]=json!(true);
            report["admissionMilliseconds"]=json!(started.elapsed().as_secs_f64()*1000.0);
        }
        let item=interop.CreateForWindow::<GraphicsCaptureItem>(hwnd);
        if let Some(report)=report.as_mut() {
            report["admissionHRESULT"]=json!(format!("{:#010x}",item.as_ref().err().map_or(0,|e|e.code().0 as u32)));
        }
        // Restore before starting a capture session, even when creation fails.
        admission.restore()?;
        if !target.valid() {return Err("Dialog retired during capture admission".into());}
        item.map_err(|e|format!("CreateForWindow after dialog admission: {e}"))
    })();
    if let Some(mut report)=report {
        // Do not insert DWM/window queries into the transient style interval.
        // Snapshot only after success/cleanup, retaining the original guard data.
        unsafe {
            let hwnd=HWND(target.hwnd as *mut _);let owner=GetWindow(hwnd,GW_OWNER).unwrap_or_default();
            report["afterCleanup"]=item_window_state(hwnd);
            report["ownerWindow"]=if owner.0.is_null() {Value::Null}else{item_window_state(owner)};
            report["identityValid"]=json!(target.valid());
            report["foreground"]=json!(GetForegroundWindow().0 as usize);
            report["compositionEnabled"]=json!(DwmIsCompositionEnabled().ok().map(|value|value.as_bool()));
        }
        report["failure"]=json!(result.as_ref().err());
        item_admission(target,&report);
    }
    result
}

unsafe fn run(target: &Target, outbox: &Outbox, stop: &AtomicBool, driver:D3D_DRIVER_TYPE, hardware_failure:Option<&str>) -> Result<bool, String> {
    unsafe {
        let deadline=Instant::now();
        while outbox.row_alignment()!=256 || !outbox.gpu_enabled.load(Ordering::Acquire) {
            if stop.load(Ordering::Acquire) || !outbox.connected.load(Ordering::Acquire) {return Ok(false);}
            if deadline.elapsed()>Duration::from_secs(5) {return Err("Solo GPU: canale immagini non disponibile. Nessun fallback TCP.".into());}
            std::thread::sleep(Duration::from_millis(5));
        }
        RoInitialize(RO_INIT_MULTITHREADED).map_err(error)?;
        struct Apartment;
        impl Drop for Apartment {
            fn drop(&mut self) { unsafe { windows::Win32::System::WinRT::RoUninitialize(); } }
        }
        let _apartment = Apartment;
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        if !GraphicsCaptureSession::IsSupported().map_err(error)? {
            return Err("Window capture is unsupported".into());
        }
        // HWND admission is independent of Direct3D. A rejected tooltip must
        // not allocate a GPU device/context just to discover it has no item.
        let interop: IGraphicsCaptureItemInterop =
            factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(error)?;
        while IsIconic(HWND(target.hwnd as *mut _)).as_bool() {
            if stop.load(Ordering::Acquire)
                || !outbox.connected.load(Ordering::Acquire)
                || !target.valid()
            {
                return Ok(false);
            }
            std::thread::sleep(Duration::from_millis(75));
        }
        // A new WGC session on a main disabled by an existing classic modal
        // dialog can start successfully yet never receive FrameArrived, even
        // after that dialog closes. Wait for that authenticated modal to end
        // before allocating the device/pool. Do not enable or close windows,
        // restart a running capture, or defer arbitrary disabled windows.
        let hwnd=HWND(target.hwnd as *mut _);
        while target.full_frame && !IsWindowEnabled(hwnd).as_bool() {
            if stop.load(Ordering::Acquire) || !outbox.connected.load(Ordering::Acquire) || !target.valid() {
                return Ok(false);
            }
            let popup=GetLastActivePopup(hwnd);
            if popup==hwnd || popup.0.is_null() || !IsWindowVisible(popup).as_bool()
                || GetWindow(popup,GW_OWNER).unwrap_or_default()!=hwnd
                || catalogue::window_class(popup.0 as usize)!="#32770"
                || identity::owner(popup,&target.sid,target.session)!=Some((target.pid,target.creation)) {
                break;
            }
            target.progress.deferred_for_modal.store(true,Ordering::Relaxed);
            target.set_phase(Phase::Waiting);
            std::thread::sleep(Duration::from_millis(75));
        }
        target.set_phase(Phase::Starting);
        let item = create_item(target, &interop)?;
        if stop.load(Ordering::Acquire) || !outbox.connected.load(Ordering::Acquire) || !target.valid() {
            return Ok(false);
        }
        let mut device = None;
        let mut context = None;
        D3D11CreateDevice(
            None,
            driver,
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
        // WGC's free-threaded pool also uses this device. The immediate
        // context is not thread-safe by default; protect it before publishing
        // the WinRT device to the capture pool, including during teardown.
        let multithread:ID3D11Multithread=context.cast().map_err(error)?;
        let _ = multithread.SetMultithreadProtected(true);
        if !multithread.GetMultithreadProtected().as_bool() {
            return Err("The capture context did not enable multithread protection".into());
        }
        let mut description = super::display::device_description(&device).map_err(error)?;
        description["multithreadProtected"]=json!(true);
        if driver==D3D_DRIVER_TYPE_HARDWARE && description["hardwareDevice"] != true {
            return Err("The capture device is a software adapter, not the Windows GPU".into());
        }
        let software_recovery=driver==D3D_DRIVER_TYPE_WARP;
        description["softwareRecovery"]=json!(software_recovery);
        if let Some(failure)=hardware_failure {description["hardwareFailure"]=json!(failure);}
        if let Some(admission)=target.capture_device.lock().unwrap().as_ref().and_then(|value|value.get("itemAdmission")).cloned() {
            description["itemAdmission"]=admission;
        }
        *target.capture_device.lock().unwrap() = Some(description);
        let dxgi: IDXGIDevice = device.cast().map_err(error)?;
        let runtime: IDirect3DDevice = CreateDirect3D11DeviceFromDXGIDevice(&dxgi)
            .map_err(|e| gpu_error(&device, "CreateDirect3D11DeviceFromDXGIDevice", e))?
            .cast()
            .map_err(error)?;
        let mut size = item.Size().map_err(error)?;
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            &runtime,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2,
            size,
        )
        .map_err(|e| gpu_error(&device, "CreateFreeThreaded", e))?;
        let session = pool.CreateCaptureSession(&item).map_err(|e| gpu_error(&device, "CreateCaptureSession", e))?;
        let _ = session.SetIsCursorCaptureEnabled(false);
        // Capture each surface independently: popups may extend beyond the document,
        // and real dialogs must not also be baked into the document's pixels.
        let _ = session.SetIncludeSecondaryWindows(false);
        // This transport replaces complete images and may drop intermediate
        // frames; it must never opt into rendering only the dirty rectangles.
        // Older Windows versions without this property retain the original API.
        let original_dirty_mode=session.DirtyRegionMode().ok();
        if original_dirty_mode.is_some_and(|mode| mode!=GraphicsCaptureDirtyRegionMode::ReportOnly) {
            session.SetDirtyRegionMode(GraphicsCaptureDirtyRegionMode::ReportOnly).map_err(error)?;
        }
        let dirty_mode=session.DirtyRegionMode().ok();
        if dirty_mode.is_some_and(|mode| mode!=GraphicsCaptureDirtyRegionMode::ReportOnly) {
            return Err("The capture session did not enable complete frames".into());
        }
        if let Some(description)=target.capture_device.lock().unwrap().as_mut() {
            description["wgcSession"]=json!({"originalDirtyRegionMode":original_dirty_mode.map(|mode|mode.0),
                "dirtyRegionMode":dirty_mode.map(|mode|mode.0),
                "includeSecondaryWindows":session.IncludeSecondaryWindows().ok()});
            if std::env::var("PERP_CAPTURE_PIXEL_HASH").as_deref()==Ok("1") {
                description["diagnosticDriverTrial"]=json!({
                    "scheduledStartRequested":std::env::var("PERP_DRIVER_SCHEDULE_TRIAL").as_deref()==Ok("1"),
                    "multiRingRequested":std::env::var("NPT_PERF").as_deref()==Ok("multi_ring")});
            }
        }
        let (arrived, ready) = mpsc::sync_channel(1);
        let progress=target.progress.clone();
        let registration = pool.FrameArrived(&TypedEventHandler::new(move |_,_| {
            progress.callbacks.fetch_add(1,Ordering::Relaxed);
            let _ = arrived.try_send(()); Ok(())
        })).map_err(error)?;
        target.progress.enabled_at_start.store(IsWindowEnabled(HWND(target.hwnd as *mut _)).as_bool(),Ordering::Relaxed);
        session.StartCapture().map_err(|e| gpu_error(&device, "StartCapture", e))?;
        target.progress.starts.fetch_add(1,Ordering::Relaxed);
        // A static app on a reserved display may have finished painting before
        // WGC subscribed. Request one ordinary repaint after StartCapture,
        // without moving/focusing it or recreating an otherwise healthy pool.
        if target.valid() {
            let requested=RedrawWindow(Some(hwnd),None,None,RDW_INVALIDATE|RDW_ALLCHILDREN|RDW_FRAME).as_bool();
            if let Some(description)=target.capture_device.lock().unwrap().as_mut() {
                description["initialRedrawRequested"]=json!(requested);
            }
        }
        let mut restart_session=false;
        let result = (|| -> Result<(), String> {
            let mut native_gpu:Option<super::gpu::Gpu>=None;
            let mut sequence = target.capture_frames.load(Ordering::Acquire);
            let mut generation = target.geometry.lock().unwrap().0.max(1);
            let mut previous = [0; 6];
            while !stop.load(Ordering::Acquire) && outbox.connected.load(Ordering::Acquire) {
                target.set_phase(Phase::Validating);
                if !target.valid() {
                    target.set_phase(Phase::Invalidated);
                    break;
                }
                if IsIconic(HWND(target.hwnd as *mut _)).as_bool() {
                    target.set_phase(Phase::Waiting);
                    std::thread::sleep(Duration::from_millis(100));
                    continue;
                }
                if target.refresh_requested.swap(false,Ordering::AcqRel) {
                    // A session that has never delivered a frame can remain
                    // stuck after Recreate. Close it on its owning thread and
                    // start a fresh session for the same authenticated HWND.
                    // This is request-driven; no retry loop on a timer.
                    if target.progress.acquired.load(Ordering::Relaxed)==0 {
                        restart_session=true;break;
                    }
                    // Recreate on this capture thread, after any prior packet's
                    // ACK, rather than racing a second producer for the HWND.
                    pool.Recreate(&runtime,DirectXPixelFormat::B8G8R8A8UIntNormalized,2,size).map_err(error)?;
                    target.progress.recreates.fetch_add(1,Ordering::Relaxed);
                    generation=generation.saturating_add(1);previous=[0;6];native_gpu=None;
                    let _=RedrawWindow(Some(hwnd),None,None,RDW_INVALIDATE|RDW_ALLCHILDREN|RDW_FRAME);
                }
                target.set_phase(Phase::Waiting);
                let _ = ready.recv_timeout(Duration::from_millis(100));
                target.set_phase(Phase::Reading);
                let mut frame = match pool.TryGetNextFrame() {
                    Ok(frame)=>{target.progress.acquired.fetch_add(1,Ordering::Relaxed);frame},
                    Err(error)=>{
                        target.progress.dequeue_hresult.store(error.code().0 as u32,Ordering::Relaxed);
                        continue;
                    }
                };
                // The pool has two slots. Prefer its newest available frame,
                // rather than spending readback and network time on an old one.
                for _ in 0..2 {
                    let Ok(newer) = pool.TryGetNextFrame() else {break};
                    target.progress.acquired.fetch_add(1,Ordering::Relaxed);
                    let _ = frame.Close(); frame = newer;
                }
                // Keep this GPU frame until the replaceable network slot is
                // available. Do not read back images just to replace pending
                // pixels, and never discard the final update of a static window.
                target.set_phase(Phase::Backpressure);
                if !outbox.wait_for_frame_slot(&target.id, stop) {
                    let _ = frame.Close();
                    break;
                }
                for _ in 0..2 {
                    let Ok(newer) = pool.TryGetNextFrame() else {break};
                    target.progress.acquired.fetch_add(1,Ordering::Relaxed);
                    let _ = frame.Close(); frame = newer;
                }
                target.set_phase(Phase::Reading);
                let mut gpu_selected_qpc=0;let _=windows::Win32::System::Performance::QueryPerformanceCounter(&mut gpu_selected_qpc);
                let frame_dirty_mode=frame.DirtyRegionMode().ok().map(|mode|mode.0);
                let dirty_regions=frame.DirtyRegions().ok().and_then(|regions|regions.Size().ok());
                if let Some(description)=target.capture_device.lock().unwrap().as_mut() {
                    description["wgcFrame"]=json!({"dirtyRegionMode":frame_dirty_mode,"dirtyRegionCount":dirty_regions});
                }
                let current = frame.ContentSize().map_err(error)?;
                if current.Width <= 0
                    || current.Height <= 0
                    || current.Width > 16_384
                    || current.Height > 16_384
                    || i64::from(current.Width) * i64::from(current.Height) > 8_388_608
                {
                    let _ = frame.Close();
                    return Err("Window exceeds the initial capture limit".into());
                }
                let resize_pool = current != size;
                if resize_pool {
                    size = current;
                    generation += 1;
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
                    target.set_phase(Phase::Recreating);
                    target.progress.recreates.fetch_add(1,Ordering::Relaxed);
                    pool.Recreate(
                        &runtime,
                        DirectXPixelFormat::B8G8R8A8UIntNormalized,
                        2,
                        size,
                    )
                    .map_err(error)?;
                    continue;
                }
                let hwnd = HWND(target.hwnd as *mut _);
                let (x, y, width, height) = if target.full_frame {
                    // WGC can round an odd DWM extent up by one pixel. That
                    // trailing row/column is not part of the window described
                    // to the host; exporting it leaves the geometry gate stuck.
                    let bounds=catalogue::frame_bounds(hwnd).ok_or("Window bounds unavailable")?;
                    let frame_width=bounds.right-bounds.left;
                    let frame_height=bounds.bottom-bounds.top;
                    let width=if frame_width>0 && (0..=1).contains(&(size.Width-frame_width)){frame_width}else{size.Width};
                    let height=if frame_height>0 && (0..=1).contains(&(size.Height-frame_height)){frame_height}else{size.Height};
                    (0, 0, width, height)
                } else {
                    client(hwnd, size.Width, size.Height)?
                };
                let geometry = [size.Width, size.Height, x, y, width, height];
                if geometry != previous {
                    generation += 1;
                    previous = geometry;
                }
                if !outbox.gpu_enabled.load(Ordering::Acquire) || software_recovery {
                    return Err("Solo GPU: questa superficie non è supportata. Nessun fallback TCP.".into());
                }
                if native_gpu.as_ref().is_none_or(|g|!g.matches(width as u32,height as u32)) {
                    native_gpu=Some(super::gpu::Gpu::new(&device,width as u32,height as u32)?);
                }
                target.set_phase(Phase::Publishing);sequence+=1;
                native_gpu.as_mut().unwrap().submit(&device,&context,&texture,x,y,&target,&outbox,generation,sequence.into(),gpu_selected_qpc)?;
                frame.Close().map_err(error)?;
                if resize_pool {pool.Recreate(&runtime,DirectXPixelFormat::B8G8R8A8UIntNormalized,2,size).map_err(error)?;}
            }
            Ok(())
        })();
        if target.capture_phase.load(Ordering::Acquire) != Phase::Invalidated as u8 {
            target.set_phase(Phase::Closing);
        }
        let _ = session.Close();
        let _ = pool.RemoveFrameArrived(registration);
        let _ = pool.Close();
        result.map(|()|restart_session)
    }
}

fn gpu_error(device: &ID3D11Device, operation: &str, cause: windows::core::Error) -> String {
    let reason = unsafe { device.GetDeviceRemovedReason() };
    format!("{operation}: {cause}; device status: {}", match reason {
        Ok(()) => "S_OK".into(), Err(reason) => reason.to_string(),
    })
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
