use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub format_version: u32,
    pub id: String,
    pub name: String,
    pub cpus: u16,
    pub memory_mib: u64,
    pub disk_gib: u64,
    pub iso_path: Option<PathBuf>,
    #[serde(default)]
    pub guest_tools_iso_path: Option<PathBuf>,
    pub created_at: String,
    pub firmware_code_path: PathBuf,
    pub tpm_enabled: bool,
    /// Capable firmware is insufficient evidence that keys are enrolled or
    /// Secure Boot is enabled in the guest; runtime verification is required.
    pub secure_boot_state: String,
    pub mac_address: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Runtime {
    pub pid: u32,
    pub process_started_at: String,
    pub launch_name: String,
    pub shutdown_requested: bool,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Vm {
    pub id: String,
    pub name: String,
    pub state: String,
    pub cpus: u16,
    pub memory_mib: u64,
    pub disk_gib: u64,
    pub iso_path: Option<PathBuf>,
    pub guest_tools_iso_path: Option<PathBuf>,
    pub directory: PathBuf,
    pub disk_path: PathBuf,
    pub created_at: String,
    pub backend: &'static str,
    pub qmp_socket: PathBuf,
    pub vnc_socket: PathBuf,
    pub last_error: Option<String>,
    pub tpm_enabled: bool,
    pub secure_boot_state: String,
    pub mac_address: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub id: String,
    pub name: String,
    pub created_at: String,
    pub vm_id: String,
    pub consistency: String,
}

pub fn validate_name(name: &str) -> Result<()> {
    if name.trim().is_empty() || name.chars().count() > 100 || name.chars().any(char::is_control) {
        return Err(Error::new(
            "invalid_name",
            "Name must contain 1–100 visible characters",
        ));
    }
    Ok(())
}

pub fn validate_resources(cpus: u16, memory_mib: u64, disk_gib: u64) -> Result<()> {
    if !(1..=256).contains(&cpus) {
        return Err(Error::new(
            "invalid_cpus",
            "CPU count must be between 1 and 256",
        ));
    }
    if !(4096..=1_048_576).contains(&memory_mib) {
        return Err(Error::new(
            "invalid_memory",
            "Windows 11 ARM requires at least 4096 MiB; maximum is 1048576 MiB",
        ));
    }
    if !(64..=16_384).contains(&disk_gib) {
        return Err(Error::new(
            "invalid_disk",
            "Windows 11 requires a disk of at least 64 GiB; maximum is 16384 GiB",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resources_enforce_windows_minimums_and_sane_limits() {
        assert!(validate_resources(4, 8192, 64).is_ok());
        for (c, m, d) in [
            (0, 8192, 64),
            (257, 8192, 64),
            (4, 2048, 64),
            (4, 8192, 32),
            (4, u64::MAX, 64),
        ] {
            assert!(validate_resources(c, m, d).is_err());
        }
        assert!(validate_name("   ").is_err());
        assert!(validate_name("Windows\n11").is_err());
    }
}
