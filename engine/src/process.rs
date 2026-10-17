use crate::command::{qemu_arguments, swtpm_arguments};
use crate::error::{Error, Result};
use crate::model::{Config, Runtime};
use crate::storage::{atomic_json, private_dir, read_json};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaunchJob {
    pub config: Config,
    pub vm_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub launch_name: String,
    pub qemu: PathBuf,
    pub swtpm: Option<PathBuf>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ExitRecord {
    pub launch_name: String,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub error: Option<String>,
    pub exited_at: String,
}

pub enum ProcessState {
    Gone,
    OwnedLive,
    Uncertain,
}

pub fn launch_process_exists(launch_name: &str, qmp_path: &Path) -> Result<bool> {
    let output = Command::new("/bin/ps")
        .args(["-ww", "-axo", "command="])
        .output()?;
    if !output.status.success() {
        return Err(Error::new(
            "process_inspection_failed",
            "Cannot establish whether an incomplete VM launch is still running",
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|command| {
            command.contains(launch_name) && command.contains(qmp_path.to_string_lossy().as_ref())
        }))
}

pub fn started_at(pid: u32) -> Option<String> {
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "lstart="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

pub fn process_state(runtime: &Runtime, qmp_path: &Path) -> ProcessState {
    if runtime.pid == 0 || runtime.pid > i32::MAX as u32 {
        return ProcessState::Uncertain;
    }
    match started_at(runtime.pid) {
        Some(start) if start != runtime.process_started_at => ProcessState::Gone,
        Some(_) => {
            let output = Command::new("/bin/ps")
                .args(["-ww", "-p", &runtime.pid.to_string(), "-o", "command="])
                .output();
            match output {
                Ok(output) if output.status.success() => {
                    let command = String::from_utf8_lossy(&output.stdout);
                    if command.contains(&runtime.launch_name)
                        && command.contains(qmp_path.to_string_lossy().as_ref())
                    {
                        ProcessState::OwnedLive
                    } else {
                        ProcessState::Uncertain
                    }
                }
                _ => ProcessState::Uncertain,
            }
        }
        None => {
            // This read-only existence probe never signals a process. An
            // ambiguous ps failure cannot make a disk safe for mutation.
            let result = unsafe { libc::kill(runtime.pid as i32, 0) };
            if result < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
                ProcessState::Gone
            } else {
                ProcessState::Uncertain
            }
        }
    }
}

fn detached(command: &mut Command) {
    // No shell, terminal inheritance, or daemon PID lookup is involved.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

fn log_stdio(path: &Path) -> Result<Stdio> {
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    Ok(Stdio::from(log))
}

pub fn launch_supervisor(job: &LaunchJob) -> Result<Child> {
    atomic_json(&job.runtime_dir.join("launch.json"), job)?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("__supervise")
        .arg(job.runtime_dir.join("launch.json"));
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log_stdio(&job.vm_dir.join("supervisor.log"))?);
    detached(&mut command);
    Ok(command.spawn()?)
}

/// Internal process: retain Child handles for the exact processes we created,
/// wait for QEMU, then stop that swtpm child and record the real QEMU exit code.
pub fn supervise(path: &Path) -> Result<()> {
    let job: LaunchJob = read_json(path)?;
    if !job.runtime_dir.is_absolute()
        || !job.vm_dir.is_absolute()
        || path != job.runtime_dir.join("launch.json")
    {
        return Err(Error::new(
            "invalid_launch",
            "Supervisor launch paths are invalid",
        ));
    }
    private_dir(&job.runtime_dir)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(job.runtime_dir.join("supervisor.lock"))?;
    lock.try_lock_exclusive().map_err(|_| {
        Error::new(
            "already_running",
            "A supervisor already owns this VM runtime",
        )
    })?;
    let result = supervise_inner(&job);
    let record = match result {
        Ok(status) => ExitRecord {
            launch_name: job.launch_name,
            success: status.success(),
            exit_code: status.code(),
            error: None,
            exited_at: chrono::Utc::now().to_rfc3339(),
        },
        Err(error) => ExitRecord {
            launch_name: job.launch_name,
            success: false,
            exit_code: None,
            error: Some(error.message),
            exited_at: chrono::Utc::now().to_rfc3339(),
        },
    };
    atomic_json(&job.runtime_dir.join("exit.json"), &record)?;
    Ok(())
}

fn supervise_inner(job: &LaunchJob) -> Result<std::process::ExitStatus> {
    let mut tpm_child: Option<Child> = None;
    if job.config.tpm_enabled {
        let swtpm = job.swtpm.as_ref().ok_or_else(|| {
            Error::new(
                "dependency_missing",
                "This VM requires swtpm but no swtpm executable is available",
            )
        })?;
        let mut command = Command::new(swtpm);
        command
            .args(swtpm_arguments(&job.runtime_dir)?)
            .current_dir(&job.vm_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log_stdio(&job.vm_dir.join("swtpm.log"))?);
        let mut child = command.spawn()?;
        let deadline = Instant::now() + Duration::from_secs(5);
        while !job.runtime_dir.join("swtpm.sock").exists() {
            if let Some(status) = child.try_wait()? {
                return Err(Error::new(
                    "tpm_start_failed",
                    format!("swtpm exited with {status}; see swtpm.log"),
                ));
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::new(
                    "tpm_start_failed",
                    "swtpm did not create its control socket within 5 seconds",
                ));
            }
            thread::sleep(Duration::from_millis(25));
        }
        tpm_child = Some(child);
    }
    let result = (|| {
        let mut command = Command::new(&job.qemu);
        if job.config.display_adapter == crate::model::DisplayAdapter::VirtioRamfbGl {
            let root = job.qemu.parent().and_then(Path::parent).ok_or_else(|| {
                Error::new(
                    "native_graphics_unavailable",
                    "Native graphics runtime directory is missing",
                )
            })?;
            crate::native_graphics::NativeGraphics::from_directory(root)?.configure(
                &mut command,
                &job.runtime_dir,
                &job.launch_name,
            )?;
        }
        command
            .args(qemu_arguments(
                &job.config,
                &job.vm_dir,
                &job.runtime_dir,
                &job.launch_name,
            )?)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log_stdio(&job.vm_dir.join("qemu.log"))?);
        let mut qemu = command.spawn()?;
        let runtime = Runtime {
            pid: qemu.id(),
            process_started_at: started_at(qemu.id()).unwrap_or_default(),
            launch_name: job.launch_name.clone(),
            shutdown_requested: false,
            last_error: None,
        };
        if let Err(error) = atomic_json(&job.runtime_dir.join("runtime.json"), &runtime) {
            // This is our Child, still held by this process. Never use a stored PID.
            let _ = qemu.kill();
            let _ = qemu.wait();
            return Err(error);
        }
        Ok(qemu.wait()?)
    })();
    if let Some(mut child) = tpm_child {
        if child.try_wait()?.is_none() {
            let _ = child.kill();
        }
        let _ = child.wait();
    }
    result
}
