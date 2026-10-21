//! RDP listener inventory and explicit console return. Never reads credentials or private keys.
use super::{error, identity};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{ptr, slice};
use windows::{
    Win32::{
        Foundation::{CRYPT_E_NOT_FOUND, ERROR_FILE_NOT_FOUND, ERROR_NO_MORE_FILES, GetLastError},
        Security::Cryptography::{
            CERT_CONTEXT, CERT_OPEN_STORE_FLAGS, CERT_QUERY_ENCODING_TYPE, CERT_SHA1_HASH_PROP_ID,
            CERT_STORE_OPEN_EXISTING_FLAG, CERT_STORE_PROV_SYSTEM_W, CERT_STORE_READONLY_FLAG,
            CERT_SYSTEM_STORE_LOCAL_MACHINE, CertCloseStore, CertEnumCertificatesInStore,
            CertFreeCertificateContext, CertGetCertificateContextProperty, CertOpenStore,
            CertVerifyTimeValidity, HCERTSTORE,
        },
        System::{
            Registry::{
                HKEY_LOCAL_MACHINE, REG_BINARY, REG_DWORD, REG_SZ, REG_VALUE_TYPE, RRF_RT_ANY,
                RegGetValueW,
            },
            RemoteDesktop::{
                WTS_INFO_CLASS, WTSDomainName, WTSFreeMemory, WTSQuerySessionInformationW,
                WTSUserName,
            },
        },
    },
    core::{PCWSTR, PWSTR, w},
};

const TERMINAL: &str = r"SYSTEM\CurrentControlSet\Control\Terminal Server";
const LISTENER: &str = r"SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp";
const POLICY: &str = r"SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services";

struct Store(HCERTSTORE);
impl Drop for Store {
    fn drop(&mut self) {
        unsafe {
            let _ = CertCloseStore(Some(self.0), 0);
        }
    }
}
struct CertificateCursor(*const CERT_CONTEXT);
impl Drop for CertificateCursor {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = CertFreeCertificateContext(Some(self.0));
            }
        }
    }
}
struct SessionText(PWSTR);
impl Drop for SessionText {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                WTSFreeMemory(self.0.0.cast());
            }
        }
    }
}

