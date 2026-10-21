use super::error;
use windows::{
    Win32::{
        Foundation::{CloseHandle, FILETIME, HANDLE, HLOCAL, HWND, LocalFree},
        Security::{
            Authorization::ConvertSidToStringSidW, GetTokenInformation, TOKEN_QUERY, TOKEN_USER,
            TokenUser,
        },
        System::{
            RemoteDesktop::ProcessIdToSessionId,
            Threading::{
                GetCurrentProcess, GetCurrentProcessId, GetProcessTimes, OpenProcess,
                OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
        UI::WindowsAndMessaging::{GetWindowThreadProcessId, IsWindow},
    },
    core::PWSTR,
};

pub struct Handle(pub HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

pub unsafe fn sid(process: HANDLE) -> Result<String, String> {
    let mut token = HANDLE::default();
    unsafe {
        OpenProcessToken(process, TOKEN_QUERY, &mut token).map_err(error)?;
    }
    let token = Handle(token);
    let mut size = 0;
    unsafe {
        let _ = GetTokenInformation(token.0, TokenUser, None, 0, &mut size);
    }
    if size == 0 || size > 65536 {
        return Err("user identity unavailable".into());
    }
    let mut data = vec![0u64; (size as usize).div_ceil(8)];
    unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            Some(data.as_mut_ptr().cast()),
            size,
            &mut size,
        )
        .map_err(error)?;
        let user = &*data.as_ptr().cast::<TOKEN_USER>();
        let mut value = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut value).map_err(error)?;
        let result = value.to_string().map_err(error);
        let _ = LocalFree(Some(HLOCAL(value.0.cast())));
        result
    }
}

pub fn current() -> Result<(String, u32), String> {
    unsafe {
        let mut session = 0;
        ProcessIdToSessionId(GetCurrentProcessId(), &mut session).map_err(error)?;
        if session == 0 {
            return Err("interactive user session required".into());
        }
        Ok((sid(GetCurrentProcess())?, session))
    }
}

pub fn owner(hwnd: HWND, expected_sid: &str, session: u32) -> Option<(u32, u64)> {
    unsafe {
        if !IsWindow(Some(hwnd)).as_bool() {
            return None;
        }
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        let mut actual_session = 0;
        ProcessIdToSessionId(pid, &mut actual_session).ok()?;
        if actual_session != session {
            return None;
        }
        let process = Handle(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?);
        if sid(process.0).ok()?.as_str() != expected_sid {
            return None;
        }
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        GetProcessTimes(process.0, &mut creation, &mut exit, &mut kernel, &mut user).ok()?;
        Some((
            pid,
            (u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime),
        ))
    }
}
