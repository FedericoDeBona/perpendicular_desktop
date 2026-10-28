use super::{
    Configuration, app_process,
    capture::{self, Target},
    catalogue::{self, Catalogue},
    clipboard, cloak, display, display_topology, error, execute, identity, window_control,
    wire::{self, Outbox},
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::Write,
    net::{SocketAddr, TcpStream},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use windows::Win32::{
    Foundation::{HWND, LPARAM, POINT, RECT, WPARAM, GetLastError, ERROR_ACCESS_DENIED},
    Graphics::Gdi::{ClientToScreen, GetMonitorInfoW, MonitorFromPoint, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTOPRIMARY, MONITOR_DEFAULTTONEAREST},
    System::{Com::{COINIT_APARTMENTTHREADED, CoCreateGuid, CoInitializeEx},
        Power::{EXECUTION_STATE,ES_CONTINUOUS,ES_DISPLAY_REQUIRED,SetThreadExecutionState}},
    UI::{
        HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext},
        Input::KeyboardAndMouse::*,
        WindowsAndMessaging::*,
    },
};

struct Window {
    target: Arc<Target>,
    app: String,
    metadata: Value,
    parent: Option<String>,
    stop: Option<Arc<AtomicBool>>,
    mac_owned: bool,
    cloak: Option<cloak::Window>,
    cloak_error: Option<String>,
    isolation_attempts:u8,
    isolation_retry_after:Instant,
    capture_unavailable_since:Option<Instant>,
}
struct Launch {
    app: String,
    deadline: Instant,
}
struct ActivationResult {
    app: String,
    nonce: u64,
    result: Result<(u32, u64), String>,
}
struct ApplicationSession {
    processes: Vec<app_process::Process>,
    gap_until: Option<Instant>,
    startup_until: Instant,
    activation: Option<u64>,
    baseline: HashSet<usize>,
}
struct Worker {
    sid: String,
    session: u32,
    epoch: String,
    catalogue: Catalogue,
    windows: HashMap<String, Window>,
    pending: Vec<Launch>,
    applications: HashMap<String, ApplicationSession>,
    activation_sender: mpsc::SyncSender<ActivationResult>,
    activation_results: mpsc::Receiver<ActivationResult>,
    activation_serial: u64,
    next_process_scan: Instant,
    next_minimum_scan: Instant,
    serial: u64,
    pressed: HashSet<u16>,
    pending_unicode: Option<u16>,
    buttons: HashSet<String>,
    display_busy: Arc<AtomicBool>,
    graphics_busy: Arc<AtomicBool>,
    execution_busy: Arc<AtomicBool>,
    process_busy: Arc<AtomicBool>,
    display_observer: Option<display::Observer>,
}

fn state_path() -> PathBuf {
    PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap_or_else(|| "C:\\Windows\\Temp".into()))
        .join("Perpendicular Restart")
        .join("windows.json")
}
fn log(message: impl std::fmt::Display) {
    let path = state_path().with_file_name("worker.log");
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(file, "{message}");
    }
}

// SetForegroundWindow notifies a different input queue asynchronously. Wait for
// that activation notification before checking foreground ownership; an
// immediate GetForegroundWindow can otherwise report a false focus refusal.
fn activate_window(hwnd: HWND) -> Result<(), String> {
    unsafe {
        let root = GetAncestor(hwnd, GA_ROOT);
        if GetAncestor(GetForegroundWindow(), GA_ROOT) == root { return Ok(()); }
        // Never join another application's input queue: an unresponsive
        // foreground thread can then block this worker inside activation.
        let accepted = SetForegroundWindow(root).as_bool();
        if accepted {
            let _ = SendMessageTimeoutW(root, WM_NULL, WPARAM(0), LPARAM(0),
                SMTO_ABORTIFHUNG | SMTO_BLOCK, 250, None);
        }
        if GetAncestor(GetForegroundWindow(), GA_ROOT) == root { Ok(()) }
        else {
            log(format!("Activation incomplete accepted={accepted} hwnd={}", root.0 as usize));
            Err("Windows did not grant this window keyboard focus".into())
        }
    }
}

fn activate_surface(window:&Window)->Result<(),String> {
    if let Some(scope)=window.cloak.as_ref().filter(|scope|scope.active()) {
        scope.activate()?;
        if !scope.native_input(){return Ok(());}
    }
    activate_window(HWND(window.target.hwnd as _))
}

// Viewing a streamed window does not count as guest user input. Keep the
// display available before starting WGC, including after an idle disconnect.
// This guard lives on the connected worker thread, which owns the request.
// Do not change the power plan, block screen locking or request system sleep
// prevention. Restore this thread's previous requirements on every exit.
struct ConnectedDisplay(EXECUTION_STATE);
impl ConnectedDisplay {
    fn acquire()->Option<Self> {
        let previous=unsafe {SetThreadExecutionState(ES_CONTINUOUS|ES_DISPLAY_REQUIRED)};
        if previous.0==0 {log("Display request unavailable for host connection");None}
        else {log("Display required for host connection");Some(Self(previous))}
    }
}
impl Drop for ConnectedDisplay {
    fn drop(&mut self) {
        let restored=unsafe {SetThreadExecutionState(self.0|ES_CONTINUOUS)}.0!=0;
        log(format!("Host display request released restored={restored}"));
    }
}

pub fn run(path: &Path) -> Result<(), String> {
    let config: Configuration =
        serde_json::from_slice(&std::fs::read(path).map_err(error)?).map_err(error)?;
    if config.token.len() != 64 || config.port < 1024 {
        return Err("Invalid connection configuration".into());
    }
    unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED)
            .ok()
            .map_err(error)?;
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let (sid, session) = identity::current()?;
    let epoch = unsafe { format!("{:?}", CoCreateGuid().map_err(error)?) };
    let _gpu_log=match super::gpu_log::start(&state_path().with_file_name(format!("gpu-driver-{epoch}.log"))) {
        Ok(sink)=>Some(sink),
        Err(error)=>{log(format!("GPU stderr diagnostics unavailable: {error}"));None},
    };
    let (activation_sender, activation_results) = mpsc::sync_channel(8);
    let mut worker = Worker {
        sid,
        session,
        epoch,
        catalogue: Catalogue::new(),
        windows: HashMap::new(),
        pending: Vec::new(),
        applications: HashMap::new(),
        activation_sender,
        activation_results,
        activation_serial: 0,
        next_process_scan: Instant::now(),
        next_minimum_scan: Instant::now(),
        serial: 0,
        pressed: HashSet::new(),
        pending_unicode: None,
        buttons: HashSet::new(),
        display_busy: Arc::new(AtomicBool::new(false)),
        graphics_busy: Arc::new(AtomicBool::new(false)),
        execution_busy: Arc::new(AtomicBool::new(false)),
        process_busy: Arc::new(AtomicBool::new(false)),
        display_observer: match display::Observer::new() {
            Ok(observer) => Some(observer),
            Err(error) => {
                log(format!("Display change notifications unavailable: {error}"));
                None
            }
        },
    };
    worker.restore();
    let endpoint: SocketAddr = format!("10.0.2.2:{}", config.port).parse().map_err(error)?;
    let mut delay = 1;
    loop {
        match TcpStream::connect_timeout(&endpoint, Duration::from_secs(3)) {
            Ok(stream) => {
                delay = 1;
                log("Host connected");
                if let Err(e) = worker.connected(stream, &config) {
                    log(e);
                }
                for window in worker.windows.values_mut() { window.cloak.take(); }
                worker.release();
            }
            Err(e) => {
                log(format!("Waiting for host: {e}"));
                delay = (delay * 2).min(8);
            }
        }
        std::thread::sleep(Duration::from_secs(delay));
    }
}

