//! Offline disk export. Conversion never writes the source, and the destination
//! appears only at the atomic, no-replacement publication step.
use crate::disk::{validate_import, DiskInfo};
use crate::error::{Error, Result};
use crate::storage::assert_regular;
use serde::Serialize;
use std::ffi::CString;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;
use uuid::Uuid;

static CANCELLED: AtomicBool = AtomicBool::new(false);

#[derive(Serialize)]
pub struct ExportedDisk {
    pub path: PathBuf,
    pub format: String,
    pub virtual_size_bytes: u64,
    pub size_bytes: u64,
}

pub fn export_disk(
    image_tool: &Path,
    source: &Path,
    destination: &Path,
    format: &str,
) -> Result<ExportedDisk> {
    if !matches!(format, "qcow2" | "raw") {
        return Err(Error::new(
            "unsupported_disk_format",
            "Disk export format must be qcow2 or raw",
        ));
    }
    assert_regular(source)?;
    let destination = export_destination(destination)?;
    let parent = destination.parent().unwrap();
    let staging = Staging::create(parent)?;
    let _signals = CancellationSignals::install()?;
    let source_info = staging.inspect(image_tool, source, "qcow2")?;
    let temporary_disk = staging.path.join("disk");
    staging.run(
        Command::new(image_tool)
            .args(["convert", "-f", "qcow2", "-O", format])
            .arg(source)
            .arg(&temporary_disk),
    )?;
    assert_regular(&temporary_disk)?;
    let converted = staging.inspect(image_tool, &temporary_disk, format)?;
    if converted.format != format || converted.virtual_size != source_info.virtual_size {
        return Err(Error::new(
            "export_verification_failed",
            "Converted disk format or virtual capacity does not match the source",
        ));
    }
    let disk = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temporary_disk)?;
    disk.set_permissions(std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    disk.sync_all()?;
    let size_bytes = disk.metadata()?.len();
    check_cancelled()?;
    staging.publish(&destination)?;
    Ok(ExportedDisk {
        path: destination,
        format: format.into(),
        virtual_size_bytes: converted.virtual_size,
        size_bytes,
    })
}

