//! A device inventory query only: no machine, disk, firmware, network or HVF.
use crate::error::{Error, Result};
use serde::Serialize;
use std::collections::BTreeSet;
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const MAX_OUTPUT: usize = 256 * 1024;
const DEADLINE: Duration = Duration::from_secs(3);

#[derive(Debug, Serialize)]
pub struct Availability {
    pub available: bool,
    pub code: String,
    pub reason: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Capabilities {
    pub ramfb: Availability,
    #[serde(rename = "virtio-ramfb")]
    pub virtio_ramfb: Availability,
}

struct ProbeChild(Child);
impl Drop for ProbeChild {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}

fn nonblocking(pipe: &impl AsRawFd) -> Result<()> {
    // Owned stdout/stderr pipes only; never alter a VM socket or another FD.
    let flags = unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(Error::new(
            "display_adapter_probe_failed",
            format!(
                "Cannot bound QEMU device inventory: {}",
                io::Error::last_os_error()
            ),
        ));
    }
    Ok(())
}

fn drain(pipe: &mut impl Read, bytes: &mut Vec<u8>, total: &mut usize) -> Result<bool> {
    let mut buffer = [0u8; 8192];
    loop {
        match pipe.read(&mut buffer) {
            Ok(0) => return Ok(true),
            Ok(count) => {
                *total += count;
                if *total > MAX_OUTPUT {
                    return Err(Error::new(
                        "display_adapter_probe_output_limit",
                        "Selected QEMU device inventory exceeded the 256 KiB output bound",
                    ));
                }
                bytes.extend_from_slice(&buffer[..count]);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => {
                return Err(Error::new(
                    "display_adapter_probe_failed",
                    format!("Cannot read selected QEMU device inventory: {error}"),
                ))
            }
        }
    }
}

fn parse_devices(text: &str) -> BTreeSet<String> {
    text.lines()
        .filter_map(|line| {
            let rest = line.trim_start().strip_prefix("name \"")?;
            let (name, tail) = rest.split_once('"')?;
            if !tail.starts_with(',')
                || name.is_empty()
                || name.len() > 128
                || !name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
            {
                return None;
            }
            Some(name.to_owned())
        })
        .collect()
}

fn inventory(qemu: &Path, timeout: Duration) -> Result<BTreeSet<String>> {
    let mut child = ProbeChild(
        Command::new(qemu)
            .args(["-device", "help"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| {
                Error::new(
                    "display_adapter_probe_failed",
                    format!("Cannot query selected QEMU display devices: {error}"),
                )
            })?,
    );
    let mut stdout = child.0.stdout.take().expect("owned inventory stdout");
    let mut stderr = child.0.stderr.take().expect("owned inventory stderr");
    nonblocking(&stdout)?;
    nonblocking(&stderr)?;
    let mut output = Vec::new();
    let mut errors = Vec::new();
    let mut total = 0;
    let end = Instant::now() + timeout;
    loop {
        let out_done = drain(&mut stdout, &mut output, &mut total)?;
        let err_done = drain(&mut stderr, &mut errors, &mut total)?;
        if let Some(status) = child.0.try_wait().map_err(|error| {
            Error::new(
                "display_adapter_probe_failed",
                format!("Cannot collect QEMU device inventory: {error}"),
            )
        })? {
            if out_done && err_done {
                if !status.success() {
                    return Err(Error::new(
                        "display_adapter_probe_failed",
                        format!("Selected QEMU device inventory failed ({status})"),
                    ));
                }
                output.push(b'\n');
                output.extend_from_slice(&errors);
                let text = std::str::from_utf8(&output).map_err(|_| {
                    Error::new(
                        "display_adapter_probe_failed",
                        "Selected QEMU device inventory was not UTF-8",
                    )
                })?;
                let devices = parse_devices(text);
                if devices.is_empty() {
                    return Err(Error::new(
                        "display_adapter_probe_failed",
                        "Selected QEMU returned no recognizable device inventory",
                    ));
                }
                return Ok(devices);
            }
        }
        if Instant::now() >= end {
            return Err(Error::new(
                "display_adapter_probe_timeout",
                "Selected QEMU device inventory exceeded the 3-second deadline",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn availability(devices: &BTreeSet<String>, name: &str) -> Availability {
    if devices.contains(name) {
        Availability {
            available: true,
            code: "supported".into(),
            reason: None,
        }
    } else {
        Availability { available: false, code: "display_adapter_unsupported".into(), reason: Some(format!("Selected QEMU does not provide {name}; this display adapter cannot start with that runtime")) }
    }
}

pub fn capabilities(qemu: Option<&Path>) -> Capabilities {
    let result = qemu
        .ok_or_else(|| {
            Error::new(
                "dependency_missing",
                "The selected QEMU runtime is unavailable",
            )
        })
        .and_then(|path| inventory(path, DEADLINE));
    match result {
        Ok(devices) => Capabilities {
            ramfb: availability(&devices, "ramfb"),
            virtio_ramfb: availability(&devices, "virtio-ramfb"),
        },
        Err(error) => {
            let unavailable = || Availability {
                available: false,
                code: error.code.clone(),
                reason: Some(error.message.clone()),
            };
            Capabilities {
                ramfb: unavailable(),
                virtio_ramfb: unavailable(),
            }
        }
    }
}

pub fn require_hybrid(qemu: &Path) -> Result<()> {
    let devices = inventory(qemu, DEADLINE)?;
    let support = availability(&devices, "virtio-ramfb");
    if support.available {
        Ok(())
    } else {
        Err(Error::new(
            &support.code,
            support.reason.unwrap_or_default(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn executable(body: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("selected-qemu");
        std::fs::write(&path, format!("#!/usr/bin/python3\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        (directory, path)
    }

    #[test]
    fn exact_names_only_and_nonzero_or_malformed_inventory_is_not_support() {
        let names = parse_devices("Display devices:\nname \"ramfb\", bus System\nname \"virtio-ramfb-typo\", desc \"virtio-ramfb\"\nwarning: name \"virtio-ramfb\", text\nname \"virtio-ramfb\" suffix");
        assert!(names.contains("ramfb"));
        assert!(!names.contains("virtio-ramfb"));
        for body in [
            "print('unrecognized output')",
            "import sys; print('name \\\"virtio-ramfb\\\", bus PCI'); sys.exit(1)",
        ] {
            let (_directory, path) = executable(body);
            assert_eq!(
                require_hybrid(&path).unwrap_err().code,
                "display_adapter_probe_failed"
            );
        }
    }

    #[test]
    fn only_device_help_is_run_and_selected_runtime_controls_capability() {
        let (_directory, path) = executable("import sys\nassert sys.argv[1:] == ['-device','help']\nprint('name \\\"ramfb\\\", bus System')\nprint('name \\\"virtio-ramfb\\\", bus PCI', file=sys.stderr)");
        let support = capabilities(Some(&path));
        assert!(support.ramfb.available && support.virtio_ramfb.available);
        require_hybrid(&path).unwrap();
        let (_directory, path) = executable("print('name \\\"ramfb\\\", bus System')");
        assert_eq!(
            require_hybrid(&path).unwrap_err().code,
            "display_adapter_unsupported"
        );
        assert_eq!(capabilities(None).virtio_ramfb.code, "dependency_missing");
    }

    #[test]
    fn output_and_time_are_bounded_and_owned_probe_is_reaped() {
        let (_directory, path) = executable("import os\nos.write(1, b'x' * 300000)");
        assert_eq!(
            require_hybrid(&path).unwrap_err().code,
            "display_adapter_probe_output_limit"
        );
        let (directory, path) = executable("");
        std::fs::write(
            &path,
            "#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\nexec /bin/sleep 30\n",
        )
        .unwrap();
        assert_eq!(
            inventory(&path, Duration::from_secs(1)).unwrap_err().code,
            "display_adapter_probe_timeout"
        );
        let pid: i32 = std::fs::read_to_string(directory.path().join("selected-qemu.pid"))
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(
            unsafe { libc::kill(pid, 0) },
            -1,
            "only the fixture-owned probe must be gone/reaped"
        );
    }
}
