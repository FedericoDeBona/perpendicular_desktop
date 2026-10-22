//! User/session-scoped process identities for application window transitions.
use super::identity::{self, Handle};
use windows::Win32::{
    Foundation::{FILETIME, WAIT_TIMEOUT},
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW,
            TH32CS_SNAPPROCESS,
        },
        RemoteDesktop::ProcessIdToSessionId,
        Threading::{
            GetProcessTimes, OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
            PROCESS_TERMINATE, PROCESS_ACCESS_RIGHTS, IsProcessCritical, TerminateProcess,
            QueryFullProcessImageNameW, WaitForSingleObject,
        },
    },
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Identity {
    pub pid: u32,
    pub creation: u64,
}

pub struct Process {
    pub identity: Identity,
    handle: Handle,
    image: String,
}
impl Process {
    pub fn open(pid: u32, sid: &str, session: u32) -> Option<Self> {
        Self::open_with_access(pid, sid, session, PROCESS_ACCESS_RIGHTS(0))
    }
    fn open_with_access(pid: u32, sid: &str, session: u32, access: PROCESS_ACCESS_RIGHTS) -> Option<Self> {
        unsafe {
            let mut actual_session = 0;
            ProcessIdToSessionId(pid, &mut actual_session).ok()?;
            if actual_session != session {
                return None;
            }
            let handle = Handle(
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE | access,
                    false,
                    pid,
                )
                .ok()?,
            );
            if identity::sid(handle.0).ok()?.as_str() != sid {
                return None;
            }
            // A shared frame host must never authorize all of its app windows.
            let mut image = vec![0u16; 32768];
            let mut length = image.len() as u32;
            QueryFullProcessImageNameW(handle.0, PROCESS_NAME_WIN32, windows::core::PWSTR(image.as_mut_ptr()), &mut length).ok()?;
            let image = String::from_utf16_lossy(&image[..length as usize]);
            if image.rsplit('\\').next().is_some_and(|name| name.eq_ignore_ascii_case("ApplicationFrameHost.exe")) {
                return None;
            }
            let (mut creation, mut exit, mut kernel, mut user) = (
                FILETIME::default(),
                FILETIME::default(),
                FILETIME::default(),
                FILETIME::default(),
            );
            GetProcessTimes(handle.0, &mut creation, &mut exit, &mut kernel, &mut user).ok()?;
            let process = Self {
                identity: Identity {
                    pid,
                    creation: (u64::from(creation.dwHighDateTime) << 32)
                        | u64::from(creation.dwLowDateTime),
                },
                handle,
                image,
            };
            process.alive().then_some(process)
        }
    }
    pub fn name(&self) -> &str { self.image.rsplit('\\').next().unwrap_or(&self.image) }
    pub fn can_terminate(&self) -> bool {
        if self.identity.pid == std::process::id() || ["perpendicular-guest.exe", "explorer.exe", "sihost.exe", "ShellExperienceHost.exe", "StartMenuExperienceHost.exe"].iter()
            .any(|name| self.name().eq_ignore_ascii_case(name)) { return false; }
        let mut critical = windows::core::BOOL::from(true);
        unsafe { IsProcessCritical(self.handle.0, &mut critical).is_ok() && !critical.as_bool() }
    }
    pub fn alive(&self) -> bool {
        unsafe { WaitForSingleObject(self.handle.0, 0) == WAIT_TIMEOUT }
    }
}

/// One bounded snapshot, shared by the application's discovery pass. Process
/// names are not identities and no WMI/provider or executable is started here.
pub fn snapshot() -> Option<Vec<(u32, u32)>> {
    unsafe {
        let snapshot = Handle(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0).ok()?);
        let mut entry = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        Process32FirstW(snapshot.0, &mut entry).ok()?;
        let mut result = Vec::new();
        loop {
            if result.len() >= 8192 {
                return None;
            }
            result.push((entry.th32ProcessID, entry.th32ParentProcessID));
            if Process32NextW(snapshot.0, &mut entry).is_err() {
                break;
            }
        }
        Some(result)
    }
}

/// Follow only a live, already authenticated parent. A dead/reused parent PID
/// without such an identity never authorizes attaching an unrelated window.
pub fn descendants(
    table: &[(u32, u32)],
    roots: &[Process],
    sid: &str,
    session: u32,
    limit: usize,
) -> Vec<Process> {
    let mut found: Vec<Process> = Vec::new();
    for _ in 0..8 {
        let previous = found.len();
        for &(pid, parent) in table {
            if found.len() >= limit {
                return found;
            }
            if roots.iter().chain(&found).any(|p| p.identity.pid == pid) {
                continue;
            }
            let Some(parent) = roots
                .iter()
                .chain(&found)
                .find(|p| p.identity.pid == parent && p.alive())
                .map(|p| p.identity)
            else {
                continue;
            };
            let Some(child) = Process::open(pid, sid, session) else {
                continue;
            };
            if child.identity.creation >= parent.creation {
                found.push(child);
            }
        }
        if found.len() == previous {
            break;
        }
    }
    found
}

/// Reopen with minimal termination rights and validate that exact handle. Never
/// authorize from a name, a stale row, or PID alone; do not kill descendants.
pub fn terminate(pid: u32, creation: u64, sid: &str, session: u32) -> Result<serde_json::Value, String> {
    let process = Process::open_with_access(pid, sid, session, PROCESS_TERMINATE)
        .filter(|p| p.identity.creation == creation)
        .ok_or("Il processo è terminato, è cambiato o non è accessibile nella sessione corrente")?;
    if !process.can_terminate() { return Err("Questo processo di sistema o del bridge è protetto".into()); }
    unsafe { TerminateProcess(process.handle.0, 1).map_err(super::error)?; }
    Ok(serde_json::json!({"pid":pid,"creation":creation.to_string(),"terminationRequested":true}))
}

pub fn list(sid: &str, session: u32) -> Result<serde_json::Value, String> {
    let table = snapshot().ok_or("Impossibile leggere i processi Windows")?;
    let mut rows = Vec::new();
    for (pid, _) in table {
        if let Some(process) = Process::open(pid, sid, session) {
            if rows.len() >= 512 { return Err("Troppi processi nella sessione; elenco non pubblicato".into()); }
            rows.push(serde_json::json!({"pid":pid,"creation":process.identity.creation.to_string(),
                "name":process.name(),"canTerminate":process.can_terminate()}));
        }
    }
    rows.sort_by_key(|row| row["name"].as_str().unwrap_or("").to_lowercase());
    Ok(serde_json::json!({"session":session,"processes":rows}))
}
