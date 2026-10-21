use super::{
    Configuration,
    capture::{self, Target},
    catalogue::{self, Catalogue},
    display, error, execute, identity, window_control,
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
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use windows::Win32::{
    Foundation::{HWND, LPARAM, POINT, WPARAM},
    Graphics::Gdi::ClientToScreen,
    System::Com::{COINIT_APARTMENTTHREADED, CoCreateGuid, CoInitializeEx},
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
}
struct Launch {
    app: String,
    pid: u32,
    before: HashSet<usize>,
    deadline: Instant,
}
struct Worker {
    sid: String,
    session: u32,
    epoch: String,
    catalogue: Catalogue,
    windows: HashMap<String, Window>,
    pending: Vec<Launch>,
    serial: u64,
    pressed: HashSet<u16>,
    buttons: HashSet<String>,
    display_busy: Arc<AtomicBool>,
    graphics_busy: Arc<AtomicBool>,
    execution_busy: Arc<AtomicBool>,
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
    let mut worker = Worker {
        sid,
        session,
        epoch,
        catalogue: Catalogue::new(),
        windows: HashMap::new(),
        pending: Vec::new(),
        serial: 0,
        pressed: HashSet::new(),
        buttons: HashSet::new(),
        display_busy: Arc::new(AtomicBool::new(false)),
        graphics_busy: Arc::new(AtomicBool::new(false)),
        execution_busy: Arc::new(AtomicBool::new(false)),
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
            "capabilities":{"capture":"software","windows":4,"transients":12,"windowRoles":true,"input":true,"catalogue":true,"displayInfo":true,"driverInfo":true,"graphicsInfo":true,"displayConfigure":true,"sharedGeometry":true,"execute":true,"executeTimeoutSeconds":60,"executeOutputBytes":65536,"displayEvents":self.display_observer.is_some()}}),
        );
        let (sender, receiver) = mpsc::sync_channel(128);
        let state = outbox.clone();
        std::thread::spawn(move || {
            while state.connected.load(Ordering::Acquire) {
                match wire::read(&mut stream) {
                    Ok(value) => {
                        if sender.try_send(value).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            state.connected.store(false, Ordering::Release);
        });
        self.release();
        for window in self.windows.values_mut() {
            if let Some(details) = catalogue::details(window.target.hwnd, &self.sid, self.session) {
                window.metadata = details;
            }
            window.stop = Some(capture::spawn(window.target.clone(), outbox.clone()));
        }
        self.snapshot(&outbox);
        let mut poll = Instant::now();
        let diagnostic_busy = Arc::new(AtomicBool::new(false));
        while outbox.connected.load(Ordering::Acquire) {
            if let Ok(command) = receiver.recv_timeout(Duration::from_millis(10)) {
                let request = command["request"].clone();
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
                {
                    let graphics_request = command["operation"] == "graphics_info";
                    let driver_request = command["operation"] == "driver_info";
                    let configure_request = command["operation"] == "display_configure";
                    let display_request =
                        command["operation"] == "display_info" || configure_request;
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
                            } else if display_request {
                                Ok(display::snapshot())
                            } else {
                                diagnostics()
                            };
                            sender.control(match result{Ok(value)=>json!({"type":"reply","request":request,"ok":true,"result":value}),
                                Err(message)=>json!({"type":"reply","request":request,"ok":false,"message":message})});
                            busy.store(false, Ordering::Release);
                        });
                    }
                    continue;
                }
                if command["operation"] != "heartbeat" {
                    let result = self.command(&command, &outbox);
                    outbox.control(match result {
                        Ok(value) => {
                            json!({"type":"reply","request":request,"ok":true,"result":value})
                        }
                        Err(message) => {
                            json!({"type":"reply","request":request,"ok":false,"message":message})
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
            if poll.elapsed() >= Duration::from_millis(75) {
                self.observe(&outbox);
                poll = Instant::now();
            }
        }
        for window in self.windows.values_mut() {
            if let Some(stop) = window.stop.take() {
                stop.store(true, Ordering::Release);
            }
        }
        outbox.connected.store(false, Ordering::Release);
        Err("Host disconnected; retaining application identities".into())
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
            "launch" => {
                let app = value["app"].as_str().ok_or("Missing app identity")?;
                if let Some(window) = self.windows.values().find(|w| {
                    w.app == app && !catalogue::transient(&w.metadata) && w.target.valid()
                }) {
                    unsafe {
                        let _ = ShowWindow(HWND(window.target.hwnd as *mut _), SW_RESTORE);
                        let _ = SetForegroundWindow(HWND(window.target.hwnd as *mut _));
                    }
                    outbox.control(json!({"type":"activate","window":window.target.id}));
                    return Ok(json!({"accepted":true,"existing":true}));
                }
                if self.pending.iter().any(|p| p.app == app) {
                    return Ok(json!({"accepted":true,"pending":true}));
                }
                if self.document_count() >= 4 {
                    return Err("Close an application before opening another".into());
                }
                let before = catalogue::windows().into_iter().collect();
                let pid = self.catalogue.launch(app)?;
                self.pending.push(Launch {
                    app: app.into(),
                    pid,
                    before,
                    deadline: Instant::now() + Duration::from_secs(10),
                });
                Ok(json!({"accepted":true,"ready":false}))
            }
            "snapshot" => {
                self.snapshot(outbox);
                Ok(json!({}))
            }
            "release" => {
                self.release();
                Ok(json!({}))
            }
            "input" | "activate" | "resize" | "close" | "hit_test" | "geometry" | "set_geometry"
            | "cancel_interaction" => {
                let id = value["window"].as_str().ok_or("Missing window identity")?;
                let window = self.windows.get(id).ok_or("Window retired")?;
                if !window.target.valid() {
                    return Err("Window retired".into());
                }
                let target = window.target.clone();
                match value["operation"].as_str().unwrap() {
                    "input" => {
                        let root = self.input_root(window);
                        let root_hwnd = root.target.hwnd;
                        let root_id = root.target.id.clone();
                        let related: Vec<usize> = self
                            .windows
                            .values()
                            .filter(|w| self.input_root(w).target.id == root_id)
                            .map(|w| w.target.hwnd)
                            .collect();
                        self.input(&target, root_hwnd, &related, value)?;
                    }
                    "activate" => unsafe {
                        let _ = ShowWindow(HWND(target.hwnd as *mut _), SW_RESTORE);
                        let _ = SetForegroundWindow(HWND(target.hwnd as *mut _));
                    },
                    "resize" => {
                        self.release();
                        return window_control::resize(&target, value);
                    }
                    "set_geometry" => {
                        self.release();
                        return window_control::set_geometry(&target, value);
                    }
                    "hit_test" => return window_control::hit_test(&target, value),
                    "geometry" => return window_control::state(&target),
                    "cancel_interaction" => {
                        self.release();
                        window_control::cancel(HWND(target.hwnd as *mut _));
                    }
                    "close" => unsafe {
                        PostMessageW(
                            Some(HWND(target.hwnd as *mut _)),
                            WM_CLOSE,
                            WPARAM(0),
                            LPARAM(0),
                        )
                        .map_err(error)?;
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

    fn observe(&mut self, outbox: &Arc<Outbox>) {
        let visible = catalogue::windows();
        let foreground = catalogue::foreground();
        let mut changed = false;
        let retired: Vec<String> = self
            .windows
            .iter()
            .filter(|(_, w)| {
                !w.target.valid()
                    || (catalogue::transient(&w.metadata)
                        && (!visible.contains(&w.target.hwnd)
                            || w.parent
                                .as_ref()
                                .is_none_or(|p| !self.windows.contains_key(p))))
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in retired {
            if let Some(mut window) = self.windows.remove(&id) {
                if let Some(stop) = window.stop.take() {
                    stop.store(true, Ordering::Release);
                }
                outbox.retire(&id);
                changed = true;
            }
        }
        let mut pending = std::mem::take(&mut self.pending);
        for launch in pending.drain(..) {
            let candidates: Vec<usize> = visible
                .iter()
                .copied()
                .filter(|raw| {
                    ((launch.pid != 0 && catalogue::process_id(*raw) == launch.pid)
                        || (!launch.before.contains(raw) && *raw == foreground)
                        || self.catalogue.matches(&launch.app, *raw))
                        && catalogue::details(*raw, &self.sid, self.session)
                            .is_some_and(|m| !catalogue::transient(&m))
                })
                .collect();
            let selected = candidates
                .iter()
                .find(|raw| **raw == foreground)
                .copied()
                .or_else(|| {
                    if candidates.len() == 1 {
                        candidates.first().copied()
                    } else {
                        None
                    }
                });
            if let Some(raw) = selected {
                if self.add(raw, launch.app.clone(), outbox) {
                    changed = true;
                    continue;
                }
            }
            if Instant::now() < launch.deadline {
                self.pending.push(launch);
            } else {
                outbox.control(json!({"type":"launch_error","app":launch.app,"message":"The app opened but its window could not be associated. Use Show Windows."}));
            }
        }
        let known: HashSet<usize> = self.windows.values().map(|w| w.target.hwnd).collect();
        // Owners precede their transient children even though EnumWindows is front-to-back.
        for raw in visible.iter().rev().copied() {
            if known.contains(&raw) || self.windows.len() >= 16 {
                continue;
            }
            if let Some(details) = catalogue::details(raw, &self.sid, self.session) {
                let pid = details["pid"].as_u64().unwrap_or(0) as u32;
                let owner = details["owner"].as_u64().unwrap_or(0) as usize;
                let app = self
                    .windows
                    .values()
                    .find(|w| w.target.pid == pid || w.target.hwnd == owner)
                    .map(|w| w.app.clone());
                if let Some(app) = app {
                    changed |= self.add(raw, app, outbox);
                }
            }
        }
        for window in self.windows.values_mut() {
            if let Some(mut details) =
                catalogue::details(window.target.hwnd, &self.sid, self.session)
            {
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

    fn add(&mut self, raw: usize, app: String, outbox: &Arc<Outbox>) -> bool {
        if self.windows.values().any(|w| w.target.hwnd == raw) || self.windows.len() >= 16 {
            return false;
        }
        let Some(metadata) = catalogue::details(raw, &self.sid, self.session) else {
            return false;
        };
        let transient = catalogue::transient(&metadata);
        if !transient && self.document_count() >= 4 {
            return false;
        }
        if transient
            && self
                .windows
                .values()
                .filter(|w| catalogue::transient(&w.metadata))
                .count()
                >= 12
        {
            return false;
        }
        let parent = self.parent_for(&metadata, &app);
        if transient && parent.is_none() {
            return false;
        }
        let Some((pid, creation)) = identity::owner(HWND(raw as *mut _), &self.sid, self.session)
        else {
            return false;
        };
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
            geometry: Mutex::new((0, 0, 0, 0, 0)),
        });
        let stop = Some(capture::spawn(target.clone(), outbox.clone()));
        self.windows.insert(
            id,
            Window {
                target,
                app,
                metadata,
                parent,
                stop,
            },
        );
        true
    }
    fn snapshot(&self, outbox: &Outbox) {
        let windows:Vec<Value>=self.windows.values().map(|w|{
            json!({"id":w.target.id,"app":w.app,"title":w.metadata["title"],"width":w.metadata["width"],"height":w.metadata["height"],
                "parent":w.parent,"role":w.metadata["role"],"x":w.metadata["x"],"y":w.metadata["y"],
                "z":w.metadata["z"],"visible":w.metadata["visible"],"minimized":w.metadata["minimized"],
                "class":w.metadata["class"],"style":w.metadata["style"],"exStyle":w.metadata["exStyle"],
                "maxWidth":w.metadata["maxWidth"],"maxHeight":w.metadata["maxHeight"],"resizable":w.metadata["resizable"]})
        }).collect();
        outbox.control(json!({"type":"windows","windows":windows,"epoch":self.epoch}));
    }
    fn save(&self) {
        let values:Vec<Value>=self.windows.values().filter(|w| !catalogue::transient(&w.metadata)).map(|w|json!({"hwnd":w.target.hwnd,"pid":w.target.pid,"creation":w.target.creation.to_string(),"app":w.app})).collect();
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
        for value in values.into_iter().take(4) {
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
            let Some(metadata) = catalogue::details(raw as usize, &self.sid, self.session) else {
                continue;
            };
            if catalogue::transient(&metadata) {
                continue;
            }
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
                geometry: Mutex::new((0, 0, 0, 0, 0)),
            });
            self.windows.insert(
                id,
                Window {
                    target,
                    app: value["app"].as_str().unwrap_or_default().into(),
                    metadata,
                    parent: None,
                    stop: None,
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
        unsafe {
            let hwnd = HWND(target.hwnd as *mut _);
            if !IsWindowEnabled(hwnd).as_bool() {
                return Err("This app is waiting for a dialog".into());
            }
            let kind = value["event"].as_str().ok_or("Missing input type")?;
            let foreground = GetAncestor(GetForegroundWindow(), GA_ROOT).0 as usize;
            let needs_focus =
                kind == "key" || kind == "text" || (kind == "button" && value["down"] == true);
            if needs_focus && !related.contains(&foreground) {
                let _ = SetForegroundWindow(HWND(root as *mut _));
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
                            return Err("The application did not accept text in time".into());
                        }
                    }
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
                        if ![0x10, 0x11, 0x12].contains(&key) {
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
        for key in self.pressed.drain() {
            let _ = send(keyboard(key, true));
        }
        for button in ["left", "right"] {
            let _ = self.release_button(button);
        }
    }
    fn release_button(&mut self, button: &str) -> Result<(), String> {
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
                dwFlags: if up {
                    KEYEVENTF_KEYUP
                } else {
                    KEYBD_EVENT_FLAGS(0)
                },
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