impl Worker {
    fn connected(&mut self, mut stream: TcpStream, config: &Configuration) -> Result<(), String> {
        let _display=ConnectedDisplay::acquire();
        stream.set_nodelay(true).map_err(error)?;
        stream
            .set_read_timeout(Some(Duration::from_secs(8)))
            .map_err(error)?;
        let outbox = Outbox::new();
        let writer = stream.try_clone().map_err(error)?;
        let sender = outbox.clone();
        std::thread::spawn(move || sender.writer(writer));
        outbox.control(
            json!({"type":"hello","protocol":1,"token":config.token,"epoch":self.epoch,
            "sid":self.sid,"session":self.session,"version":env!("CARGO_PKG_VERSION"),
            "capabilities":{"capture":"wgc-hardware-readback-with-software-recovery","windows":4,"transients":12,"windowRoles":true,"input":true,"catalogue":true,"appIcon":true,"frameChannel":true,"windowRefresh":true,"nativeAppInput":true,"modeFocus":true,"deviceFocus":true,"gpuFramesOnly":true,"frameEncodings":[],"displayInfo":true,"displayTopology":true,"driverInfo":true,"graphicsInfo":true,"displayConfigure":true,"sharedGeometry":true,"processControl":true,"clipboard":true,"clipboardTextBytes":262144,"applicationStatus":true,"memoryStatus":true,"execute":true,"executeTimeoutSeconds":60,"executeOutputBytes":65536,"displayEvents":self.display_observer.is_some()}}),
        );
        let (sender, receiver) = mpsc::sync_channel(128);
        let state = outbox.clone();
        std::thread::spawn(move || {
            while state.connected.load(Ordering::Acquire) {
                match wire::read(&mut stream) {
                    Ok(value) => {
                        // A burst of typing must wait for the bounded consumer,
                        // not sever the session and discard already committed text.
                        if sender.send(value).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            state.connected.store(false, Ordering::Release);
        });
        self.release();
        self.finish_activations(&outbox);
        let restored: Vec<_> = self.windows.iter().filter_map(|(id, window)| {
            let mut details = catalogue::details(window.target.hwnd, &self.sid, self.session)?;
            window_control::describe_minimum(&mut details);
            Some((id.clone(), self.application_surface(details, &window.app)))
        }).collect();
        for (id, metadata) in restored {
            if let Some(window) = self.windows.get_mut(&id) { window.metadata = metadata; }
        }
        // A control-only desktop connection must not restore WGC captures.
        // Restore them only after the host explicitly requests window frames.
        self.snapshot(&outbox);
        let mut poll = Instant::now();
        let diagnostic_busy = Arc::new(AtomicBool::new(false));
        let icon_busy = Arc::new(AtomicBool::new(false));
        let mut frame_channel_started = false;
        while outbox.connected.load(Ordering::Acquire) {
            // Commands wake this wait immediately. Only window discovery needs
            // a deadline; do not wake 100 times/s to check a 75 ms observation.
            let interval = if self.windows.is_empty() && self.pending.is_empty() {
                Duration::from_millis(500)
            } else { Duration::from_millis(75) };
            if let Ok(command) = receiver.recv_timeout(interval.saturating_sub(poll.elapsed())) {
                let request = command["request"].clone();
                if command["operation"] == "trial_clock" {outbox.control(json!({"type":"reply","request":request,"ok":true,"result":super::gpu::clock()}));continue;}
                if command["operation"] == "frame_channel" {
                    let channel = command["channel"].as_str().filter(|s| s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit()));
                    if frame_channel_started || channel.is_none() || command["rowAlignment"] != 256
                        || (!command["encoding"].is_null() && command["encoding"] != "lz4-block") {
                        outbox.control(json!({"type":"reply","request":request,"ok":false,"message":"Invalid or duplicate frame channel"}));
                        continue;
                    }
                    outbox.gpu_enabled.store(command["gpuFrames"]==true,Ordering::Release);
                    if command["gpuFrames"] != true {outbox.control(json!({"type":"reply","request":request,"ok":false,"message":"Solo GPU: canale immagini GPU richiesto."}));continue;}
                    let compress_frames = false;
                    frame_channel_started = true;
        for window in self.windows.values_mut() {
            window.target = Arc::new(window.target.fresh_capture());
            window.stop = Some(capture::spawn(window.target.clone(), outbox.clone()));
        }

                    let channel = channel.unwrap().to_owned();
                    let endpoint: SocketAddr = format!("10.0.2.2:{}", config.port).parse().map_err(error)?;
                    let hello = json!({"type":"hello","role":"frames","protocol":1,"token":config.token,
                        "sid":self.sid,"session":self.session,"epoch":self.epoch,"channel":channel});
                    let sender = outbox.clone();
                    std::thread::spawn(move || {
                        let result = TcpStream::connect_timeout(&endpoint, Duration::from_secs(2));
                        match result {
                            Ok(stream) => {
                                sender.control(json!({"type":"reply","request":request,"ok":true,"result":{"accepted":true}}));
                                if sender.clone().start_frames(stream, hello, compress_frames).is_err() {sender.connected.store(false, Ordering::Release);}
                            }
                            Err(_) => {sender.connected.store(false, Ordering::Release);}
                        }
                    });
                    continue;
                }
                if command["operation"] == "app_icon" {
                    let app = command["app"].as_str().unwrap_or("");
                    let source = self.catalogue.icon_source(app);
                    if source.is_err() || icon_busy.swap(true, Ordering::AcqRel) {
                        outbox.control(json!({"type":"reply","request":request,"ok":false,"message":"Application icon unavailable or busy"}));
                    } else {
                        let app = app.to_owned();
                        let parsing = source.unwrap();
                        let sender = outbox.clone();
                        let busy = icon_busy.clone();
                        std::thread::spawn(move || {
                            let result = super::icons::extract(&app, &parsing);
                            sender.control(match result {
                                Ok(value) => json!({"type":"reply","request":request,"ok":true,"result":value}),
                                Err(message) => json!({"type":"reply","request":request,"ok":false,"message":message}),
                            });
                            busy.store(false, Ordering::Release);
                        });
                    }
                    continue;
                }
                if command["operation"] == "process_list" || command["operation"] == "process_terminate" {
                    if self.process_busy.swap(true, Ordering::AcqRel) {
                        outbox.control(json!({"type":"reply","request":request,"ok":false,"message":"Process query already running"}));
                    } else {
                        let sender = outbox.clone();
                        let busy = self.process_busy.clone();
                        let sid = self.sid.clone();
                        let session = self.session;
                        std::thread::spawn(move || {
                            let result = if command["operation"] == "process_list" { app_process::list(&sid, session) }
                            else { (|| {
                                let pid = command["pid"].as_u64().and_then(|p| u32::try_from(p).ok()).ok_or("Invalid process ID")?;
                                let creation = command["creation"].as_str().and_then(|s| s.parse().ok()).ok_or("Missing process creation identity")?;
                                app_process::terminate(pid, creation, &sid, session)
                            })() };
                            busy.store(false, Ordering::Release);
                            sender.control(match result {
                                Ok(value) => json!({"type":"reply","request":request,"ok":true,"result":value}),
                                Err(message) => json!({"type":"reply","request":request,"ok":false,"message":message}),
                            });
                        });
                    }
                    continue;
                }
                if command["operation"] == "memory_status" {
                    outbox.control(match super::memory::status() {
                        Ok(value) => json!({"type":"reply","request":request,"ok":true,"result":value}),
                        Err(message) => json!({"type":"reply","request":request,"ok":false,"message":message}),
                    });
                    continue;
                }
                if command["operation"] == "execute" {
                    if self.execution_busy.swap(true, Ordering::AcqRel) {
                        outbox.control(json!({"type":"reply","request":request,"ok":false,"message":"A command is already running"}));
                    } else {
                        let sender = outbox.clone();
                        let busy = self.execution_busy.clone();
                        std::thread::spawn(move || {
                            let result = execute::run(&command);
                            busy.store(false, Ordering::Release);
                            sender.control(match result {
                                Ok(value) => json!({"type":"reply","request":request,"ok":true,"result":value}),
                                Err(message) => json!({"type":"reply","request":request,"ok":false,"message":message}),
                            });
                        });
                    }
                    continue;
                }
                if command["operation"] == "diagnostics"
                    || command["operation"] == "driver_info"
                    || command["operation"] == "display_info"
                    || command["operation"] == "graphics_info"
                    || command["operation"] == "display_configure"
                    || command["operation"] == "display_topology"
                    || command["operation"] == "display_layout"
                {
                    let graphics_request = command["operation"] == "graphics_info";
                    let driver_request = command["operation"] == "driver_info";
                    let configure_request = command["operation"] == "display_configure";
                    let topology_request = command["operation"] == "display_topology";
                    let layout_request = command["operation"] == "display_layout";
                    let display_request = command["operation"] == "display_info" || configure_request || topology_request || layout_request;
                    let busy = if graphics_request {
                        self.graphics_busy.clone()
                    } else if display_request {
                        self.display_busy.clone()
                    } else {
                        diagnostic_busy.clone()
                    };
                    if busy.swap(true, Ordering::AcqRel) {
                        outbox.control(json!({"type":"reply","request":request,"ok":false,"message":"Diagnostics already running"}));
                    } else {
                        let sender = outbox.clone();
                        std::thread::spawn(move || {
                            let result = if driver_request {
                                super::drivers::devices().map(|devices| json!({"devices":devices}))
                            } else if graphics_request {
                                Ok(display::graphics())
                            } else if configure_request {
                                display::configure(&command)
                            } else if topology_request {
                                display_topology::snapshot()
                            } else if layout_request {
                                display_topology::configure(&command)
                            } else if display_request {
                                Ok(display::snapshot())
                            } else {
                                diagnostics()
                            };
                            // A reply authorizes the host's next operation.
                            // Release the completed operation before queuing it.
                            busy.store(false, Ordering::Release);
                            sender.control(match result{Ok(value)=>json!({"type":"reply","request":request,"ok":true,"result":value}),
                                Err(message)=>json!({"type":"reply","request":request,"ok":false,"message":message})});
                        });
                    }
                    continue;
                }
                if !frame_channel_started && command["operation"] == "launch" {
                    outbox.control(json!({"type":"reply","request":request,"ok":false,"message":"Individual windows are disabled in this desktop connection"}));
                    continue;
                }
                if command["operation"] != "heartbeat" {
                    let result = self.command(&command, &outbox);
                    outbox.control(match result {
                        Ok(value) => {
                            json!({"type":"reply","request":request,"ok":true,"result":value})
                        }
                        Err(message) => {
                            json!({"type":"reply","request":request,"operation":command["operation"],
                                "window":command["window"],"ok":false,"message":message})
                        }
                    });
                }
            }
            unsafe {
                let mut message = MSG::default();
                while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                    let _ = TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
            }
            if self
                .display_observer
                .as_ref()
                .is_some_and(|observer| observer.take_changed())
            {
                outbox.control(json!({"type":"display_changed","epoch":self.epoch}));
            }
            if poll.elapsed() >= interval {
                if frame_channel_started {
                self.observe(&outbox);
                }
                poll = Instant::now();
            }
        }
        for window in self.windows.values_mut() {
            window.cloak.take();
            if let Some(stop) = window.stop.take() {
                stop.store(true, Ordering::Release);
            }
        }
        outbox.connected.store(false, Ordering::Release);
        Err("Host disconnected; retaining application identities".into())
    }

    fn desktop_application(&self,app:&str,raw:usize)->Option<Value> {
        if raw==0 || !self.catalogue.matches(app,raw)
            || self.windows.values().any(|w|w.mac_owned && w.target.hwnd==raw) {return None;}
        let details=catalogue::details(raw,&self.sid,self.session)?;
        if catalogue::transient(&details) || catalogue::shell_surface(raw) {return None;}
        let owner=identity::owner(HWND(raw as _),&self.sid,self.session)?;
        Some(json!({"app":app,"target":{"hwnd":raw,"pid":owner.0,"creation":owner.1.to_string()}}))
    }
    fn desktop_singleton_state(&self,value:&Value)->Result<Value,String> {
        let app=value["app"].as_str().ok_or("Missing app identity")?;
        let raw=value["target"]["hwnd"].as_u64().ok_or("Missing window identity")? as usize;
        let actual=self.desktop_application(app,raw).ok_or("The Windows application changed")?;
        if actual["target"]!=value["target"] {return Err("The Windows application changed".into());}
        unsafe {
            let hwnd=HWND(raw as _);
            if !IsWindowVisible(hwnd).as_bool() || !IsWindowEnabled(hwnd).as_bool() || IsIconic(hwnd).as_bool() {
                return Err("Restore this application or finish its dialog in Windows".into());
            }
            let primary=MonitorFromPoint(POINT{x:0,y:0},MONITOR_DEFAULTTOPRIMARY);
            let mut info=MONITORINFO{cbSize:size_of::<MONITORINFO>() as u32,..Default::default()};
            if !GetMonitorInfoW(primary,&mut info).as_bool() || info.dwFlags&1==0 {return Err("Windows desktop display unavailable".into());}
            let seamless=value["destination"]=="seamless";
            if seamless && !self.catalogue.singleton(app) {return Err("This application requires a new Seamless window".into());}
            let (destination,work)=if seamless {
                let (frame,work)=window_control::first_app_work_area().ok_or("Seamless displays are not ready")?;
                let monitor=MonitorFromPoint(POINT{x:frame.left+1,y:frame.top+1},MONITOR_DEFAULTTONEAREST);
                if monitor==primary {return Err("Seamless display cannot be the Windows desktop".into());}
                (monitor,work)
            }else{(primary,info.rcWork)};
            let mut bounds=catalogue::frame_bounds(hwnd).ok_or("Window geometry unavailable")?;
            let focused=GetAncestor(GetForegroundWindow(),GA_ROOT)==hwnd;
            let mut gui=GUITHREADINFO{cbSize:size_of::<GUITHREADINFO>() as u32,..Default::default()};
            GetGUIThreadInfo(0,&mut gui).map_err(error)?;
            // Check before any geometry mutation, including the direct API.
            // A real user drag, menu or held pointer must never be fought.
            if !gui.hwndCapture.is_invalid() || gui.flags.0&0x1e!=0 {return Err("Finish the current Windows interaction before switching apps".into());}
            let contained=|r:RECT|r.left>=work.left-1 && r.top>=work.top-1 && r.right<=work.right+1 && r.bottom<=work.bottom+1;
            let mut direct_error=None;
            if value["place"]==true && !contained(bounds) {
                let mut outer=RECT::default();GetWindowRect(hwnd,&mut outer).map_err(error)?;
                let width=(bounds.right-bounds.left).min(work.right-work.left).max(160);
                let height=(bounds.bottom-bounds.top).min(work.bottom-work.top).max(100);
                if let Err(cause)=SetWindowPos(hwnd,None,work.left-(bounds.left-outer.left),work.top-(bounds.top-outer.top),
                    width+(outer.right-outer.left)-(bounds.right-bounds.left),
                    height+(outer.bottom-outer.top)-(bounds.bottom-bounds.top),
                    SWP_NOZORDER|SWP_NOACTIVATE|SWP_ASYNCWINDOWPOS) {direct_error=Some(error(cause));}
                bounds=catalogue::frame_bounds(hwnd).ok_or("Window geometry unavailable")?;
            }
            let on_destination=MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)==destination;
            let mut move_key=None;
            if seamless && on_destination && !contained(bounds) && !IsZoomed(hwnd).as_bool() {
                let mut title=[0u16;128];
                let count=GetMenuStringW(GetSystemMenu(hwnd,false),SC_MOVE,Some(&mut title),MF_BYCOMMAND).max(0) as usize;
                let title=String::from_utf16_lossy(&title[..count]);
                move_key=title.split('&').nth(1).and_then(|v|v.chars().next())
                    .filter(char::is_ascii_alphabetic).map(|v|v.to_ascii_lowercase().to_string());
            }
            let adjustment=if bounds.right-bounds.left>work.right-work.left || bounds.bottom-bounds.top>work.bottom-work.top {None}
                else if bounds.top<work.top {Some("down")}else if bounds.bottom>work.bottom {Some("up")}
                else if bounds.left<work.left {Some("right")}else if bounds.right>work.right {Some("left")}else{None};
            let on_desktop=on_destination && contained(bounds);
            log(format!("Application destination seamless={seamless} hwnd={raw} focused={focused} visible={on_desktop} rect={},{},{},{} directError={direct_error:?}",bounds.left,bounds.top,bounds.right,bounds.bottom));
            Ok(json!({"focused":focused,"onDesktop":on_desktop,"onPrimary":MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)==destination,"rect":[bounds.left,bounds.top,bounds.right,bounds.bottom],
                "maxMoves":GetSystemMetrics(SM_CMONITORS).clamp(1,8),"zoomed":IsZoomed(hwnd).as_bool(),
                "moveKey":move_key,"adjustment":adjustment}))
        }
    }
    fn command(&mut self, value: &Value, outbox: &Arc<Outbox>) -> Result<Value, String> {
        // Releases never depend on a window, pointer coordinates or capture generation.
        // A resize or a retired popup must not leave an injected button/key held.
        if value["operation"] == "input" && value["down"] == false {
            match value["event"].as_str() {
                Some("button") => {
                    let button = value["button"].as_str().ok_or("Missing button")?;
                    self.release_button(button)?;
                    return Ok(json!({"accepted":true}));
                }
                Some("key") => {
                    let key = value["key"]
                        .as_u64()
                        .filter(|v| *v > 0 && *v <= 255)
                        .ok_or("Invalid key")? as u16;
                    send(keyboard(key, true))?;
                    self.pressed.remove(&key);
                    return Ok(json!({"accepted":true}));
                }
                _ => {}
            }
        }
        match value["operation"].as_str().ok_or("Missing operation")? {
            "catalogue" => Ok(self.catalogue.refresh()?),
            "app_input_mode" => {
                let enabled=value["enabled"].as_bool().ok_or("Missing input mode")?;
                window_control::set_native_app_input(enabled)?;
                Ok(json!({"accepted":true}))
            }
            "desktop_focus_target" => {
                let foreground=catalogue::foreground();
                let window=self.windows.values().find(|w|w.mac_owned && self.catalogue.singleton(&w.app)
                    && w.target.hwnd==foreground && w.target.valid()).map(|w|(w.target.id.clone(),w.app.clone()));
                let off_primary=unsafe {MonitorFromWindow(HWND(foreground as _),MONITOR_DEFAULTTONEAREST)
                    !=MonitorFromPoint(POINT{x:0,y:0},MONITOR_DEFAULTTOPRIMARY)};
                let idle=unsafe {
                    let mut gui=GUITHREADINFO{cbSize:size_of::<GUITHREADINFO>() as u32,..Default::default()};
                    GetGUIThreadInfo(0,&mut gui).is_ok() && gui.hwndCapture.is_invalid() && gui.flags.0&0x1e==0
                };
                // An explicit Desktop input that activates the Mac-owned
                // singleton transfers ownership, rather than pulling focus
                // back into its Mac mirror. Retire children before the owner.
                if let Some((id,app))=window.as_ref().filter(|_|idle && value["transfer"]==true) {
                    let mut ids:Vec<_>=self.windows.iter().filter(|(_,w)|w.app==*app && w.target.id!=*id)
                        .map(|(id,_)|id.clone()).collect();
                    ids.push(id.clone());
                    for id in ids {self.retire_window(&id,outbox);}
                    self.pending.retain(|p|p.app!=*app);
                    if let Some(session)=self.applications.get_mut(app) {session.startup_until=Instant::now();}
                    self.save();self.snapshot(outbox);
                    outbox.control(json!({"type":"launch_state","app":app,"state":"desktop"}));
                    let target=self.desktop_application(app,foreground).ok_or("Application changed during transfer")?;
                    log(format!("Application transferred to Desktop app={app} hwnd={foreground}"));
                    return Ok(json!({"desktopSingleton":target,"transferred":true}));
                }
                let singleton=if window.is_none() && off_primary && idle {
                    self.catalogue.items.keys().find_map(|app|self.desktop_application(app,foreground))
                }else{None};
                Ok(json!({"window":window.map(|w|w.0),"desktopSingleton":singleton}))
            }
            "desktop_singleton_state" => self.desktop_singleton_state(value),
            "seamless_adopt" => {
                let mut state_request=value.clone();state_request["destination"]=json!("seamless");
                let state=self.desktop_singleton_state(&state_request)?;
                if state["onDesktop"]!=true {return Err("The application has not reached its Seamless display".into());}
                let app=value["app"].as_str().ok_or("Missing app identity")?.to_owned();
                let raw=value["target"]["hwnd"].as_u64().ok_or("Missing window identity")? as usize;
                if !self.add(raw,app.clone(),outbox) {return Err("The existing application could not be transferred".into());}
                self.save();self.snapshot(outbox);
                log(format!("Application transferred to Seamless app={app} hwnd={raw}"));
                Ok(json!({"accepted":true}))
            }
            "window_refresh" => {
                let id=value["window"].as_str().ok_or("Missing window identity")?;
                let window=self.windows.get_mut(id).ok_or("Window retired")?;
                if !window.target.valid(){return Err("Window retired".into());}
                if window.cloak.is_none() {
                    window.cloak_error=None;window.isolation_attempts=0;window.isolation_retry_after=Instant::now();
                }
                if window.stop.as_ref().is_none_or(|s|s.load(Ordering::Acquire)) {
                    outbox.retire(id);
                    window.target=Arc::new(window.target.fresh_capture());
                    window.stop=Some(capture::spawn(window.target.clone(),outbox.clone()));
                    window.capture_unavailable_since=None;
                    window.cloak_error=None;
                }else {window.target.refresh_requested.store(true,Ordering::Release);}
                log(format!("Window capture refresh requested hwnd={}",window.target.hwnd));
                self.snapshot(outbox);
                Ok(json!({"requested":true}))
            }
            "launch" => {
                let app = value["app"].as_str().ok_or("Missing app identity")?;
                if let Some(window) = self.windows.values().find(|w| {
                    w.app == app && !catalogue::transient(&w.metadata) && w.target.valid()
                }) {
                    let window = self.activation_window(window)?;
                    // Host focus must not depend on foreground permission in
                    // Windows (for example when an elevated app is in front).
                    outbox.control(json!({"type":"activate","window":window.target.id}));
                    unsafe {
                        let _ = ShowWindow(HWND(window.target.hwnd as *mut _), SW_RESTORE);
                        activate_surface(window)?;
                    }
                    return Ok(json!({"accepted":true,"existing":true}));
                }
                if self.catalogue.singleton(app) {
                    let existing=catalogue::windows().into_iter().find_map(|raw| {
                        if !self.catalogue.matches(app,raw){return None;}
                        identity::owner(HWND(raw as _),&self.sid,self.session).map(|owner|(raw,owner))
                    });
                    if let Some((raw,owner))=existing {
                        if self.document_count()>=4 {return Err("Close an application before opening another".into());}
                        // This is an explicit request for the exact existing
                        // singleton. Move it before admitting it to capture.
                        // Let Windows perform normal single-instance
                        // activation before attempting the cross-mode move.
                        // SetForegroundWindow alone is often denied after
                        // the user has been interacting with another app.
                        let activation=self.catalogue.prepare_launch(app)?;
                        let sender=outbox.clone();let app=app.to_owned();let sid=self.sid.clone();let session=self.session;
                        std::thread::Builder::new().name("singleton-transfer".into()).spawn(move || {
                            let result=if identity::owner(HWND(raw as _),&sid,session)==Some(owner) {
                                activation.run().and_then(|_| {
                                    if identity::owner(HWND(raw as _),&sid,session)==Some(owner) {Ok(())}
                                    else {Err("The existing application window changed".into())}
                                })
                            }else{Err("The existing application window changed".into())};
                            sender.control(match result {
                                Ok(())=>json!({"type":"seamless_transfer","app":app,"target":{"hwnd":raw,"pid":owner.0,"creation":owner.1.to_string()}}),
                                Err(message)=>json!({"type":"launch_error","app":app,"message":message}),
                            });
                        }).map_err(error)?;
                        return Ok(json!({"accepted":true,"existing":true,"ready":false,"destination":"seamless"}));
                    }
                }
                if self.pending.iter().any(|p| p.app == app) {
                    return Ok(json!({"accepted":true,"pending":true}));
                }
                let activation = self.catalogue.prepare_launch(app)?;
                if self.applications.get(app).is_some_and(|session| {
                    // The observation grace period is not evidence of a live
                    // launch. Pending activation is checked above; after a
                    // verified exit the user must be able to launch again.
                    session.activation.is_some()
                }) {
                    outbox.control(json!({"type":"launch_state","app":app,"state":"waiting"}));
                    return Ok(json!({"accepted":true,"existing":true,"ready":false}));
                }
                if self.document_count() >= 4 {
                    return Err("Close an application before opening another".into());
                }
                if !self.applications.contains_key(app) && self.applications.len() >= 8 {
                    return Err("Too many application transitions are still active".into());
                }
                self.activation_serial += 1;
                let nonce = self.activation_serial;
                let sender = self.activation_sender.clone();
                let app_id = app.to_string();
                let baseline = catalogue::windows().into_iter().collect();
                std::thread::Builder::new().name("app-activation".into()).spawn(move || {
                    let result = activation.run();
                    let _ = sender.send(ActivationResult { app: app_id, nonce, result });
                }).map_err(error)?;
                let until = Instant::now() + Duration::from_secs(30);
                log(format!("Application activation started app={app} nonce={nonce}"));
                let processes=self.applications.remove(app).map(|session|session.processes).unwrap_or_default();
                self.applications.insert(app.into(), ApplicationSession {
                    processes, gap_until: Some(until), startup_until: until,
                    activation: Some(nonce),
                    baseline,
                });
                self.next_process_scan = Instant::now();
                self.pending.push(Launch {
                    app: app.into(),
                    deadline: until,
                });
                self.save();
                outbox.control(json!({"type":"launch_state","app":app,"state":"waiting"}));
                Ok(json!({"accepted":true,"ready":false}))
            }
            "application_status" => Ok(self.application_status()),
            "application_close" => {
                let app = value["app"].as_str().ok_or("Missing app identity")?;
                let mut count = 0;
                for window in self.windows.values().filter(|w| w.app == app && !catalogue::transient(&w.metadata) && w.target.valid()) {
                    unsafe { PostMessageW(Some(HWND(window.target.hwnd as *mut _)), WM_CLOSE, WPARAM(0), LPARAM(0)).map_err(error)?; }
                    count += 1;
                }
                Ok(json!({"closeRequested":count}))
            }
            "snapshot" => {
                self.snapshot(outbox);
                Ok(json!({}))
            }
            "desktop_clipboard" => {
                let foreground=unsafe {GetForegroundWindow()}.0 as usize;
                match value["action"].as_str().unwrap_or("") {
                    "prepare" => Ok(json!({"sequence":clipboard::sequence(),"foreground":foreground})),
                    "write" => {
                        clipboard::write(value["text"].as_str().ok_or("Missing clipboard text")?)?;
                        Ok(json!({}))
                    },
                    "read" => {
                        let expected=value["foreground"].as_u64().ok_or("Missing clipboard focus")? as usize;
                        if foreground==0 || foreground!=expected {return Err("Clipboard focus changed".into());}
                        let previous=value["sequence"].as_u64().ok_or("Missing clipboard sequence")? as u32;
                        let text=clipboard::read_after(previous)?;
                        if unsafe {GetForegroundWindow()}.0 as usize!=expected {return Err("Clipboard focus changed".into());}
                        Ok(json!({"text":text}))
                    },
                    _ => Err("Unsupported clipboard action".into()),
                }
            }
            "release" => {
                self.release();
                Ok(json!({}))
            }
            "input" | "clipboard" | "activate" | "resize" | "close" | "hit_test" | "geometry" | "set_geometry"
            | "cancel_interaction" | "device_focus_state" => {
                let id = value["window"].as_str().ok_or("Missing window identity")?;
                let window = self.windows.get(id).ok_or("Window retired")?;
                if !window.target.valid() {
                    return Err("Window retired".into());
                }
                let target = window.target.clone();
                match value["operation"].as_str().unwrap() {
                    "device_focus_state" => unsafe {
                        let hwnd=HWND(target.hwnd as _);
                        if !window.mac_owned || catalogue::transient(&window.metadata)
                            || !window_control::native_app_input_allowed(hwnd)
                            || !IsWindowVisible(hwnd).as_bool() || !IsWindowEnabled(hwnd).as_bool()
                            || IsIconic(hwnd).as_bool() {
                            return Err("This window is not available for device focus".into());
                        }
                        let foreground=GetAncestor(GetForegroundWindow(),GA_ROOT);
                        let mut gui=GUITHREADINFO{cbSize:size_of::<GUITHREADINFO>() as u32,..Default::default()};
                        GetGUIThreadInfo(0,&mut gui).map_err(error)?;
                        // Menus, a held pointer and move/resize loops belong
                        // to the user's current interaction, never cycle them.
                        if foreground.is_invalid() || !gui.hwndCapture.is_invalid()
                            || gui.flags.0 & 0x1e != 0 {
                            return Err("Finish the current Windows interaction before switching apps".into());
                        }
                        return Ok(json!({"focused":foreground==hwnd,"foreground":foreground.0 as usize}));
                    },
                    "input" | "clipboard" => {
                        let root = self.input_root(window);
                        let root_hwnd = root.target.hwnd;
                        let root_id = root.target.id.clone();
                        let related: Vec<usize> = self
                            .windows
                            .values()
                            .filter(|w| self.input_root(w).target.id == root_id)
                            .map(|w| w.target.hwnd)
                            .collect();
                        if value["operation"]=="clipboard" {
                            let action=value["action"].as_str().ok_or("Missing clipboard action")?;
                            let key=match action {"copy"=>0x43,"cut"=>0x58,"paste"=>0x56,_=>return Err("Unsupported clipboard action".into())};
                            if !unsafe {IsWindowEnabled(HWND(target.hwnd as *mut _)).as_bool()} {return Err("This app is waiting for a dialog".into());}
                            activate_surface(root)?;
                            self.release();
                            let sequence=clipboard::sequence();
                            if action=="paste" {clipboard::write(value["text"].as_str().ok_or("Missing clipboard text")?)?;}
                            self.input(&target,root_hwnd,&related,&json!({"event":"chord","keys":[0x11,key]}))?;
                            if action!="paste" {
                                let text=clipboard::read_after(sequence)?;
                                if !target.valid() || !related.contains(&(unsafe {GetAncestor(GetForegroundWindow(), GA_ROOT)}.0 as usize)) {return Err("Clipboard focus changed".into());}
                                return Ok(json!({"text":text}));
                            }
                        }else{self.input(&target, root_hwnd, &related, value)?;}
                    }
                    "activate" => {
                        let active = self.activation_window(window)?;
                        unsafe {
                            let _ = ShowWindow(HWND(active.target.hwnd as *mut _), SW_RESTORE);
                            activate_surface(active)?;
                        }
                        if active.target.id != target.id {
                            outbox.control(json!({"type":"activate","window":active.target.id}));
                        }
                    }
                    "resize" => {
                        self.release();
                        return window_control::resize(&target, value);
                    }
                    "set_geometry" => {
                        self.release();
                        return window_control::set_geometry(&target, value);
                    }
                    "hit_test" => return window_control::hit_test(&target, value),
                    "geometry" => {
                        let mut state = window_control::state(&target)?;
                        state["capturePhase"] = json!(target.capture_phase_name());
                        state["captureFrames"] = json!(target.capture_frames.load(Ordering::Acquire));
                        state["captureProgress"] = target.progress.snapshot();
                        state["captureDevice"] = json!(*target.capture_device.lock().unwrap());
                        state["captureStopped"] = json!(window.stop.as_ref()
                            .map(|stop| stop.load(Ordering::Acquire)).unwrap_or(true));
                        state["macOwned"] = json!(window.mac_owned);
                        let popup_isolated=window.mac_owned && catalogue::transient(&window.metadata)
                            && window_control::native_app_input_allowed(HWND(target.hwnd as _));
                        state["guestCloaked"] = json!(window.cloak.as_ref().is_some_and(|s|s.active() && !s.native_input()));
                        state["guestIsolated"] = json!(popup_isolated || window.cloak.as_ref().is_some_and(cloak::Window::active));
                        state["guestIsolation"] = json!(if popup_isolated || window.cloak.as_ref().is_some_and(cloak::Window::native_input){"app-display"}else{"dwm"});
                        state["isolationAttempts"]=json!(window.isolation_attempts);
                        state["guestIsolationBackend"]=json!(if popup_isolated{"app-display-inherited"}else if window.cloak.as_ref().is_some_and(cloak::Window::uses_display_api){"app-display-api"}else{"in-process"});
                        state["cloakError"] = json!(window.cloak_error);
                        return Ok(state);
                    }
                    "cancel_interaction" => {
                        self.release();
                        window_control::cancel(HWND(target.hwnd as *mut _));
                    }
                    "close" => unsafe {
                        if catalogue::window_class(target.hwnd)=="ConsoleWindowClass" {
                            // Console windows do not pump a normal client UI
                            // queue. Use the system close command with a bound.
                            self.release();
                            if SendMessageTimeoutW(HWND(target.hwnd as _),WM_SYSCOMMAND,WPARAM(SC_CLOSE as usize),LPARAM(0),
                                SMTO_ABORTIFHUNG | SMTO_BLOCK,500,None).0==0 {
                                return Err("Windows did not confirm the console close request".into());
                            }
                        }else if let Err(cause)=PostMessageW(
                            Some(HWND(target.hwnd as *mut _)),
                            WM_CLOSE,
                            WPARAM(0),
                            LPARAM(0),
                        ) {
                            // A medium-integrity SendInput can return success
                            // without controlling an elevated foreground app.
                            // Ask the host for one ordinary device Alt+F4;
                            // never activate a different window or force exit.
                            if cause.code().0 as u32 != 0x80070005
                                || !window_control::native_app_input_allowed(HWND(target.hwnd as _))
                                || !IsWindowEnabled(HWND(target.hwnd as _)).as_bool()
                                || GetAncestor(GetForegroundWindow(),GA_ROOT).0 as usize != target.hwnd {
                                return Err(error(cause));
                            }
                            log(format!("Close message denied; requesting foreground device shortcut hwnd={}",target.hwnd));
                            return Ok(json!({"accepted":false,"method":"device-keyboard"}));
                        }
                    },
                    _ => {}
                }
                Ok(json!({"accepted":true}))
            }
            _ => Err("Unsupported operation".into()),
        }
    }

