use super::error;
use windows::{
    Win32::{
        Foundation::{CloseHandle, FILETIME, HANDLE, HLOCAL, HWND, LocalFree},
        Security::{
            Authorization::ConvertSidToStringSidW, GetTokenInformation, TOKEN_QUERY, TOKEN_USER,
            TokenUser, TokenIntegrityLevel, TOKEN_MANDATORY_LABEL,
            GetSidSubAuthority, GetSidSubAuthorityCount, IsValidSid,
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

pub fn integrity_level(pid: u32) -> Option<u32> {
    unsafe {
        let process=Handle(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,false,pid).ok()?);
        let mut token=HANDLE::default();
        OpenProcessToken(process.0,TOKEN_QUERY,&mut token).ok()?;
        let token=Handle(token);
        let mut size=0;
        let _=GetTokenInformation(token.0,TokenIntegrityLevel,None,0,&mut size);
        if size<size_of::<TOKEN_MANDATORY_LABEL>() as u32 || size>65536 {return None;}
        let mut data=vec![0u64;(size as usize).div_ceil(8)];
        GetTokenInformation(token.0,TokenIntegrityLevel,Some(data.as_mut_ptr().cast()),size,&mut size).ok()?;
        let sid=(*data.as_ptr().cast::<TOKEN_MANDATORY_LABEL>()).Label.Sid;
        if !IsValidSid(sid).as_bool(){return None;}
        let count=*GetSidSubAuthorityCount(sid);
        if count==0 {return None;}
        Some(*GetSidSubAuthority(sid,u32::from(count-1)))
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
