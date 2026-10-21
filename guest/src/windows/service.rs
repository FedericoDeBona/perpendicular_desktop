use super::{Configuration, error};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    sync::mpsc,
    time::Duration,
};
use windows::{
    Win32::{
        Foundation::{CloseHandle, HANDLE},
        System::{
            Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock},
            RemoteDesktop::{WTSGetActiveConsoleSessionId, WTSQueryUserToken},
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
    let configuration: Configuration =
        serde_json::from_slice(&std::fs::read(config).map_err(error)?).map_err(error)?;
    if configuration.token.len() != 64 || configuration.port < 1024 {
        return Err("Invalid installation configuration".into());
    }
    let root = directory();
    std::fs::create_dir_all(&root).map_err(error)?;
    let source = std::env::current_exe().map_err(error)?;
    let bytes = std::fs::read(&source).map_err(error)?;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    let version = root.join(format!("0.1.0-{}", &digest[..12]));
    std::fs::create_dir_all(&version).map_err(error)?;
    let executable = version.join("perpendicular-guest.exe");
    std::fs::write(&executable, bytes).map_err(error)?;
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
    log("Service running; waiting for interactive session");
    loop {
        if receiver.recv_timeout(Duration::from_secs(2)).is_ok() {
            break;
        }
        unsafe {
            let session = WTSGetActiveConsoleSessionId();
            if let Some((process, previous)) = &worker {
                let mut code = 0;
                let active = GetExitCodeProcess(process.0, &mut code).is_ok() && code == 259;
                if !active || *previous != session {
                    if active {
                        let _ = TerminateProcess(process.0, 0);
                    }
                    worker = None;
                }
            }
            if worker.is_none() && session != u32::MAX {
                match start_worker(session) {
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

unsafe fn start_worker(session: u32) -> Result<super::identity::Handle, String> {
    unsafe {
        let mut token = HANDLE::default();
        WTSQueryUserToken(session, &mut token).map_err(error)?;
        let token = super::identity::Handle(token);
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