    fn document_count(&self) -> usize {
        self.windows
            .values()
            .filter(|w| !catalogue::transient(&w.metadata))
            .count()
    }

    fn activation_window<'a>(&'a self, window: &'a Window) -> Result<&'a Window, String> {
        if !window.target.valid() { return Err("Window retired".into()); }
        unsafe {
            let requested = HWND(window.target.hwnd as *mut _);
            let root_hwnd = GetAncestor(requested, GA_ROOTOWNER);
            let root = self.windows.values().find(|candidate| candidate.app == window.app
                && candidate.target.hwnd == root_hwnd.0 as usize && candidate.target.valid()).unwrap_or(window);
            let root_hwnd = HWND(root.target.hwnd as *mut _);
            if !IsWindowEnabled(requested).as_bool() || !IsWindowEnabled(root_hwnd).as_bool() {
                let mut popup = GetLastActivePopup(root_hwnd);
                let mut active = None;
                for _ in 0..12 {
                    if popup.is_invalid() || popup == root_hwnd { break; }
                    if let Some(candidate) = self.windows.values().find(|candidate| {
                        candidate.app == window.app && candidate.target.hwnd == popup.0 as usize
                            && candidate.metadata["role"] == "dialog" && candidate.target.valid()
                    }) {
                        if GetAncestor(popup, GA_ROOTOWNER) == root_hwnd
                            && IsWindowEnabled(popup).as_bool() && IsWindowVisible(popup).as_bool()
                        {
                            active = Some(candidate);
                        }
                    }
                    let next = GetLastActivePopup(popup);
                    if next == popup { break; }
                    popup = next;
                }
                if let Some(active) = active {
                    if root.target.valid() && active.target.valid()
                        && IsWindowEnabled(HWND(active.target.hwnd as *mut _)).as_bool()
                    {
                        return Ok(active);
                    }
                }
            }
            if !window.target.valid() { return Err("Window retired".into()); }
            if !IsWindowEnabled(requested).as_bool() {
                return Err("This app is waiting for a dialog".into());
            }
            Ok(window)
        }
    }

