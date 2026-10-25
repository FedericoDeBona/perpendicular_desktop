use super::{Configuration, error};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    sync::mpsc,
    time::Duration,
};
use windows::{
    Win32::{
        Foundation::{CloseHandle, HANDLE, HLOCAL, LocalFree},
        Security::{
            Authorization::ConvertSidToStringSidW, GetTokenInformation, TOKEN_USER, TokenUser,
        },
        System::{
            Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock},
            RemoteDesktop::{
                WTSActive, WTSEnumerateSessionsW, WTSFreeMemory, WTSGetActiveConsoleSessionId,
                WTSQueryUserToken,
            },
            Threading::{
                CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW,
                GetExitCodeProcess, PROCESS_INFORMATION, STARTUPINFOW, TerminateProcess,
            },
        },
    },
    core::{PCWSTR, PWSTR, w},
};
use windows_service::{
    define_windows_service,
    service::{
        ServiceAccess, ServiceControl, ServiceControlAccept, ServiceErrorControl, ServiceExitCode,
        ServiceInfo, ServiceStartType, ServiceState, ServiceStatus, ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
    service_manager::{ServiceManager, ServiceManagerAccess},
};

const NAME: &str = "PerpendicularRestart";
pub fn directory() -> PathBuf {
    PathBuf::from(std::env::var_os("ProgramData").unwrap_or_else(|| "C:\\ProgramData".into()))
        .join("Perpendicular Restart")
}
fn log(message: impl std::fmt::Display) {
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(directory().join("service.log"))
    {
        let _ = writeln!(file, "{message}");
    }
}
pub fn install(config: &Path) -> Result<(), String> {
    use sha2::{Digest, Sha256};
    let mut configuration: Configuration =
        serde_json::from_slice(&std::fs::read(config).map_err(error)?).map_err(error)?;
    if configuration.token.len() != 64 || configuration.port < 1024 {
        return Err("Invalid installation configuration".into());
    }
    configuration.owner_sid = Some(super::identity::current()?.0);
    let root = directory();
    std::fs::create_dir_all(&root).map_err(error)?;
    let source = std::env::current_exe().map_err(error)?;
    let bytes = std::fs::read(&source).map_err(error)?;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    let version = root.join(format!("0.1.0-{}", &digest[..12]));
    std::fs::create_dir_all(&version).map_err(error)?;
    let executable = version.join("perpendicular-guest.exe");
    // A repeated install can target the currently running version. Windows
    // locks its executable, so retain a byte-identical file instead of rewriting.
    if std::fs::read(&executable).ok().as_deref() != Some(bytes.as_slice()) {
        std::fs::write(&executable, &bytes).map_err(error)?;
    }
    super::cloak::install(&version)?;
    std::fs::write(
        root.join("connection.json"),
        serde_json::to_vec_pretty(&configuration).map_err(error)?,
    )
    .map_err(error)?;
    let manager = ServiceManager::local_computer(
        None::<&str>,
        ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE,
    )
    .map_err(error)?;
    let info = ServiceInfo {
        name: NAME.into(),
        display_name: "Perpendicular Guest".into(),
        service_type: ServiceType::OWN_PROCESS,
        start_type: ServiceStartType::AutoStart,
        error_control: ServiceErrorControl::Normal,
        executable_path: executable,
        launch_arguments: vec!["service".into()],
        dependencies: vec![],
        account_name: None,
        account_password: None,
    };
    let access = ServiceAccess::QUERY_STATUS
        | ServiceAccess::START
        | ServiceAccess::STOP
        | ServiceAccess::CHANGE_CONFIG;
    let service = match manager.open_service(NAME, access) {
        Ok(service) => {
            let _ = service.stop();
            for _ in 0..30 {
                if service.query_status().map_err(error)?.current_state == ServiceState::Stopped {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            service.change_config(&info).map_err(error)?;
            service
        }
        Err(_) => manager.create_service(&info, access).map_err(error)?,
    };
    service
        .set_description("Supervises the Perpendicular bridge in the interactive Windows session.")
        .map_err(error)?;
    service.start::<&str>(&[]).map_err(error)?;
    log("Installed guest service 0.1.0");
    Ok(())
}

define_windows_service!(service_main, entry);
pub fn run() -> Result<(), String> {
    service_dispatcher::start(NAME, service_main).map_err(error)
}
fn entry(_: Vec<OsString>) {
    if let Err(e) = supervise() {
        log(e);
    }
}

fn supervise() -> Result<(), String> {
    let configuration: Configuration =
        serde_json::from_slice(&std::fs::read(directory().join("connection.json")).map_err(error)?)
            .map_err(error)?;
    let (stop, receiver) = mpsc::channel();
    let status = service_control_handler::register(NAME, move |event| match event {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            let _ = stop.send(());
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    })
    .map_err(error)?;
    let report = |state, controls| {
        status
            .set_service_status(ServiceStatus {
                service_type: ServiceType::OWN_PROCESS,
                current_state: state,
                controls_accepted: controls,
                exit_code: ServiceExitCode::Win32(0),
                checkpoint: 0,
                wait_hint: Duration::ZERO,
                process_id: None,
            })
            .map_err(error)
    };
    report(
        ServiceState::Running,
        ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
    )?;
    let mut worker: Option<(super::identity::Handle, u32)> = None;
    let mut selection_error = None;
    log("Service running; waiting for interactive session");
    loop {
        if receiver.recv_timeout(Duration::from_secs(2)).is_ok() {
            break;
        }
        let session = match active_session(configuration.owner_sid.as_deref()) {
            Ok(session) => {
                selection_error = None;
                session
            }
            Err(error) => {
                if selection_error.as_ref() != Some(&error) {
                    log(&error);
                    selection_error = Some(error);
                }
                None
            }
        };
        unsafe {
            if let Some((process, previous)) = &worker {
                let mut code = 0;
                if let Err(error) = GetExitCodeProcess(process.0, &mut code) {
                    log(format!("Cannot inspect worker: {error}"));
                    continue;
                }
                let active = code == 259;
                // A lock, disconnect or ambiguous selection must not kill a healthy
                // worker. Replace it only after confirming a different owner session.
                if !active || session.is_some_and(|session| session != *previous) {
                    if active {
                        if let Err(error) = TerminateProcess(process.0, 0) {
                            log(format!("Cannot replace worker: {error}"));
                            continue;
                        }
                    }
                    worker = None;
                }
            }
            if let Some(session) = session.filter(|_| worker.is_none()) {
                match start_worker(session, configuration.owner_sid.as_deref()) {
                    Ok(process) => {
                        worker = Some((process, session));
                        log(format!("Worker started in session {session}"));
                    }
                    Err(e) => log(e),
                }
            }
        }
    }
    if let Some((process, _)) = worker {
        unsafe {
            let _ = TerminateProcess(process.0, 0);
        }
    }
    report(ServiceState::Stopped, ServiceControlAccept::empty())
}

fn active_session(owner_sid: Option<&str>) -> Result<Option<u32>, String> {
    if let Some(owner_sid) = owner_sid {
        return owner_session(owner_sid);
    }
    // Compatibility for installations whose configuration predates ownerSid.
    unsafe {
        let session = WTSGetActiveConsoleSessionId();
        Ok((session != 0 && session != u32::MAX).then_some(session))
    }
}

fn owner_session(owner_sid: &str) -> Result<Option<u32>, String> {
    unsafe {
        let mut sessions = std::ptr::null_mut();
        let mut count = 0;
        WTSEnumerateSessionsW(None, 0, 1, &mut sessions, &mut count).map_err(error)?;
        let candidates = if count == 0 {
            Vec::new()
        } else if sessions.is_null() {
            return Err("Windows returned an invalid session list".into());
        } else {
            std::slice::from_raw_parts(sessions, count as usize)
                .iter()
                .filter(|session| {
                    session.SessionId != 0
                        && session.SessionId != u32::MAX
                        && session.State == WTSActive
                })
                .map(|session| session.SessionId)
                .collect::<Vec<_>>()
        };
        if !sessions.is_null() {
            WTSFreeMemory(sessions.cast());
        }
        let mut selected = None;
        for session in candidates {
            let mut token = HANDLE::default();
            WTSQueryUserToken(session, &mut token).map_err(error)?;
            let token = super::identity::Handle(token);
            if token_sid(token.0)? == owner_sid {
                if selected.is_some() {
                    return Err("Multiple active sessions for the guest owner; waiting".into());
                }
                selected = Some(session);
            }
        }
        Ok(selected)
    }
}

// identity::sid takes a process handle; WTS supplies a token directly.
fn token_sid(token: HANDLE) -> Result<String, String> {
    unsafe {
        let mut size = 0;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut size);
        if size == 0 || size > 65536 {
            return Err("Session user identity unavailable".into());
        }
        let mut data = vec![0u64; (size as usize).div_ceil(8)];
        GetTokenInformation(
            token,
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

unsafe fn start_worker(
    session: u32,
    owner_sid: Option<&str>,
) -> Result<super::identity::Handle, String> {
    unsafe {
        if session == 0 || session == u32::MAX {
            return Err("Interactive user session required".into());
        }
        let mut token = HANDLE::default();
        WTSQueryUserToken(session, &mut token).map_err(error)?;
        let token = super::identity::Handle(token);
        if let Some(owner_sid) = owner_sid {
            if token_sid(token.0)? != owner_sid {
                return Err("Session owner changed before starting the worker".into());
            }
        }
        let executable = std::env::current_exe().map_err(error)?;
        let mut line: Vec<u16> = format!(
            "\"{}\" worker \"{}\"",
            executable.display(),
            directory().join("connection.json").display()
        )
        .encode_utf16()
        .chain([0])
        .collect();
        let application: Vec<u16> = executable
            .as_os_str()
            .to_string_lossy()
            .encode_utf16()
            .chain([0])
            .collect();
        let mut environment = std::ptr::null_mut();
        CreateEnvironmentBlock(&mut environment, Some(token.0), false).map_err(error)?;
        let mut startup = STARTUPINFOW::default();
        startup.cb = size_of::<STARTUPINFOW>() as u32;
        startup.lpDesktop = PWSTR(w!("winsta0\\default").0 as *mut _);
        let mut process = PROCESS_INFORMATION::default();
        let result = CreateProcessAsUserW(
            Some(token.0),
            PCWSTR(application.as_ptr()),
            Some(PWSTR(line.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
            Some(environment),
            PCWSTR::null(),
            &startup,
            &mut process,
        )
        .map_err(error);
        let _ = DestroyEnvironmentBlock(environment);
        result?;
        let _ = CloseHandle(process.hThread);
        Ok(super::identity::Handle(process.hProcess))
    }
}
