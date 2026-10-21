use super::{error, identity, window_control};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use windows::{
    Win32::{
        Foundation::{FILETIME, HWND, LPARAM, POINT, RECT},
        Graphics::{
            Dwm::{DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute},
            Gdi::ClientToScreen,
        },
        Storage::{
            EnhancedStorage::{PKEY_Link_Arguments, PKEY_Link_TargetParsingPath},
            Packaging::Appx::GetApplicationUserModelId,
        },
        System::{
            Com::CoTaskMemFree,
            Threading::{GetProcessId, GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION},
        },
        UI::{
            Input::KeyboardAndMouse::IsWindowEnabled,
            Shell::{
                BHID_EnumItems, IEnumShellItems, IShellItem, IShellItem2, SEE_MASK_IDLIST,
                SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHCreateItemFromParsingName,
                SHELLEXECUTEINFOW, SHGetIDListFromObject, SIGDN_DESKTOPABSOLUTEPARSING,
                SIGDN_NORMALDISPLAY, ShellExecuteExW,
            },
            WindowsAndMessaging::{
                EnumWindows, GW_OWNER, GWL_EXSTYLE, GWL_STYLE, GetClassNameW, GetClientRect,
                GetForegroundWindow, GetWindow, GetWindowLongPtrW, GetWindowRect, GetWindowTextW,
                GetWindowThreadProcessId, IsIconic, IsWindowVisible, WS_CAPTION,
                WS_EX_DLGMODALFRAME, WS_EX_TOOLWINDOW, WS_POPUP, WS_THICKFRAME,
            },
        },
    },
    core::{Interface, PWSTR, w},
};

pub struct Catalogue {
    pub items: HashMap<String, IShellItem>,
    identities: HashMap<String, String>,
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
        unsafe {
            let Ok(handle) =
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process_id(hwnd))
            else {
                return false;
            };
            let handle = identity::Handle(handle);
            let mut length = 0;
            let _ = GetApplicationUserModelId(handle.0, &mut length, None);
            if length == 0 || length > 32768 {
                return false;
            }
            let mut buffer = vec![0u16; length as usize];
            if GetApplicationUserModelId(handle.0, &mut length, Some(PWSTR(buffer.as_mut_ptr()))).0
                != 0
            {
                return false;
            }
            let actual = String::from_utf16_lossy(
                &buffer[..buffer.iter().position(|v| *v == 0).unwrap_or(buffer.len())],
            );
            actual.eq_ignore_ascii_case(
                expected
                    .strip_prefix("shell:AppsFolder\\")
                    .unwrap_or(expected),
            )
        }
    }

    pub fn launch(&self, id: &str) -> Result<(u32, u64), String> {
        let item = self
            .items
            .get(id)
            .ok_or("Refresh the application list before launching")?;
        unsafe {
            let pidl = SHGetIDListFromObject(item).map_err(error)?;
            let mut info = SHELLEXECUTEINFOW::default();
            info.cbSize = size_of::<SHELLEXECUTEINFOW>() as u32;
            info.fMask = SEE_MASK_IDLIST | SEE_MASK_NOASYNC | SEE_MASK_NOCLOSEPROCESS;
            info.lpVerb = w!("open");
            info.lpIDList = pidl.cast();
            info.nShow = 1;
            let result = ShellExecuteExW(&mut info).map_err(error);
            CoTaskMemFree(Some(pidl.cast()));
            result?;
            let process = identity::Handle(info.hProcess);
            if process.0.is_invalid() {
                return Ok((0, 0));
            }
            let mut created = FILETIME::default();
            let mut exited = FILETIME::default();
            let mut kernel = FILETIME::default();
            let mut user = FILETIME::default();
            // Keep the activation handle alive while reading its identity:
            // reopening only the PID could capture an unrelated reused process.
            if GetProcessTimes(process.0, &mut created, &mut exited, &mut kernel, &mut user).is_err() {
                // Activation succeeded; packaged apps can still be associated by
                // their declared app identity when no process identity is usable.
                return Ok((0, 0));
            }
            Ok((GetProcessId(process.0), ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64))
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
            "style":style,"exStyle":ex_style,"visible":IsWindowVisible(hwnd).as_bool(),
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
