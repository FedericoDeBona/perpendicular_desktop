use super::{error, identity, window_control};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use windows::{
    Win32::{
        Foundation::{FILETIME, HANDLE, HWND, LPARAM, POINT, RECT, ERROR_INSUFFICIENT_BUFFER},
        Graphics::{
            Dwm::{DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute},
            Gdi::ClientToScreen,
        },
        Storage::{
            EnhancedStorage::{PKEY_Link_Arguments, PKEY_Link_TargetParsingPath},
            Packaging::Appx::{GetApplicationUserModelId, GetPackagesByPackageFamily, ParseApplicationUserModelId},
        },
        System::{
            Com::{CLSCTX_LOCAL_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize},
            Threading::{GetProcessId, GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION},
        },
        UI::{
            Input::KeyboardAndMouse::IsWindowEnabled,
            Shell::{
                AO_NONE, ApplicationActivationManager, IApplicationActivationManager,
                BHID_EnumItems, IEnumShellItems, ILGetSize, IShellItem, IShellItem2, SEE_MASK_IDLIST,
                SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHCreateItemFromParsingName,
                SHELLEXECUTEINFOW, SHGetIDListFromObject, SIGDN_DESKTOPABSOLUTEPARSING,
                SIGDN_NORMALDISPLAY, ShellExecuteExW,
            },
            WindowsAndMessaging::{
                EnumChildWindows, EnumWindows, GA_ROOT, GW_OWNER, GWL_EXSTYLE, GWL_STYLE, GetAncestor, GetClassNameW, GetClientRect,
                GetForegroundWindow, GetWindow, GetWindowLongPtrW, GetWindowRect, GetWindowTextW,
                GetWindowThreadProcessId, IsIconic, IsWindowVisible, WS_CAPTION,
                WS_EX_DLGMODALFRAME, WS_EX_TOOLWINDOW, WS_POPUP, WS_THICKFRAME,
            },
        },
    },
    core::{Interface, PCWSTR, PWSTR, w},
};

pub struct Catalogue {
    pub items: HashMap<String, IShellItem>,
    identities: HashMap<String, String>,
}

/// The process owning an ApplicationFrameWindow is shared. Its app identity
/// comes only from this authenticated CoreWindow child, never the host PID.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct HostedContent {
    pub hwnd: usize,
    pub pid: u32,
    pub creation: u64,
    pub app_id: String,
}
impl HostedContent {
    pub fn valid(&self, frame: usize, sid: &str, session: u32) -> bool {
        identity::owner(HWND(self.hwnd as *mut _), sid, session) == Some((self.pid, self.creation))
            && window_class(self.hwnd) == "Windows.UI.Core.CoreWindow"
            && window_class(frame) == "ApplicationFrameWindow"
            && unsafe { GetAncestor(HWND(self.hwnd as *mut _), GA_ROOT).0 as usize == frame }
    }
    pub fn matches_app(&self) -> bool {
        !self.app_id.is_empty() && self.app_id.len() <= 32768
            && process_app_id(self.hwnd).is_some_and(|actual| actual.eq_ignore_ascii_case(&self.app_id))
    }
}

pub fn window_class(raw: usize) -> String {
    let mut class = [0u16; 256];
    let count = unsafe { GetClassNameW(HWND(raw as *mut _), &mut class) }.max(0) as usize;
    String::from_utf16_lossy(&class[..count])
}

/// Only a real parent chain can promote a CoreWindow to its visible frame.
pub fn host_frame(raw: usize, sid: &str, session: u32) -> Option<usize> {
    if window_class(raw) != "Windows.UI.Core.CoreWindow" { return None; }
    let root = unsafe { GetAncestor(HWND(raw as *mut _), GA_ROOT).0 as usize };
    if root == 0 || root == raw || window_class(root) != "ApplicationFrameWindow" { return None; }
    identity::owner(HWND(raw as *mut _), sid, session)?;
    identity::owner(HWND(root as *mut _), sid, session)?;
    Some(root)
}

