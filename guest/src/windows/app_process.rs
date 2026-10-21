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
            GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
            WaitForSingleObject,
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
}
impl Process {
    pub fn open(pid: u32, sid: &str, session: u32) -> Option<Self> {
        unsafe {
            let mut actual_session = 0;
            ProcessIdToSessionId(pid, &mut actual_session).ok()?;
            if actual_session != session {
                return None;
            }
            let handle = Handle(
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    false,
                    pid,
                )
                .ok()?,
            );
            if identity::sid(handle.0).ok()?.as_str() != sid {
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
            };
            process.alive().then_some(process)
        }
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