    fn input_root<'a>(&'a self, mut window: &'a Window) -> &'a Window {
        for _ in 0..12 {
            if !catalogue::transient(&window.metadata) {
                break;
            }
            let Some(parent) = window.parent.as_ref().and_then(|id| self.windows.get(id)) else {
                break;
            };
            window = parent;
        }
        window
    }

    fn parent_for(&self, metadata: &Value, app: &str) -> Option<String> {
        let mut owner = metadata["owner"].as_u64().unwrap_or(0) as usize;
        for _ in 0..12 {
            if owner == 0 {
                break;
            }
            if let Some(window) = self.windows.values().find(|w| w.target.hwnd == owner) {
                return Some(window.target.id.clone());
            }
            owner = unsafe {
                GetWindow(HWND(owner as *mut _), GW_OWNER)
                    .unwrap_or_default()
                    .0 as usize
            };
        }
        if !catalogue::transient(metadata) && metadata["role"] != "dialog" {
            return None;
        }
        let foreground = catalogue::foreground();
        // Chromium can use unowned popup HWNDs. Prefer the active app window, then
        // the closest document of that process; never promote an unassociated popup.
        self.windows
            .values()
            .filter(|w| {
                w.app == app
                    && w.metadata["hwnd"] != metadata["hwnd"]
                    && !catalogue::transient(&w.metadata)
                    && w.metadata["pid"] == metadata["pid"]
            })
            .min_by_key(|w| {
                let dx =
                    w.metadata["x"].as_i64().unwrap_or(0) - metadata["x"].as_i64().unwrap_or(0);
                let dy =
                    w.metadata["y"].as_i64().unwrap_or(0) - metadata["y"].as_i64().unwrap_or(0);
                (w.target.hwnd != foreground, dx * dx + dy * dy)
            })
            .map(|w| w.target.id.clone())
    }