fn process_app_id(raw: usize) -> Option<String> {
    unsafe {
        let handle = identity::Handle(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process_id(raw)).ok()?);
        handle_app_id(handle.0)
    }
}

fn handle_app_id(handle: HANDLE) -> Option<String> {
    unsafe {
        let mut length = 0;
        let _ = GetApplicationUserModelId(handle, &mut length, None);
        if length == 0 || length > 32768 { return None; }
        let mut buffer = vec![0u16; length as usize];
        if GetApplicationUserModelId(handle, &mut length, Some(PWSTR(buffer.as_mut_ptr()))).0 != 0 { return None; }
        Some(String::from_utf16_lossy(&buffer[..buffer.iter().position(|v| *v == 0).unwrap_or(buffer.len())]))
    }
}

unsafe extern "system" fn collect_children(hwnd: HWND, context: LPARAM) -> windows::core::BOOL {
    let children = unsafe { &mut *(context.0 as *mut Vec<usize>) };
    children.push(hwnd.0 as usize);
    (children.len() < 64).into()
}

/// Owned bytes only; Shell COM interfaces stay in the catalogue's apartment.
pub struct Activation {
    pidl: Vec<u16>,
    packaged_id: Option<String>,
}

// AppsFolder also contains desktop shortcuts with explicit AppUserModelIDs.
// Select package activation only after Windows parses the identity and finds a
// package registered for this user. Desktop entries keep Shell activation.
fn registered_package(app: &str) -> bool {
    let app: Vec<u16> = app.encode_utf16().chain(Some(0)).collect();
    let mut family = vec![0u16; 32768];
    let mut relative = vec![0u16; 32768];
    let (mut family_length, mut relative_length) = (family.len() as u32, relative.len() as u32);
    unsafe {
        if ParseApplicationUserModelId(PCWSTR(app.as_ptr()), &mut family_length, Some(PWSTR(family.as_mut_ptr())),
            &mut relative_length, Some(PWSTR(relative.as_mut_ptr()))).0 != 0 { return false; }
        let (mut count, mut length) = (0, 0);
        let result = GetPackagesByPackageFamily(PCWSTR(family.as_ptr()), &mut count, None, &mut length, None);
        result == ERROR_INSUFFICIENT_BUFFER && count > 0
    }
}

impl Activation {
    pub fn run(self) -> Result<(u32, u64), String> {
        unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok().map_err(error)?; }
        let result = self.execute();
        unsafe { CoUninitialize(); }
        result
    }

    fn execute(&self) -> Result<(u32, u64), String> {
        unsafe {
            if let Some(app) = &self.packaged_id {
                let manager: IApplicationActivationManager = CoCreateInstance(&ApplicationActivationManager, None, CLSCTX_LOCAL_SERVER).map_err(error)?;
                let wide: Vec<u16> = app.encode_utf16().chain(Some(0)).collect();
                let pid = manager.ActivateApplication(PCWSTR(wide.as_ptr()), PCWSTR::null(), AO_NONE).map_err(error)?;
                let handle = identity::Handle(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).map_err(error)?);
                if !handle_app_id(handle.0).is_some_and(|actual| actual.eq_ignore_ascii_case(app)) {
                    return Err("Windows activation returned a different application identity".into());
                }
                let (mut created, mut exited, mut kernel, mut user) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
                GetProcessTimes(handle.0, &mut created, &mut exited, &mut kernel, &mut user).map_err(error)?;
                return Ok((pid, ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64));
            }
            let mut info = SHELLEXECUTEINFOW::default();
            info.cbSize = size_of::<SHELLEXECUTEINFOW>() as u32;
            info.fMask = SEE_MASK_IDLIST | SEE_MASK_NOASYNC | SEE_MASK_NOCLOSEPROCESS;
            info.lpVerb = w!("open");
            info.lpIDList = self.pidl.as_ptr().cast_mut().cast();
            info.nShow = 1;
            ShellExecuteExW(&mut info).map_err(error)?;
            let process = identity::Handle(info.hProcess);
            if process.0.is_invalid() { return Ok((0, 0)); }
            let mut created = FILETIME::default();
            let mut exited = FILETIME::default();
            let mut kernel = FILETIME::default();
            let mut user = FILETIME::default();
            // Read the identity before closing this exact activation handle.
            if GetProcessTimes(process.0, &mut created, &mut exited, &mut kernel, &mut user).is_err() {
                return Ok((0, 0));
            }
            Ok((GetProcessId(process.0), ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64))
        }
    }
}