fn registry(path: &str, name: &str) -> Result<Option<(REG_VALUE_TYPE, Vec<u8>)>, String> {
    let path: Vec<u16> = path.encode_utf16().chain([0]).collect();
    let name: Vec<u16> = name.encode_utf16().chain([0]).collect();
    let mut kind = REG_VALUE_TYPE::default();
    let mut size = 0;
    unsafe {
        let result = RegGetValueW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(path.as_ptr()),
            PCWSTR(name.as_ptr()),
            RRF_RT_ANY,
            Some(&mut kind),
            None,
            Some(&mut size),
        );
        if result == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        result.ok().map_err(error)?;
        if size > 65536 {
            return Err("RDP registry value is unexpectedly large".into());
        }
        let mut bytes = vec![0u8; size as usize];
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(path.as_ptr()),
            PCWSTR(name.as_ptr()),
            RRF_RT_ANY,
            Some(&mut kind),
            Some(bytes.as_mut_ptr().cast()),
            Some(&mut size),
        )
        .ok()
        .map_err(error)?;
        bytes.truncate(size as usize);
        Ok(Some((kind, bytes)))
    }
}
fn dword(path: &str, name: &str) -> Result<Option<u32>, String> {
    registry(path, name)?
        .map(|(kind, bytes)| {
            if kind != REG_DWORD || bytes.len() != 4 {
                return Err(format!("Invalid RDP DWORD: {name}"));
            }
            Ok(u32::from_le_bytes(bytes.try_into().unwrap()))
        })
        .transpose()
}
fn string(kind: REG_VALUE_TYPE, bytes: &[u8]) -> Result<String, String> {
    if kind != REG_SZ || bytes.len() % 2 != 0 {
        return Err("Invalid RDP registry string".into());
    }
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|v| u16::from_le_bytes([v[0], v[1]]))
        .take_while(|u| *u != 0)
        .collect();
    String::from_utf16(&units).map_err(error)
}
fn selected_sha1() -> Result<Option<Vec<u8>>, String> {
    let Some((kind, bytes)) = registry(LISTENER, "SSLCertificateSHA1Hash")? else {
        return Ok(None);
    };
    let hash = if kind == REG_BINARY {
        bytes
    } else {
        let text = string(kind, &bytes)?;
        let text: String = text
            .chars()
            .filter(|c| !c.is_ascii_whitespace() && *c != ':')
            .collect();
        if text.len() != 40 || !text.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err("Malformed RDP-Tcp SSLCertificateSHA1Hash".into());
        }
        (0..40)
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).map_err(error))
            .collect::<Result<Vec<_>, _>>()?
    };
    if hash.len() != 20 {
        return Err("Malformed RDP-Tcp SSLCertificateSHA1Hash".into());
    }
    Ok(Some(hash))
}
fn session_text(session: u32, class: WTS_INFO_CLASS) -> Result<String, String> {
    unsafe {
        let mut text = SessionText(PWSTR::null());
        let mut count = 0;
        WTSQuerySessionInformationW(None, session, class, &mut text.0, &mut count)
            .map_err(error)?;
        if text.0.is_null() || count < 2 || count > 65536 || count % 2 != 0 {
            return Err("RDP user name unavailable".into());
        }
        let units = slice::from_raw_parts(text.0.0, count as usize / 2);
        let end = units.iter().position(|v| *v == 0).unwrap_or(units.len());
        String::from_utf16(&units[..end]).map_err(error)
    }
}
fn certificate() -> Result<Value, String> {
    let selected = selected_sha1()?;
    unsafe {
        let store = Store(
            CertOpenStore(
                CERT_STORE_PROV_SYSTEM_W,
                CERT_QUERY_ENCODING_TYPE(0),
                None,
                CERT_OPEN_STORE_FLAGS(CERT_SYSTEM_STORE_LOCAL_MACHINE)
                    | CERT_STORE_READONLY_FLAG
                    | CERT_STORE_OPEN_EXISTING_FLAG,
                Some(w!("Remote Desktop").as_ptr().cast()),
            )
            .map_err(error)?,
        );
        let mut cursor = CertificateCursor(ptr::null());
        let mut candidates: Vec<(String, String)> = Vec::new();
        loop {
            // Enumeration consumes the previous context, including on an error.
            let previous = std::mem::replace(&mut cursor.0, ptr::null());
            cursor.0 =
                CertEnumCertificatesInStore(store.0, (!previous.is_null()).then_some(previous));
            if cursor.0.is_null() {
                let code = GetLastError();
                if code.0 == CRYPT_E_NOT_FOUND.0 as u32 || code == ERROR_NO_MORE_FILES {
                    break;
                }
                return Err(format!("Could not enumerate RDP certificates: {}", code.0));
            }
            let context = &*cursor.0;
            let mut sha1 = [0u8; 20];
            let mut size = sha1.len() as u32;
            CertGetCertificateContextProperty(
                cursor.0,
                CERT_SHA1_HASH_PROP_ID,
                Some(sha1.as_mut_ptr().cast()),
                &mut size,
            )
            .map_err(error)?;
            if size != 20 {
                return Err("Invalid RDP certificate SHA1 identity".into());
            }
            if selected
                .as_ref()
                .is_some_and(|hash| hash.as_slice() != sha1)
            {
                continue;
            }
            if context.pCertInfo.is_null() || CertVerifyTimeValidity(None, context.pCertInfo) != 0 {
                if selected.is_some() {
                    return Err("Selected RDP certificate is not currently valid".into());
                }
                continue;
            }
            if context.pbCertEncoded.is_null()
                || context.cbCertEncoded == 0
                || context.cbCertEncoded > 1024 * 1024
            {
                return Err("Invalid RDP certificate DER".into());
            }
            let der = slice::from_raw_parts(context.pbCertEncoded, context.cbCertEncoded as usize);
            let sha256 = format!("{:x}", Sha256::digest(der));
            if !candidates.iter().any(|(hash, _)| *hash == sha256) {
                candidates.push((sha256, sha1.iter().map(|v| format!("{v:02x}")).collect()));
            }
        }
        if candidates.len() != 1 {
            return Err(if selected.is_some() {
                "RDP-Tcp certificate binding was not uniquely found in LocalMachine/Remote Desktop"
            } else {
                "No unique currently valid certificate in LocalMachine/Remote Desktop; refusing to guess the RDP pin"
            }.into());
        }
        let (sha256, sha1) = candidates.pop().unwrap();
        Ok(
            json!({"sha256":sha256,"sha1":sha1,"selection":if selected.is_some(){"rdpTcpSha1"}else{"uniqueValid"},
            "store":"LocalMachine/Remote Desktop","validNow":true}),
        )
    }
}