    fn remember_process(&mut self, app: &str, pid: u32, creation: u64) {
        if !self.applications.contains_key(app) && self.applications.len() >= 8 { return; }
        let session = self.applications.entry(app.into()).or_insert_with(|| ApplicationSession {
            processes: Vec::new(), gap_until: None, startup_until: Instant::now(), activation: None,
            baseline:HashSet::new(),
        });
        if session.processes.len() >= 16 || session.processes.iter().any(|p| p.identity.pid == pid && p.identity.creation == creation) { return; }
        if let Some(process) = app_process::Process::open(pid, &self.sid, self.session)
            .filter(|p| p.identity.creation == creation) {
            session.processes.push(process);
        }
    }
    fn finish_activations(&mut self, outbox: &Outbox) {
        let mut changed = false;
        while let Ok(result) = self.activation_results.try_recv() {
            if !self.applications.get(&result.app).is_some_and(|session| session.activation == Some(result.nonce)) {
                continue;
            }
            changed = true;
            self.applications.get_mut(&result.app).unwrap().activation = None;
            match result.result {
                Ok((pid, creation)) => {
                    self.remember_process(&result.app, pid, creation);
                    let has_window = self.windows.values().any(|w| w.app == result.app && !catalogue::transient(&w.metadata));
                    let session = self.applications.get_mut(&result.app).unwrap();
                    if !has_window { session.gap_until = Some(Instant::now() + Duration::from_secs(30)); }
                    log(format!("Application activation completed app={} nonce={} pid={pid} creation={creation} verified={}",
                        result.app, result.nonce, session.processes.iter().any(|p| p.identity.pid == pid && p.identity.creation == creation)));
                    self.next_process_scan = Instant::now();
                }
                Err(message) => {
                    log(format!("Application activation failed app={} nonce={} error={message}", result.app, result.nonce));
                    self.pending.retain(|pending| pending.app != result.app);
                    let has_window = self.windows.values().any(|w| w.app == result.app);
                    if !has_window && self.applications[&result.app].processes.is_empty() {
                        self.applications.remove(&result.app);
                    }
                    outbox.control(json!({"type":"launch_error","app":result.app,
                        "message":format!("Impossibile avviare l’app: {message}")}));
                }
            }
        }
        if changed { self.save(); }
    }
    fn application_surface(&self, mut metadata: Value, app: &str) -> Value {
        // A frameless loading/main window can carry WS_POPUP without having
        // any owner. Only an already authenticated app may promote it, and
        // ordinary menus and popups belonging to a document stay transient.
        if metadata["role"] == "popup" && metadata["class"] != "#32768"
            && metadata["owner"].as_u64() == Some(0)
            && (self.windows.values().any(|w| w.app == app
                && w.metadata["hwnd"] == metadata["hwnd"] && w.metadata["role"] == "main")
                || (!self.windows.values().any(|w| w.metadata["hwnd"] == metadata["hwnd"])
                    && !self.windows.values().any(|w| w.app == app && !catalogue::transient(&w.metadata))))
        {
            metadata["role"] = json!("main");
        }
        metadata
    }
    fn application_for(&self, metadata: &Value) -> Option<String> {
        let pid = metadata["pid"].as_u64()? as u32;
        let creation = metadata["creation"].as_str()?.parse::<u64>().ok()?;
        let raw=metadata["hwnd"].as_u64()? as usize;
        let owner=metadata["owner"].as_u64().unwrap_or(0) as usize;
        if let Some(parent)=self.windows.values().find(|w|w.target.hwnd==owner && w.target.valid()) {
            return Some(parent.app.clone());
        }
        // An app identity or shared process alone never turns a window opened
        // inside Windows into a Mac-owned window. Only admit a fresh result of
        // an explicit launcher request, or a transient of the active Mac app.
        let launching=|app:&String|self.pending.iter().any(|p|p.app==*app && p.deadline>Instant::now())
            && !self.windows.values().any(|w|w.app==*app && !catalogue::transient(&w.metadata))
            && self.applications.get(app).is_some_and(|s|!s.baseline.contains(&raw));
        let transient_app=if catalogue::transient(metadata) {
            self.windows.values().find(|w|w.mac_owned && w.target.hwnd==catalogue::foreground()).map(|w|w.app.clone())
        } else {None};
        if metadata["class"] == "ApplicationFrameWindow" {
            let mut matches = self.applications.keys().filter(|app| {
                launching(app) && self.catalogue.hosted_content(app, raw, &self.sid, self.session).is_some()
            });
            let app = matches.next()?;
            return matches.next().is_none().then(|| app.clone());
        }
        if let Some(app) = self.applications.keys().find(|app| (launching(app) || transient_app.as_ref()==Some(app)) && self.catalogue.matches(app,
            metadata["hwnd"].as_u64().unwrap_or(0) as usize)) { return Some(app.clone()); }
        let mut candidates = self.applications.iter().filter(|(app, session)| {
            (launching(app) || transient_app.as_ref()==Some(app)) && session.processes.iter().any(|p| p.identity.pid == pid && p.identity.creation == creation)
        });
        let (app, _) = candidates.next()?;
        candidates.next().is_none().then(|| app.clone())
    }
    fn refresh_applications(&mut self) -> bool {
        let now = Instant::now();
        let visible_apps: HashSet<String> = self.windows.values().filter(|w| !catalogue::transient(&w.metadata))
            .map(|w| w.app.clone()).collect();
        let mut changed = false;
        for (app, session) in &mut self.applications {
            let before = session.processes.len();
            session.processes.retain(app_process::Process::alive);
            changed |= before != session.processes.len();
            if visible_apps.contains(app) {
                changed |= session.gap_until.take().is_some();
            } else if session.gap_until.is_none() || (before != 0 && session.processes.is_empty()) {
                session.gap_until = Some(now + Duration::from_secs(30)); changed = true;
                log(format!("Application window gap app={app} processes={}", session.processes.len()));
                // A missing Mac mirror can be a deliberate Desktop transfer
                // or a closed document. It must not create another launch.
            }
        }
        let before = self.applications.len();
        self.applications.retain(|_, session| session.activation.is_some() || !session.processes.is_empty()
            || session.gap_until.is_none_or(|until| until > now));
        changed |= before != self.applications.len();
        if self.applications.is_empty() || now < self.next_process_scan { return changed; }
        self.next_process_scan = now + Duration::from_millis(250);
        let table = app_process::snapshot();
        for (app, session) in &mut self.applications {
            if let Some(table) = &table {
                let children = app_process::descendants(table, &session.processes, &self.sid, self.session,
                    16usize.saturating_sub(session.processes.len()));
                for child in &children {
                    log(format!("Application descendant app={app} pid={} creation={}", child.identity.pid, child.identity.creation));
                }
                changed |= !children.is_empty(); session.processes.extend(children);
            }
        }
        changed
    }
    fn observe(&mut self, outbox: &Arc<Outbox>) {
        self.finish_activations(outbox);
        // Desktop-only windows cannot become Mac-owned without a launcher
        // request. Retain process lifecycle bookkeeping, but do not inspect
        // every unrelated window (and open its process) in the background.
        if self.windows.is_empty() && self.pending.is_empty() {
            if self.refresh_applications() {self.snapshot(outbox);self.save();}
            return;
        }
        let visible = catalogue::windows();
        let mut changed = false;
        let retired: Vec<String> = self
            .windows
            .iter()
            .filter(|(_, w)| {
                !w.target.valid() || catalogue::shell_surface(w.target.hwnd)
                    || (catalogue::transient(&w.metadata)
                        && (!visible.contains(&w.target.hwnd)
                            || w.parent
                                .as_ref()
                                .is_none_or(|p| !self.windows.contains_key(p))))
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in retired {
            changed |= self.retire_window(&id, outbox);
        }
        changed |= self.refresh_applications();
        let known: HashSet<usize> = self.windows.values().map(|w| w.target.hwnd).collect();
        // Owners precede their transient children even though EnumWindows is front-to-back.
        for raw in visible.iter().rev().copied() {
            if known.contains(&raw) || (self.windows.len() >= 16
                && catalogue::window_class(raw) != "ApplicationFrameWindow") {
                continue;
            }
            if let Some(details) = catalogue::details(raw, &self.sid, self.session) {
                if let Some(app) = self.application_for(&details) {
                    changed |= self.add(raw, app, outbox);
                }
            }
        }
        let pending = std::mem::take(&mut self.pending);
        for launch in pending {
            if self.windows.values().any(|w| w.app == launch.app && !catalogue::transient(&w.metadata)) { continue; }
            if Instant::now() < launch.deadline { self.pending.push(launch); }
            else {
                let still_running = self.applications.get(&launch.app).is_some_and(|session| {
                    session.activation.is_some() || session.processes.iter().any(app_process::Process::alive)
                });
                log(format!("Application launch wait exceeded app={} stillRunning={still_running}", launch.app));
                // One bounded diagnostic at failure, omitting window titles and
                // paths. It also exposes a successor we could not authenticate.
                for raw in visible.iter().take(64) {
                    if let Some(details) = catalogue::details(*raw, &self.sid, self.session) {
                        log(format!("Launch candidate hwnd={raw} pid={} creation={} class={} role={} owner={} style={} exStyle={}",
                            details["pid"], details["creation"], details["class"], details["role"],
                            details["owner"], details["style"], details["exStyle"]));
                    }
                }
                let message = if still_running {
                    "L’app è ancora in avvio. La finestra apparirà appena disponibile; puoi aprire Windows per seguirla."
                } else {
                    "L’app non ha ancora mostrato una finestra riconoscibile. Puoi continuare dal desktop Windows."
                };
                outbox.control(json!({"type":"launch_error","app":launch.app,"message":message}));
            }
        }
        let updated: Vec<_> = self.windows.iter().filter_map(|(id, window)| {
            let details = catalogue::details(window.target.hwnd, &self.sid, self.session)?;
            Some((id.clone(), self.application_surface(details, &window.app)))
        }).collect();
        let refresh_minimum = Instant::now() >= self.next_minimum_scan;
        if refresh_minimum { self.next_minimum_scan = Instant::now() + Duration::from_secs(2); }
        for (id, mut details) in updated {
            if let Some(window) = self.windows.get_mut(&id) {
                let app_display=window_control::native_app_input_allowed(HWND(window.target.hwnd as _));
                let transient=catalogue::transient(&details);
                if window.mac_owned && !transient && window.cloak.is_none()
                    && window.isolation_attempts<3 && Instant::now()>=window.isolation_retry_after
                    && (!window_control::native_app_input_configured()
                        || app_display)
                    && window.target.capture_frames.load(Ordering::Acquire)>0
                    && window.stop.as_ref().is_some_and(|stop|!stop.load(Ordering::Acquire)) {
                    window.isolation_attempts+=1;
                    window.isolation_retry_after=Instant::now()+Duration::from_secs(1);
                    match cloak::Window::new(window.target.clone()).and_then(|mut scope|{scope.hide()?;Ok(scope)}) {
                        Ok(scope)=>{window.cloak=Some(scope);window.cloak_error=None;changed=true;}
                        Err(message)=>{
                            log(format!("Window isolation unavailable hwnd={}: {message}",window.target.hwnd));
                            window.cloak_error=Some(message);changed=true;
                        }
                    }
                }
                let mut cloaked=window.cloak.as_ref().is_some_and(cloak::Window::active);
                if cloaked && window.stop.as_ref().is_none_or(|stop|stop.load(Ordering::Acquire)) {
                    let since=window.capture_unavailable_since.get_or_insert_with(Instant::now);
                    // Resize restarts WGC deliberately; retain isolation while it reconnects.
                    if since.elapsed()>Duration::from_secs(3) {
                        window.cloak.take();window.cloak_error=Some("Capture stopped; restored in Windows".into());cloaked=false;
                    }
                }else {window.capture_unavailable_since=None;}
                if let Some(scope)=&mut window.cloak {
                    let native=window_control::native_app_input_allowed(HWND(window.target.hwnd as _));
                    if let Err(message)=scope.set_native_input(native) {
                        window.cloak_error=Some(message);scope.show();cloaked=false;
                    }else {cloaked=scope.active();}
                    if let Err(message)=scope.touch() {
                        window.cloak_error=Some(message);scope.show();cloaked=false;
                    }
                }
                if window.cloak.is_some() && !cloaked {
                    window.cloak.take();window.cloak_error=Some("Window isolation expired; restored in Windows".into());
                    window.isolation_retry_after=Instant::now()+Duration::from_secs(1);
                }
                // Popup menus have no taskbar button and remain on their
                // authenticated app's reserved display. Never inject/cloak
                // their system menu-loop windows independently of the owner.
                let popup_isolated=window.mac_owned && transient && app_display;
                details["guestCloaked"]=json!(cloaked && !window.cloak.as_ref().is_some_and(cloak::Window::native_input));
                details["guestIsolated"]=json!(cloaked || popup_isolated);
                details["guestIsolation"]=json!(if popup_isolated || window.cloak.as_ref().is_some_and(cloak::Window::native_input){"app-display"}else{"dwm"});
                details["guestIsolationBackend"]=json!(if popup_isolated{"app-display-inherited"}else if window.cloak.as_ref().is_some_and(cloak::Window::uses_display_api){"app-display-api"}else{"in-process"});
                details["macOwned"]=json!(window.mac_owned);
                details["cloakError"]=json!(window.cloak_error);
                // DWM visibility and presentation of a Mac-owned window are
                // separate. Never suppress our host window because we cloaked it.
                if cloaked {details["visible"]=json!(unsafe{IsWindowVisible(HWND(window.target.hwnd as *mut _)).as_bool()});}
                if refresh_minimum { window_control::describe_minimum(&mut details); }
                else {
                    details["minWidth"] = window.metadata["minWidth"].clone();
                    details["minHeight"] = window.metadata["minHeight"].clone();
                }
                details["z"] = json!(
                    visible
                        .iter()
                        .position(|raw| *raw == window.target.hwnd)
                        .unwrap_or(1024)
                );
                if details != window.metadata {
                    window.metadata = details;
                    changed = true;
                }
            }
        }
        if changed {
            self.snapshot(outbox);
            self.save();
        }
    }

    fn retire_window(&mut self, id: &str, outbox: &Outbox) -> bool {
        let Some(mut window) = self.windows.remove(id) else { return false; };
        log(format!("Application window retired app={} hwnd={} pid={} creation={} class={} role={}", window.app, window.target.hwnd,
            window.target.pid, window.target.creation, window.metadata["class"], window.metadata["role"]));
        if let Some(stop) = window.stop.take() { stop.store(true, Ordering::Release); }
        outbox.retire(id);
        true
    }

    fn add(&mut self, raw: usize, app: String, outbox: &Arc<Outbox>) -> bool {
        if catalogue::shell_surface(raw) {return false;}
        let raw = catalogue::host_frame(raw, &self.sid, self.session).unwrap_or(raw);
        let Some(metadata) = catalogue::details(raw, &self.sid, self.session) else {
            return false;
        };
        let owner=metadata["owner"].as_u64().unwrap_or(0) as usize;
        // DWM also cloaks owned dialogs when their Mac parent is cloaked.
        // Admit that exact authenticated owner chain, not arbitrary hidden apps.
        let mac_child=self.windows.values().any(|w|w.mac_owned && w.target.hwnd==owner && w.target.valid());
        if metadata["cloaked"] == true && !mac_child { return false; }
        let hosted = if metadata["class"] == "ApplicationFrameWindow" {
            let Some(content) = self.catalogue.hosted_content(&app, raw, &self.sid, self.session) else { return false; };
            Some(content)
        } else { None };
        let mut changed = false;
        if let Some(content) = &hosted {
            // Reparenting can happen after observe's initial retirement pass.
            // Retire only this exact old CoreWindow before counting documents.
            let old: Vec<_> = self.windows.iter().filter(|(_, window)| {
                window.target.hwnd == content.hwnd && window.target.hosted.is_none()
                    && ((window.target.pid == content.pid && window.target.creation == content.creation)
                        || !window.target.valid())
            }).map(|(id, _)| id.clone()).collect();
            for id in old { changed |= self.retire_window(&id, outbox); }
        }
        if self.windows.values().any(|w| w.target.hwnd == raw) || self.windows.len() >= 16 {
            return changed;
        }
        let mut metadata = self.application_surface(metadata, &app);
        let transient = catalogue::transient(&metadata);
        if !transient && self.document_count() >= 4 {
            return changed;
        }
        if transient
            && self
                .windows
                .values()
                .filter(|w| catalogue::transient(&w.metadata))
                .count()
                >= 12
        {
            return changed;
        }
        let parent = self.parent_for(&metadata, &app);
        if transient && parent.is_none() {
            return changed;
        }
        let Some((pid, creation)) = identity::owner(HWND(raw as *mut _), &self.sid, self.session)
        else {
            return changed;
        };
        window_control::describe_minimum(&mut metadata);
        let first_document = !transient && !self.windows.values().any(|w| w.app == app && !catalogue::transient(&w.metadata));
        if let Some(content) = &hosted {
            self.remember_process(&app, content.pid, content.creation);
            log(format!("Application frame identity app={app} frame={raw} hostPid={pid} child={} pid={} creation={} appId={}",
                content.hwnd, content.pid, content.creation, content.app_id));
        }
        else { self.remember_process(&app, pid, creation); }
        if !transient {
            if let Some(session) = self.applications.get_mut(&app) {
                session.gap_until = None;session.startup_until=Instant::now();
            }
        }
        self.serial += 1;
        let id = format!("{}:{}", self.epoch, self.serial);
        let target = Arc::new(Target {
            id: id.clone(),
            hwnd: raw,
            pid,
            creation,
            sid: self.sid.clone(),
            session: self.session,
            full_frame: metadata["role"] != "dialog",
            hosted,
            item_creation: Arc::new(Mutex::new(())),
            capture_phase: AtomicU8::new(capture::Phase::Starting as u8),
            capture_frames: AtomicU64::new(0),
            progress: Arc::new(capture::Progress::default()),
            capture_device: Mutex::new(None),
            readback_device_lost: AtomicBool::new(false),
            refresh_requested: AtomicBool::new(false),
            geometry: Mutex::new((0, 0, 0, 0, 0)),
        });
        let stop = Some(capture::spawn(target.clone(), outbox.clone()));
        log(format!("Application window app={app} hwnd={raw} pid={pid} creation={creation} class={} role={} owner={} style={} exStyle={}",
            metadata["class"], metadata["role"], metadata["owner"], metadata["style"], metadata["exStyle"]));
        if first_document {
            outbox.control(json!({"type":"launch_state","app":app,"state":"window_available","window":id}));
        }
        self.windows.insert(
            id,
            Window {
                target,
                app,
                metadata,
                parent,
                stop,
                mac_owned:true,
                cloak:None,
                cloak_error:None,
                isolation_attempts:0,isolation_retry_after:Instant::now(),
                    capture_unavailable_since:None,
            },
        );
        true
    }
    fn application_status(&self) -> Value {
        let mut apps = Vec::new();
        for (app, session) in &self.applications {
            let windows: Vec<Value> = self.windows.values().filter(|w| w.app == *app && !catalogue::transient(&w.metadata)).map(|w| {
                json!({"id":w.target.id,"captureFrames":w.target.capture_frames.load(Ordering::Acquire),
                    "capturePhase":w.target.capture_phase_name(),
                    "captureStopped":w.stop.as_ref().is_none_or(|s| s.load(Ordering::Acquire))})
            }).collect();
            let processes: Vec<Value> = session.processes.iter().filter(|p| p.alive()).map(|p|
                json!({"pid":p.identity.pid,"creation":p.identity.creation.to_string(),"name":p.name()})).collect();
            apps.push(json!({"app":app,"activationPending":session.activation.is_some(),"processes":processes,"windows":windows}));
        }
        json!({"epoch":self.epoch,"applications":apps})
    }
    fn snapshot(&self, outbox: &Outbox) {
        let windows:Vec<Value>=self.windows.values().map(|w|{
            json!({"id":w.target.id,"app":w.app,"title":w.metadata["title"],"width":w.metadata["width"],"height":w.metadata["height"],
                "parent":w.parent,"role":w.metadata["role"],"x":w.metadata["x"],"y":w.metadata["y"],
                "z":w.metadata["z"],"visible":w.metadata["visible"],"minimized":w.metadata["minimized"],
                "class":w.metadata["class"],"style":w.metadata["style"],"exStyle":w.metadata["exStyle"],
                "macOwned":w.mac_owned,"guestCloaked":w.metadata["guestCloaked"],
                "guestIsolated":w.metadata["guestIsolated"],"guestIsolation":w.metadata["guestIsolation"],
                "guestIsolationBackend":w.metadata["guestIsolationBackend"],"cloakError":w.cloak_error,
                "maxWidth":w.metadata["maxWidth"],"maxHeight":w.metadata["maxHeight"],
                "minWidth":w.metadata["minWidth"],"minHeight":w.metadata["minHeight"],"resizable":w.metadata["resizable"]})
        }).collect();
        outbox.control(json!({"type":"windows","windows":windows,"epoch":self.epoch}));
    }
    fn save(&self) {
        let mut values:Vec<Value>=self.windows.values().filter(|w| !catalogue::transient(&w.metadata)).map(|w|json!({"hwnd":w.target.hwnd,"pid":w.target.pid,"creation":w.target.creation.to_string(),"app":w.app,"hosted":w.target.hosted,"macOwned":w.mac_owned})).collect();
        let now = Instant::now();
        let unix = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        for (app, session) in &self.applications {
            let remaining = |until:Instant| until.saturating_duration_since(now).as_millis().min(30_000) as u64;
            values.push(json!({"type":"application","app":app,
                "gapUntil":session.gap_until.map(|until| unix+remaining(until)),
                "startupUntil":unix+remaining(session.startup_until),
                "processes":session.processes.iter().map(|p| json!({"pid":p.identity.pid,"creation":p.identity.creation.to_string()})).collect::<Vec<_>>()}));
        }
        let path = state_path();
        let _ = std::fs::create_dir_all(path.parent().unwrap());
        if let Ok(bytes) = serde_json::to_vec(&values) {
            let _ = std::fs::write(path, bytes);
        }
    }
    fn restore(&mut self) {
        let Some(values) = std::fs::read(state_path())
            .ok()
            .and_then(|v| serde_json::from_slice::<Vec<Value>>(&v).ok())
        else {
            return;
        };
        let now = Instant::now();
        let unix = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        for value in values.iter().filter(|value| value["type"] == "application").take(8) {
            let Some(app) = value["app"].as_str().filter(|v| v.len() == 64) else { continue; };
            let gap = value["gapUntil"].as_u64().unwrap_or(unix+30_000);
            let mut processes = Vec::new();
            if let Some(saved) = value["processes"].as_array() {
                for candidate in saved.iter().take(16) {
                    let Some(pid) = candidate["pid"].as_u64().and_then(|p| u32::try_from(p).ok()) else { continue; };
                    let Some(creation) = candidate["creation"].as_str().and_then(|s| s.parse::<u64>().ok()) else { continue; };
                    if let Some(process) = app_process::Process::open(pid, &self.sid, self.session)
                        .filter(|p| p.identity.creation == creation) { processes.push(process); }
                }
            }
            if processes.is_empty() { continue; }
            let startup = value["startupUntil"].as_u64().unwrap_or(unix).saturating_sub(unix).min(30_000);
            self.applications.insert(app.into(), ApplicationSession { processes,
                gap_until:Some(now+Duration::from_millis(gap.saturating_sub(unix).min(30_000))),
                startup_until:now+Duration::from_millis(startup), activation: None,baseline:HashSet::new() });
        }
        for value in values.into_iter().filter(|value| value["hwnd"].as_u64().is_some()).take(4) {
            let Some(raw) = value["hwnd"].as_u64() else {
                continue;
            };
            if identity::owner(HWND(raw as *mut _), &self.sid, self.session)
                != Some((
                    value["pid"].as_u64().unwrap_or(0) as u32,
                    value["creation"]
                        .as_str()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0),
                ))
            {
                continue;
            }
            let app = value["app"].as_str().unwrap_or_default().to_string();
            let Some(metadata) = catalogue::details(raw as usize, &self.sid, self.session) else {
                continue;
            };
            if metadata["cloaked"] == true || catalogue::shell_surface(raw as usize)
                || catalogue::host_frame(raw as usize, &self.sid, self.session).is_some() { continue; }
            let hosted = if metadata["class"] == "ApplicationFrameWindow" {
                let Ok(content) = serde_json::from_value::<catalogue::HostedContent>(value["hosted"].clone()) else { continue; };
                if !content.valid(raw as usize, &self.sid, self.session) || !content.matches_app()
                    || !self.catalogue.matches(&app, content.hwnd) { continue; }
                Some(content)
            } else { None };
            let metadata = self.application_surface(metadata, &app);
            if catalogue::transient(&metadata) {
                continue;
            }
            let pid = value["pid"].as_u64().unwrap_or(0) as u32;
            let creation = value["creation"].as_str().unwrap_or_default().parse().unwrap_or(0);
            if let Some(content) = &hosted { self.remember_process(&app, content.pid, content.creation); }
            else { self.remember_process(&app, pid, creation); }
            if let Some(session) = self.applications.get_mut(&app) { session.gap_until = None; }
            self.serial += 1;
            let id = format!("{}:{}", self.epoch, self.serial);
            let target = Arc::new(Target {
                id: id.clone(),
                hwnd: raw as usize,
                pid: value["pid"].as_u64().unwrap() as u32,
                creation: value["creation"].as_str().unwrap().parse().unwrap(),
                sid: self.sid.clone(),
                session: self.session,
                full_frame: metadata["role"] != "dialog",
                hosted,
                item_creation: Arc::new(Mutex::new(())),
                capture_phase: AtomicU8::new(capture::Phase::Starting as u8),
                capture_frames: AtomicU64::new(0),
                progress: Arc::new(capture::Progress::default()),
                capture_device: Mutex::new(None),
            readback_device_lost: AtomicBool::new(false),
                refresh_requested: AtomicBool::new(false),
                geometry: Mutex::new((0, 0, 0, 0, 0)),
            });
            self.windows.insert(
                id,
                Window {
                    target,
                    app,
                    metadata,
                    parent: None,
                    stop: None,
                    mac_owned:value["macOwned"]==true,
                    cloak:None,
                    cloak_error:None,
                    isolation_attempts:0,isolation_retry_after:Instant::now(),
                    capture_unavailable_since:None,
                },
            );
        }
        let parents: Vec<_> = self
            .windows
            .iter()
            .map(|(id, w)| (id.clone(), self.parent_for(&w.metadata, &w.app)))
            .collect();
        for (id, parent) in parents {
            self.windows.get_mut(&id).unwrap().parent = parent;
        }
    }

    fn input(
        &mut self,
        target: &Target,
        root: usize,
        related: &[usize],
        value: &Value,
    ) -> Result<(), String> {
        let kind=value["event"].as_str().ok_or("Missing input type")?;
        if let Some(scope)=self.windows.get_mut(&target.id).and_then(|w|w.cloak.as_mut()) {
            if scope.native_input() && !window_control::native_app_input_allowed(HWND(target.hwnd as _)) {
                scope.set_native_input(false)?;
                return Err("The app is leaving its reserved display".into());
            }
        }
        if self.windows.get(&target.id).is_some_and(|w|w.cloak.as_ref().is_some_and(|s|s.active() && !s.native_input())) {
            if kind=="leave" {return Ok(());}
            // DefWindowProc's Alt-F4/title-button tracking requires a visible
            // desktop hit target. Request the same authenticated system close.
            if kind=="chord" && value["keys"]==json!([0x12,0x73]) {
                if !target.valid(){return Err("Window retired".into());}
                self.release();
                unsafe {PostMessageW(Some(HWND(target.hwnd as _)),WM_CLOSE,WPARAM(0),LPARAM(0)).map_err(error)?;}
                return Ok(());
            }
            if matches!(kind,"pointer"|"button"|"scroll") {
                if !target.valid(){return Err("Window retired".into());}
                let (generation,width,height,ox,oy)=*target.geometry.lock().unwrap();
                if value["generation"].as_u64()!=Some(generation){return Err("Window geometry is updating".into());}
                let coordinate=|name:&str,max:i32|value[name].as_i64().filter(|v|*v>=0 && *v<i64::from(max)).map(|v|v as i32).ok_or("Pointer outside content");
                let mut point=POINT{x:coordinate("x",width)?+ox,y:coordinate("y",height)?+oy};
                unsafe {
                    if !IsWindowEnabled(HWND(target.hwnd as _)).as_bool(){return Err("This app is waiting for a dialog".into());}
                    if !ClientToScreen(HWND(target.hwnd as _),&mut point).as_bool(){return Err("Pointer transform unavailable".into());}

                }
                let window=self.windows.get_mut(&target.id).ok_or("Window retired")?;
                let result=window.cloak.as_mut().unwrap().pointer(kind,value["button"].as_str().unwrap_or("left"),value["down"]==true,
                    point.x,point.y,value["delta"].as_i64().unwrap_or(0).clamp(-2400,2400) as i32);
                if let Err(message)=result {
                    window.cloak.take();window.cloak_error=Some(message.clone());
                    log(format!("Restored guest visibility after input failure hwnd={}: {message}",target.hwnd));
                    return Err("L’app è tornata visibile in Windows. Ripeti il clic per continuare.".into());
                }
                return Ok(());
            }
        }
        unsafe {
            let hwnd = HWND(target.hwnd as *mut _);
            if !IsWindowEnabled(hwnd).as_bool() {
                return Err("This app is waiting for a dialog".into());
            }
            let kind = value["event"].as_str().ok_or("Missing input type")?;
            let foreground = GetAncestor(GetForegroundWindow(), GA_ROOT).0 as usize;
            let needs_focus = kind == "key" || kind == "text" || kind == "chord";
            if needs_focus && !related.contains(&foreground) {
                if let Some(scope)=self.windows.get(&target.id).and_then(|w|w.cloak.as_ref()) {scope.activate()?;}
                activate_window(HWND(root as *mut _))?;
            }
            if needs_focus
                && !related.contains(&(GetAncestor(GetForegroundWindow(), GA_ROOT).0 as usize))
            {
                return Err("Windows did not grant this window keyboard focus".into());
            }
            match kind {
                "leave" => {
                    // Move off the hovered control when the pointer leaves the Mac surfaces.
                    // Do not activate another HWND or cancel an open Windows menu.
                    if !related.contains(&(GetAncestor(GetForegroundWindow(), GA_ROOT).0 as usize))
                    {
                        return Ok(());
                    }
                    let bounds = catalogue::frame_bounds(HWND(root as *mut _))
                        .ok_or("Window geometry unavailable")?;
                    let left = GetSystemMetrics(SM_XVIRTUALSCREEN);
                    let top = GetSystemMetrics(SM_YVIRTUALSCREEN);
                    let width = GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1);
                    let height = GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1);
                    send(INPUT {
                        r#type: INPUT_MOUSE,
                        Anonymous: INPUT_0 {
                            mi: MOUSEINPUT {
                                dx: (bounds.left + 1 - left).clamp(0, width - 1) * 65535 / width,
                                dy: (bounds.top + 1 - top).clamp(0, height - 1) * 65535 / height,
                                dwFlags: MOUSEEVENTF_MOVE
                                    | MOUSEEVENTF_ABSOLUTE
                                    | MOUSEEVENTF_VIRTUALDESK,
                                ..Default::default()
                            },
                        },
                    })?;
                }
                "pointer" | "button" | "scroll" => {
                    let (generation, width, height, offset_x, offset_y) =
                        *target.geometry.lock().unwrap();
                    if value["generation"].as_u64() != Some(generation) {
                        return Err("Window geometry is updating".into());
                    }
                    let x = value["x"]
                        .as_i64()
                        .filter(|v| *v >= 0 && *v < i64::from(width))
                        .ok_or("Pointer outside content")? as i32;
                    let y = value["y"]
                        .as_i64()
                        .filter(|v| *v >= 0 && *v < i64::from(height))
                        .ok_or("Pointer outside content")? as i32;
                    let mut point = POINT {
                        x: x + offset_x,
                        y: y + offset_y,
                    };
                    if !ClientToScreen(hwnd, &mut point).as_bool() {
                        return Err("Pointer transform unavailable".into());
                    }
                    if kind == "button" && value["down"] == true {
                        if !target.valid() { return Err("Window retired".into()); }
                        // Let the user's real mouse-down grant activation. A
                        // foreground refusal must not prevent that first click,
                        // but an occluding/unregistered window must never get it.
                        let requested_root = GetAncestor(hwnd, GA_ROOT);
                        let hits_target = || {
                            let hit = GetAncestor(WindowFromPoint(point), GA_ROOT);
                            hit == requested_root && self.windows.values().any(|window| {
                                window.target.hwnd == hit.0 as usize && window.target.valid()
                            })
                        };
                        if !hits_target() {
                            SetWindowPos(hwnd, Some(HWND_TOP), 0, 0, 0, 0,
                                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS)
                                .map_err(error)?;
                            // The target thread applies the raise asynchronously.
                            // Give this first click a bounded chance to reach its
                            // own window, without waiting on a hung UI thread.
                            let deadline = Instant::now() + Duration::from_millis(60);
                            while !hits_target() && Instant::now() < deadline {
                                std::thread::sleep(Duration::from_millis(4));
                            }
                        }
                        if !hits_target() {
                            log(format!("Click blocked by occlusion hwnd={} x={} y={}", target.hwnd, point.x, point.y));
                            return Err("The click target is covered. Try again or use Windows.".into());
                        }
                        let mut gui = GUITHREADINFO { cbSize: size_of::<GUITHREADINFO>() as u32, ..Default::default() };
                        GetGUIThreadInfo(0, &mut gui).map_err(error)?;
                        let capture_root = GetAncestor(gui.hwndCapture, GA_ROOT);
                        // A classic menu runs inside its authenticated owner's
                        // menu loop: Windows keeps mouse capture on that owner,
                        // not the #32768 popup receiving this click.
                        let owner_menu_capture = catalogue::window_class(target.hwnd) == "#32768"
                            && capture_root.0 as usize == root
                            && GetAncestor(hwnd, GA_ROOTOWNER).0 as usize == root
                            && self.windows.values().any(|w| w.target.hwnd == root && w.target.valid());
                        if !gui.hwndCapture.is_invalid() && capture_root != requested_root && !owner_menu_capture {
                            return Err("Another window is capturing the mouse. Release it in Windows before clicking.".into());
                        }
                        let mut current = POINT { x: x + offset_x, y: y + offset_y };
                        if *target.geometry.lock().unwrap() != (generation, width, height, offset_x, offset_y)
                            || !ClientToScreen(hwnd, &mut current).as_bool()
                            || current.x != point.x || current.y != point.y
                        {
                            return Err("Window geometry is updating".into());
                        }
                        if !target.valid() { return Err("Window retired".into()); }
                        if !IsWindowEnabled(hwnd).as_bool() {
                            return Err("This app is waiting for a dialog".into());
                        }
                    }
                    let dx = ((point.x - GetSystemMetrics(SM_XVIRTUALSCREEN)) as i64 * 65535
                        / GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1) as i64)
                        as i32;
                    let dy = ((point.y - GetSystemMetrics(SM_YVIRTUALSCREEN)) as i64 * 65535
                        / GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1) as i64)
                        as i32;
                    let mut flags =
                        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
                    let mut data = 0;
                    if kind == "button" {
                        let button = value["button"].as_str().unwrap_or("left");
                        let down = value["down"].as_bool().ok_or("Invalid button state")?;
                        flags |= match (button, down) {
                            ("left", true) => MOUSEEVENTF_LEFTDOWN,
                            ("left", false) => MOUSEEVENTF_LEFTUP,
                            ("right", true) => MOUSEEVENTF_RIGHTDOWN,
                            ("right", false) => MOUSEEVENTF_RIGHTUP,
                            _ => return Err("Unsupported button".into()),
                        };
                    }
                    if kind == "scroll" {
                        flags |= MOUSEEVENTF_WHEEL;
                        data =
                            value["delta"].as_i64().unwrap_or(0).clamp(-2400, 2400) as i32 as u32;
                    }
                    send(INPUT {
                        r#type: INPUT_MOUSE,
                        Anonymous: INPUT_0 {
                            mi: MOUSEINPUT {
                                dx,
                                dy,
                                mouseData: data,
                                dwFlags: flags,
                                ..Default::default()
                            },
                        },
                    })?;
                    if kind == "button" {
                        self.buttons
                            .insert(value["button"].as_str().unwrap_or("left").into());
                    }
                }
                "text" => {
                    let text = value["text"]
                        .as_str()
                        .filter(|s| s.len() <= 1024)
                        .ok_or("Invalid input text")?;
                    if text.chars().any(|c|c=='\u{7f}' || (c.is_control() && !matches!(c,'\r'|'\n'|'\t'))) {return Err("Control characters must be sent as keys".into());}
                    let native_queue=self.windows.get(&target.id).and_then(|w|w.cloak.as_ref())
                        .is_some_and(cloak::Window::native_input);
                    if target.hosted.is_some() || native_queue {
                        if !target.valid() { return Err("Window retired".into()); }
                        if let Some(unit) = self.pending_unicode {
                            send(unicode_key(unit, true))?;
                            self.pending_unicode = None;
                        }
                        let units: Vec<u16> = text.encode_utf16().collect();
                        let inputs: Vec<INPUT> = units.iter().flat_map(|unit| {
                            [unicode_key(*unit, false), unicode_key(*unit, true)]
                        }).collect();
                        if inputs.is_empty() { return Ok(()); }
                        // Keep committed text behind shortcuts in the same
                        // Windows input queue. A synchronous WM_CHAR can
                        // overtake the key which is about to focus an editor.
                        let sent = SendInput(&inputs, size_of::<INPUT>() as i32) as usize;
                        if sent != inputs.len() {
                            // SendInput inserts in order. Only an odd accepted
                            // prefix can leave a Unicode key-down unmatched.
                            if sent % 2 != 0 {
                                let unit = units[sent / 2];
                                self.pending_unicode = Some(unit);
                                if send(unicode_key(unit, true)).is_ok() { self.pending_unicode = None; }
                            }
                            log(format!("Unicode input incomplete accepted={sent} total={} releasePending={}", inputs.len(), self.pending_unicode.is_some()));
                            return Err("Windows did not accept all of the text. The text was not retried.".into());
                        }
                        return Ok(());
                    }
                    let mut focus = GUITHREADINFO::default();
                    focus.cbSize = size_of::<GUITHREADINFO>() as u32;
                    GetGUIThreadInfo(0, &mut focus).map_err(error)?;
                    if focus.hwndFocus.is_invalid()
                        || !related.contains(&(GetAncestor(focus.hwndFocus, GA_ROOT).0 as usize))
                    {
                        return Err("This window has no focused text control".into());
                    }
                    // Text is already committed by macOS. Deliver UTF-16 character messages to
                    // the focused control; virtual-key injection remains reserved for shortcuts.
                    for unit in text.encode_utf16() {
                        if SendMessageTimeoutW(
                            focus.hwndFocus,
                            WM_CHAR,
                            WPARAM(unit as usize),
                            LPARAM(1),
                            SMTO_ABORTIFHUNG | SMTO_BLOCK,
                            500,
                            None,
                        )
                        .0 == 0
                        {
                            if GetLastError()==ERROR_ACCESS_DENIED {
                                return Err("Windows denied access to this app's text control".into());
                            }
                            return Err("The application did not accept text in time".into());
                        }
                    }
                }
                "chord" => {
                    let keys=value["keys"].as_array().filter(|k|!k.is_empty() && k.len()<=4).ok_or("Invalid shortcut")?;
                    let keys:Vec<u16>=keys.iter().map(|k|k.as_u64().filter(|k|*k>0 && *k<=255).map(|k|k as u16).ok_or("Invalid shortcut key")).collect::<Result<_,_>>()?;
                    self.release();
                    self.pressed.extend(keys.iter().copied());
                    let inputs:Vec<INPUT>=keys.iter().map(|k|keyboard(*k,false)).chain(keys.iter().rev().map(|k|keyboard(*k,true))).collect();
                    if SendInput(&inputs,size_of::<INPUT>() as i32) as usize != inputs.len() {self.release();return Err("Windows did not accept the shortcut".into());}
                    self.pressed.clear();
                    if target.hosted.is_none(){std::thread::sleep(Duration::from_millis(16));}
                }
                "key" => {
                    let key = value["key"]
                        .as_u64()
                        .filter(|v| *v > 0 && *v <= 255)
                        .ok_or("Invalid key")? as u16;
                    let down = value["down"].as_bool().ok_or("Invalid key state")?;
                    send(keyboard(key, !down))?;
                    if down {
                        self.pressed.insert(key);
                        // Hosted text and virtual keys both use the ordered
                        // SendInput queue. Keep the legacy Win32 pacing only:
                        // its synchronous WM_CHAR path is a separate mechanism.
                        if target.hosted.is_none() && ![0x10, 0x11, 0x12].contains(&key) {
                            std::thread::sleep(Duration::from_millis(16));
                        }
                    } else {
                        self.pressed.remove(&key);
                    }
                }
                _ => return Err("Unsupported input type".into()),
            }
            Ok(())
        }
    }
    fn release(&mut self) {
        for window in self.windows.values_mut(){if let Some(scope)=window.cloak.as_mut(){scope.cancel();}}
        for key in self.pressed.drain() {
            let _ = send(keyboard(key, true));
        }
        if let Some(unit) = self.pending_unicode {
            if send(unicode_key(unit, true)).is_ok() { self.pending_unicode = None; }
        }
        for button in ["left", "right"] {
            let _ = self.release_button(button);
        }
    }
    fn release_button(&mut self, button: &str) -> Result<(), String> {
        for window in self.windows.values_mut() {
            if let Some(scope)=window.cloak.as_mut() {
                if let Err(message)=scope.release(button) {
                    window.cloak.take();window.cloak_error=Some(message);
                }
            }
        }
        let (key, flag) = match button {
            "left" => (VK_LBUTTON, MOUSEEVENTF_LEFTUP),
            "right" => (VK_RBUTTON, MOUSEEVENTF_RIGHTUP),
            _ => return Err("Unsupported button".into()),
        };
        // A stray right-up on the caption opens its system menu. Only release a
        // tracked press or a button actually held (including after worker restart).
        if self.buttons.contains(button) || unsafe { GetAsyncKeyState(key.0 as i32) } < 0 {
            send(INPUT {
                r#type: INPUT_MOUSE,
                Anonymous: INPUT_0 {
                    mi: MOUSEINPUT {
                        dwFlags: flag,
                        ..Default::default()
                    },
                },
            })?;
        }
        self.buttons.remove(button);
        Ok(())
    }
}
fn keyboard(key: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(key),
                dwFlags: (if up {
                    KEYEVENTF_KEYUP
                } else {
                    KEYBD_EVENT_FLAGS(0)
                }) | if (0x21..=0x28).contains(&key) || key==0x2d || key==0x2e {KEYEVENTF_EXTENDEDKEY} else {KEYBD_EVENT_FLAGS(0)},
                ..Default::default()
            },
        },
    }
}
fn unicode_key(unit: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(0),
                wScan: unit,
                dwFlags: KEYEVENTF_UNICODE | if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) },
                ..Default::default()
            },
        },
    }
}
fn send(input: INPUT) -> Result<(), String> {
    if unsafe { SendInput(&[input], size_of::<INPUT>() as i32) } == 1 {
        Ok(())
    } else {
        Err("Windows rejected the input event".into())
    }
}