unsafe fn text(value: PWSTR) -> String {
    unsafe {
        let result = value.to_string().unwrap_or_default();
        CoTaskMemFree(Some(value.0.cast()));
        result
    }
}

impl Catalogue {
    pub fn new() -> Self {
        Self {
            items: HashMap::new(),
            identities: HashMap::new(),
        }
    }

    /// Only this string crosses into an icon worker's COM apartment.
    pub fn icon_source(&self, id: &str) -> Result<String, String> {
        self.identities.get(id).cloned()
            .ok_or_else(|| "Refresh the application list before requesting its icon".into())
    }

    pub fn refresh(&mut self) -> Result<Value, String> {
        unsafe {
            let folder: IShellItem =
                SHCreateItemFromParsingName(w!("shell:AppsFolder"), None).map_err(error)?;
            let iterator: IEnumShellItems =
                folder.BindToHandler(None, &BHID_EnumItems).map_err(error)?;
            let mut apps = Vec::new();
            let mut items = HashMap::new();
            let mut identities = HashMap::new();
            for _ in 0..1024 {
                let mut next = [None];
                let mut fetched = 0;
                if iterator.Next(&mut next, Some(&mut fetched)).is_err() || fetched == 0 {
                    break;
                }
                let Some(item) = next[0].take() else {
                    continue;
                };
                let Ok(name) = item.GetDisplayName(SIGDN_NORMALDISPLAY) else {
                    continue;
                };
                let name = text(name);
                let Ok(parsing) = item.GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING) else {
                    continue;
                };
                let parsing = text(parsing);
                if name.is_empty() || name.len() > 512 || parsing.len() > 32768 {
                    continue;
                }
                // Exclude host-forwarding aliases and unavailable local links.
                if let Ok(properties) = item.cast::<IShellItem2>() {
                    // Converted VMs can retain rundll32 shortcuts whose target
                    // exists locally but whose arguments delegate to the Mac.
                    if let Ok(arguments) = properties.GetString(&PKEY_Link_Arguments) {
                        if text(arguments).to_ascii_lowercase().contains("sharedhostapps.dll") {
                            continue;
                        }
                    }
                    if let Ok(target) = properties.GetString(&PKEY_Link_TargetParsingPath) {
                        let path = text(target);
                        let normalized = path.to_lowercase();
                        if normalized.contains("sharedhostapps")
                            || path.starts_with("\\\\")
                            || (path.as_bytes().get(1) == Some(&b':')
                                && !std::path::Path::new(&path).exists())
                        {
                            continue;
                        }
                    }
                }
                let id = format!("{:x}", Sha256::digest(parsing.as_bytes()));
                apps.push(json!({"id":id,"name":name}));
                identities.insert(id.clone(), parsing);
                items.insert(id, item);
            }
            apps.sort_by_key(|a| a["name"].as_str().unwrap_or_default().to_lowercase());
            self.items = items;
            self.identities = identities;
            Ok(json!(apps))
        }
    }

    /// Shell activation can reuse an existing packaged app without returning a
    /// process handle or creating a new HWND. Match its declared app identity,
    /// never an arbitrary foreground window or a window title.
    pub fn matches(&self, id: &str, hwnd: usize) -> bool {
        let Some(expected) = self.identities.get(id) else {
            return false;
        };
        process_app_id(hwnd).is_some_and(|actual| actual.eq_ignore_ascii_case(
            expected.strip_prefix("shell:AppsFolder\\").unwrap_or(expected)))
    }

    pub fn hosted_content(&self, app: &str, frame: usize, sid: &str, session: u32) -> Option<HostedContent> {
        if window_class(frame) != "ApplicationFrameWindow" { return None; }
        identity::owner(HWND(frame as *mut _), sid, session)?;
        let expected = self.identities.get(app)?;
        let expected = expected.strip_prefix("shell:AppsFolder\\").unwrap_or(expected);
        let mut children = Vec::new();
        unsafe { let _ = EnumChildWindows(Some(HWND(frame as *mut _)), Some(collect_children),
            LPARAM((&mut children as *mut Vec<usize>) as isize)); }
        for hwnd in children {
            if window_class(hwnd) != "Windows.UI.Core.CoreWindow" { continue; }
            if !unsafe { IsWindowVisible(HWND(hwnd as *mut _)).as_bool() } { continue; }
            let Some((pid, creation)) = identity::owner(HWND(hwnd as *mut _), sid, session) else { continue; };
            let Some(actual) = process_app_id(hwnd).filter(|actual| actual.eq_ignore_ascii_case(expected)) else { continue; };
            let content = HostedContent { hwnd, pid, creation, app_id: actual };
            if content.valid(frame, sid, session) { return Some(content); }
        }
        None
    }

    pub fn prepare_launch(&self, id: &str) -> Result<Activation, String> {
        let item = self
            .items
            .get(id)
            .ok_or("Refresh the application list before launching")?;
        unsafe {
            let pidl = SHGetIDListFromObject(item).map_err(error)?;
            let size = ILGetSize(Some(pidl)) as usize;
            if !(3..=65_536).contains(&size) {
                CoTaskMemFree(Some(pidl.cast()));
                return Err("Invalid application activation identity".into());
            }
            // ITEMIDLIST needs two-byte alignment, including odd-length items.
            let mut owned = vec![0u16; size.div_ceil(2)];
            std::ptr::copy_nonoverlapping(pidl.cast::<u8>(), owned.as_mut_ptr().cast::<u8>(), size);
            CoTaskMemFree(Some(pidl.cast()));
            let bytes = std::slice::from_raw_parts(owned.as_ptr().cast::<u8>(), size);
            let mut offset = 0;
            loop {
                let Some(length) = bytes.get(offset..offset + 2) else {
                    return Err("Invalid application activation identity".into());
                };
                let length = u16::from_le_bytes([length[0], length[1]]) as usize;
                if length == 0 {
                    if offset == 0 || offset + 2 != size {
                        return Err("Invalid application activation identity".into());
                    }
                    break;
                }
                if length < 2 || length > size - offset - 2 {
                    return Err("Invalid application activation identity".into());
                }
                offset += length;
            }
            let packaged_id = self.identities.get(id).filter(|app| registered_package(app)).cloned();
            Ok(Activation { pidl: owned, packaged_id })
        }
    }
}