fn export_destination(destination: &Path) -> Result<PathBuf> {
    if !destination.is_absolute() {
        return Err(Error::new(
            "invalid_destination",
            "Export destination must be an absolute file path",
        ));
    }
    let name = destination.file_name().ok_or_else(|| {
        Error::new(
            "invalid_destination",
            "Export destination must have a file name",
        )
    })?;
    let parent = destination
        .parent()
        .unwrap()
        .canonicalize()
        .map_err(|error| {
            Error::io(
                "Export destination folder must already exist and be accessible",
                error,
            )
        })?;
    if !parent.is_dir() {
        return Err(Error::new(
            "invalid_destination",
            "Export destination parent must be a folder",
        ));
    }
    let destination = parent.join(name);
    if destination.to_str().is_none() {
        return Err(Error::new(
            "invalid_destination",
            "Export destination must be valid UTF-8",
        ));
    }
    match fs::symlink_metadata(&destination) {
        Ok(_) => return Err(destination_exists()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(Error::io("Cannot inspect export destination", error)),
    }
    Ok(destination)
}

fn destination_exists() -> Error {
    Error::new(
        "destination_exists",
        "Export destination already exists; choose a new file name",
    )
}

struct Staging {
    path: PathBuf,
    directory: File,
    parent: File,
}

impl Staging {
    fn create(parent: &Path) -> Result<Self> {
        let parent_handle = File::open(parent)?;
        let path = parent.join(format!(".perpendicular-export-{}", Uuid::new_v4()));
        DirBuilder::new().mode(0o700).create(&path)?;
        let directory = match File::open(&path) {
            Ok(file) => file,
            Err(error) => {
                let _ = fs::remove_dir(&path);
                return Err(error.into());
            }
        };
        Ok(Self {
            path,
            directory,
            parent: parent_handle,
        })
    }

    fn run(&self, command: &mut Command) -> Result<Vec<u8>> {
        check_cancelled()?;
        let stdout_path = self.path.join("stdout");
        let stderr_path = self.path.join("stderr");
        let log = |path: &Path| -> Result<File> {
            Ok(OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(path)?)
        };
        let child = command
            .stdin(Stdio::null())
            .stdout(log(&stdout_path)?)
            .stderr(log(&stderr_path)?)
            .spawn()
            .map_err(|error| Error::io("Cannot start qemu-img for disk export", error))?;
        let mut child = OwnedChild(child);
        let status = loop {
            check_cancelled()?;
            if let Some(status) = child.0.try_wait()? {
                break status;
            }
            thread::sleep(Duration::from_millis(50));
        };
        if !status.success() {
            let mut diagnostic = Vec::new();
            File::open(stderr_path)?
                .take(16384)
                .read_to_end(&mut diagnostic)?;
            return Err(Error::new(
                "export_failed",
                format!(
                    "qemu-img exited with {status}: {}",
                    String::from_utf8_lossy(&diagnostic).trim()
                ),
            ));
        }
        let mut output = Vec::new();
        File::open(stdout_path)?
            .take(1024 * 1024 + 1)
            .read_to_end(&mut output)?;
        if output.len() > 1024 * 1024 {
            return Err(Error::new(
                "export_failed",
                "qemu-img metadata response exceeded 1 MiB",
            ));
        }
        Ok(output)
    }

    fn inspect(&self, image_tool: &Path, path: &Path, format: &str) -> Result<DiskInfo> {
        let output = self.run(
            Command::new(image_tool)
                .args(["info", "-f", format, "--output=json"])
                .arg(path),
        )?;
        let info: DiskInfo = serde_json::from_slice(&output)?;
        validate_import(&info)?;
        Ok(info)
    }

    fn publish(&self, destination: &Path) -> Result<()> {
        let source = c"disk";
        let name = CString::new(destination.file_name().unwrap().as_bytes()).map_err(|_| {
            Error::new(
                "invalid_destination",
                "Export filename contains a null byte",
            )
        })?;
        #[cfg(target_os = "macos")]
        let result = unsafe {
            libc::renameatx_np(
                self.directory.as_raw_fd(),
                source.as_ptr(),
                self.parent.as_raw_fd(),
                name.as_ptr(),
                libc::RENAME_EXCL,
            )
        };
        #[cfg(not(target_os = "macos"))]
        let result = unsafe {
            libc::linkat(
                self.directory.as_raw_fd(),
                source.as_ptr(),
                self.parent.as_raw_fd(),
                name.as_ptr(),
                0,
            )
        };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            return Err(if error.kind() == std::io::ErrorKind::AlreadyExists {
                destination_exists()
            } else {
                Error::io(
                    "Cannot publish completed disk export without replacement",
                    error,
                )
            });
        }
        // Publication is the commit point. Cancellation after this point leaves
        // the complete destination intact and the command reports success.
        self.parent.sync_all()?;
        Ok(())
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        // Only remove our exact private staging directory and known entries.
        // Never traverse a replacement directory or recursively delete data.
        let owned = self
            .directory
            .metadata()
            .ok()
            .zip(fs::symlink_metadata(&self.path).ok())
            .is_some_and(|(expected, actual)| {
                actual.is_dir() && expected.dev() == actual.dev() && expected.ino() == actual.ino()
            });
        if owned {
            for name in ["disk", "stdout", "stderr"] {
                let _ = fs::remove_file(self.path.join(name));
            }
            let _ = fs::remove_dir(&self.path);
        }
    }
}

struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

extern "C" fn request_cancellation(_: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}

fn check_cancelled() -> Result<()> {
    if CANCELLED.load(Ordering::Relaxed) {
        Err(Error::new(
            "export_cancelled",
            "Disk export was cancelled before publication",
        ))
    } else {
        Ok(())
    }
}

struct CancellationSignals(Vec<(libc::c_int, libc::sigaction)>);
impl CancellationSignals {
    fn install() -> Result<Self> {
        CANCELLED.store(false, Ordering::Relaxed);
        let mut guard = Self(Vec::new());
        for signal in [libc::SIGINT, libc::SIGTERM] {
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = request_cancellation as *const () as usize;
            unsafe {
                libc::sigemptyset(&mut action.sa_mask);
            }
            let mut old = unsafe { std::mem::zeroed() };
            if unsafe { libc::sigaction(signal, &action, &mut old) } != 0 {
                return Err(Error::io(
                    "Cannot install export cancellation handler",
                    std::io::Error::last_os_error(),
                ));
            }
            guard.0.push((signal, old));
        }
        Ok(guard)
    }
}
impl Drop for CancellationSignals {
    fn drop(&mut self) {
        for (signal, old) in &self.0 {
            unsafe {
                libc::sigaction(*signal, old, std::ptr::null_mut());
            }
        }
    }
}