/// Invoke in the authenticated interactive worker. A missing/ambiguous pin is an error.
pub fn rdp_info() -> Result<Value, String> {
    let (sid, session) = identity::current()?;
    let user = session_text(session, WTSUserName)?;
    let domain = session_text(session, WTSDomainName)?;
    if user.is_empty() {
        return Err("Interactive RDP user name unavailable".into());
    }
    let username = if domain.is_empty() {
        user.clone()
    } else {
        format!("{domain}\\{user}")
    };
    let edition = registry(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion", "EditionID")?
        .map(|(kind, bytes)| string(kind, &bytes))
        .transpose()?;
    Ok(
        json!({"username":username,"user":user,"domain":domain,"sid":sid,"sessionId":session,"edition":edition,
        "fDenyTSConnections":dword(TERMINAL,"fDenyTSConnections")?,
        "nla":dword(LISTENER,"UserAuthentication")?,"securityLayer":dword(LISTENER,"SecurityLayer")?,
        "policy":{"fDenyTSConnections":dword(POLICY,"fDenyTSConnections")?,
            "nla":dword(POLICY,"UserAuthentication")?,"securityLayer":dword(POLICY,"SecurityLayer")?},
        "certificate":certificate()?}),
    )
}

/// Ask the fixed SYSTEM service to return this user's session to the console.
/// UAC consent, when required by Windows, remains in the normal `runas` flow.
/// Acceptance is not proof that the console or the guest connection has recovered.
pub fn return_console() -> Result<Value, String> {
    use windows::Win32::{
        Foundation::{WAIT_FAILED, WAIT_OBJECT_0, WAIT_TIMEOUT},
        System::{
            SystemInformation::GetSystemDirectoryW,
            Threading::{GetExitCodeProcess, WaitForSingleObject},
        },
        UI::{
            Shell::{
                SEE_MASK_FLAG_NO_UI, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW,
            },
            WindowsAndMessaging::SW_HIDE,
        },
    };

    let (_, session) = identity::current()?;
    unsafe {
        // Resolve the system executable through Windows, never PATH or WINDIR.
        let mut directory = vec![0u16; 32768];
        let count = GetSystemDirectoryW(Some(&mut directory)) as usize;
        if count == 0 {
            return Err(format!(
                "Could not resolve the Windows system directory: {}",
                GetLastError().0
            ));
        }
        if count >= directory.len() {
            return Err("The Windows system directory path is too long".into());
        }
        directory.truncate(count);
        directory.extend("\\sc.exe".encode_utf16());
        directory.push(0);
        let mut execute = SHELLEXECUTEINFOW {
            cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
            fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI,
            lpVerb: w!("runas"),
            lpFile: PCWSTR(directory.as_ptr()),
            lpParameters: w!("control PerpendicularRestart 128"),
            nShow: SW_HIDE.0,
            ..Default::default()
        };
        ShellExecuteExW(&mut execute).map_err(error)?;
        if execute.hProcess.is_invalid() {
            return Err("Windows did not return a handle for the console-return request".into());
        }
        let process = identity::Handle(execute.hProcess);
        let acceptance = match WaitForSingleObject(process.0, 2000) {
            WAIT_OBJECT_0 => {
                let mut code = 0;
                GetExitCodeProcess(process.0, &mut code).map_err(error)?;
                if code != 0 {
                    return Err(format!(
                        "The console-return service control failed: sc.exe exit code {code}"
                    ));
                }
                "serviceControl"
            }
            WAIT_TIMEOUT => "elevationLaunched",
            WAIT_FAILED => {
                return Err(format!(
                    "Could not wait for the console-return request: {}",
                    GetLastError().0
                ));
            }
            other => {
                return Err(format!(
                    "Unexpected console-return wait result: {}",
                    other.0
                ));
            }
        };
        Ok(
            json!({"accepted":true,"acceptance":acceptance,"sessionId":session,
            "consoleReconnected":null,"verificationRequired":true}),
        )
    }
}