fn diagnostics() -> Result<Value, String> {
    use std::io::Read;
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    let mut child = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            include_str!("../../diagnostics.ps1"),
        ])
        .creation_flags(0x08000000)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(error)?;
    // Drain both pipes while PowerShell is running. A report larger than the
    // Windows pipe buffer must not block the child before the timeout check.
    let stdout = child.stdout.take().ok_or("Missing diagnostics output")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("Missing diagnostics error output")?;
    fn read_output(stream: impl Read) -> std::io::Result<Vec<u8>> {
        let mut bytes = Vec::new();
        stream.take(131_073).read_to_end(&mut bytes)?;
        Ok(bytes)
    }
    let output_reader = std::thread::spawn(move || read_output(stdout));
    let error_reader = std::thread::spawn(move || read_output(stderr));
    let deadline = Instant::now() + Duration::from_secs(30);
    while child.try_wait().map_err(error)?.is_none() {
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = output_reader.join();
            let _ = error_reader.join();
            return Err("Diagnostics timed out".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let status = child.wait().map_err(error)?;
    let output = output_reader
        .join()
        .map_err(|_| "Diagnostics reader failed")?
        .map_err(error)?;
    let errors = error_reader
        .join()
        .map_err(|_| "Diagnostics error reader failed")?
        .map_err(error)?;
    if output.len() > 131_072 || errors.len() > 131_072 {
        return Err("Windows diagnostics exceeded the report limit".into());
    }
    if !status.success() || output.is_empty() {
        return Err(format!(
            "Windows diagnostics unavailable: {}",
            String::from_utf8_lossy(&errors)
                .chars()
                .take(1200)
                .collect::<String>()
        ));
    }
    let text = String::from_utf8_lossy(&output);
    let mut report: Value =
        serde_json::from_str(text.trim_start_matches('\u{feff}').trim()).map_err(error)?;
    report["displayDevices"] = json!(super::drivers::devices()?);
    Ok(report)
}