unsafe extern "system" fn collect(hwnd: HWND, context: LPARAM) -> windows::core::BOOL {
    let values = unsafe { &mut *(context.0 as *mut Vec<usize>) };
    if values.len() >= 1024 {
        return false.into();
    }
    unsafe {
        if IsWindowVisible(hwnd).as_bool() {
            values.push(hwnd.0 as usize);
        }
    }
    true.into()
}

pub fn windows() -> Vec<usize> {
    let mut values = Vec::new();
    unsafe {
        let _ = EnumWindows(
            Some(collect),
            LPARAM((&mut values as *mut Vec<usize>) as isize),
        );
    }
    values
}

pub fn details(raw: usize, sid: &str, session: u32) -> Option<Value> {
    let hwnd = HWND(raw as *mut _);
    let (pid, creation) = identity::owner(hwnd, sid, session)?;
    unsafe {
        let mut cloaked = 0u32;
        let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, (&mut cloaked as *mut u32).cast(), size_of::<u32>() as u32);
        let mut client = windows::Win32::Foundation::RECT::default();
        GetClientRect(hwnd, &mut client).ok()?;
        if client.right <= 0 || client.bottom <= 0 {
            return None;
        }
        let mut title = [0u16; 1024];
        let count = GetWindowTextW(hwnd, &mut title).max(0) as usize;
        let owner = GetWindow(hwnd, GW_OWNER).unwrap_or_default().0 as usize;
        let mut class = [0u16; 256];
        let count_class = GetClassNameW(hwnd, &mut class).max(0) as usize;
        let class = String::from_utf16_lossy(&class[..count_class]);
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
        let ex_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
        let caption = style & WS_CAPTION.0 == WS_CAPTION.0;
        // DWM's decoration has no independent app content or input surface.
        // AppKit supplies the shadow of the corresponding Mac window.
        if class == "SysShadow" && !caption && style & WS_THICKFRAME.0 == 0 {
            return None;
        }
        // WS_POPUP alone also describes real dialogs. Preserve those as documents.
        let role = if class == "#32768" {
            "popup"
        } else if class.eq_ignore_ascii_case("tooltips_class32")
            || class == "MicrosoftWindowsTooltip"
        {
            "tooltip"
        } else if class == "#32770"
            || ex_style & WS_EX_DLGMODALFRAME.0 != 0
            || (owner != 0 && !IsWindowEnabled(HWND(owner as *mut _)).as_bool())
        {
            "dialog"
        } else if !caption
            && style & WS_THICKFRAME.0 == 0
            && (style & WS_POPUP.0 != 0 || ex_style & WS_EX_TOOLWINDOW.0 != 0)
        {
            "popup"
        } else if owner != 0 && caption {
            "dialog"
        } else {
            "main"
        };
        let mut rect = frame_bounds(hwnd)?;
        let (max_width, max_height) = window_control::limits(hwnd, role != "dialog");
        if role == "dialog" {
            let mut origin = POINT::default();
            if !ClientToScreen(hwnd, &mut origin).as_bool() {
                return None;
            }
            rect = RECT {
                left: origin.x,
                top: origin.y,
                right: origin.x + client.right,
                bottom: origin.y + client.bottom,
            };
        }
        Some(json!({"hwnd":raw,"pid":pid,"creation":creation.to_string(),
            "title":String::from_utf16_lossy(&title[..count]),"owner":owner,
            "width":rect.right-rect.left,"height":rect.bottom-rect.top,
            "x":rect.left,"y":rect.top,"role":role,"class":class,
            "style":style,"exStyle":ex_style,"cloaked":cloaked != 0,
            "visible":IsWindowVisible(hwnd).as_bool() && cloaked == 0,
            "maxWidth":max_width,"maxHeight":max_height,"resizable":style & WS_THICKFRAME.0 != 0,
            "minimized":IsIconic(hwnd).as_bool()}))
    }
}

pub fn transient(metadata: &Value) -> bool {
    matches!(metadata["role"].as_str(), Some("popup" | "tooltip"))
}

pub fn frame_bounds(hwnd: HWND) -> Option<RECT> {
    unsafe {
        let mut rect = RECT::default();
        if DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            (&mut rect as *mut RECT).cast(),
            size_of::<RECT>() as u32,
        )
        .is_err()
            || rect.right <= rect.left
            || rect.bottom <= rect.top
        {
            GetWindowRect(hwnd, &mut rect).ok()?;
        }
        Some(rect)
    }
}

pub fn foreground() -> usize {
    unsafe { GetForegroundWindow().0 as usize }
}
pub fn process_id(raw: usize) -> u32 {
    let mut pid = 0;
    unsafe {
        GetWindowThreadProcessId(HWND(raw as *mut _), Some(&mut pid));
    }
    pid
}
