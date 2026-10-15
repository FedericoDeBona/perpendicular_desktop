use crate::error::{Error, Result};
use serde::Serialize;
use std::env;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Serialize, Default)]
pub struct Tools {
    pub qemu_path: Option<PathBuf>,
    pub qemu_img_path: Option<PathBuf>,
    pub firmware_code_path: Option<PathBuf>,
    pub firmware_vars_path: Option<PathBuf>,
    pub swtpm_path: Option<PathBuf>,
    pub guest_tools_iso_path: Option<PathBuf>,
    pub firmware_secure_boot_capable: bool,
}

fn executable(path: &Path) -> Option<PathBuf> {
    let metadata = path.metadata().ok()?;
    if metadata.is_file() && metadata.permissions().mode() & 0o111 != 0 {
        path.canonicalize().ok()
    } else {
        None
    }
}

fn tool(override_key: &str, name: &str, roots: &[PathBuf]) -> Option<PathBuf> {
    // An explicit but invalid override stays unavailable; never silently run a
    // different executable than the one the operator selected.
    if let Some(path) = env::var_os(override_key) {
        return executable(Path::new(&path));
    }
    for root in roots {
        for directory in [
            root.clone(),
            root.join("bin"),
            root.join("QEMU/bin"),
            root.join(".tools/bin"),
            root.join(".tools/qemu/bin"),
        ] {
            if let Some(path) = executable(&directory.join(name)) {
                return Some(path);
            }
        }
    }
    for directory in env::split_paths(&env::var_os("PATH").unwrap_or_default()) {
        if let Some(path) = executable(&directory.join(name)) {
            return Some(path);
        }
    }
    for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        if let Some(path) = executable(&Path::new(directory).join(name)) {
            return Some(path);
        }
    }
    None
}

impl Tools {
    pub fn discover() -> Self {
        let mut roots = Vec::new();
        if let Ok(exe) = env::current_exe() {
            for ancestor in exe.ancestors().skip(1).take(6) {
                roots.push(ancestor.join("Resources"));
                roots.push(ancestor.join("../Resources"));
                roots.push(ancestor.to_path_buf());
            }
        }
        if let Some(repo) = Path::new(env!("CARGO_MANIFEST_DIR")).parent() {
            roots.push(repo.into());
        }
        let qemu_path = tool("PERPENDICULAR_QEMU", "qemu-system-aarch64", &roots);
        let qemu_img_path = tool("PERPENDICULAR_QEMU_IMG", "qemu-img", &roots);
        let swtpm_path = tool("PERPENDICULAR_SWTPM", "swtpm", &roots);
        let guest_tools_iso_path = if let Some(path) = env::var_os("PERPENDICULAR_GUEST_TOOLS_ISO")
        {
            PathBuf::from(path)
                .canonicalize()
                .ok()
                .filter(|path| path.is_file())
        } else {
            roots
                .iter()
                .flat_map(|root| {
                    [
                        root.join("perpendicular-drivers.iso"),
                        root.join(".tools/downloads/perpendicular-drivers.iso"),
                    ]
                })
                .find_map(|path| path.canonicalize().ok().filter(|path| path.is_file()))
        };
        let firmware_override = env::var_os("PERPENDICULAR_FIRMWARE_DIR");
        let mut firmware_roots = Vec::new();
        if let Some(root) = &firmware_override {
            firmware_roots.push(PathBuf::from(root));
        } else {
            for root in &roots {
                firmware_roots.extend([
                    root.join("qemu"),
                    root.join("QEMU/share/qemu"),
                    root.join("share/qemu"),
                    root.join(".tools/qemu/share/qemu"),
                    root.join(".tools/firmware"),
                ]);
            }
            if let Some(prefix) = qemu_path
                .as_deref()
                .and_then(Path::parent)
                .and_then(Path::parent)
            {
                firmware_roots.push(prefix.join("share/qemu"));
            }
            firmware_roots.extend([
                PathBuf::from("/opt/homebrew/share/qemu"),
                PathBuf::from("/usr/local/share/qemu"),
            ]);
        }
        // Pair code and variables from the same directory/profile; never mix a
        // secure template with unrelated ordinary firmware.
        let mut firmware = None;
        for (code, vars, secure) in [
            (
                "edk2-aarch64-secure-code.fd",
                "edk2-arm-secure-vars.fd",
                true,
            ),
            ("edk2-aarch64-code.fd", "edk2-arm-vars.fd", false),
            ("AAVMF_CODE.ms.fd", "AAVMF_VARS.ms.fd", true),
            ("AAVMF_CODE.fd", "AAVMF_VARS.fd", false),
        ] {
            for root in &firmware_roots {
                let code = root.join(code);
                let vars = root.join(vars);
                if code.is_file() && vars.is_file() {
                    if let (Ok(code), Ok(vars)) = (code.canonicalize(), vars.canonicalize()) {
                        firmware = Some((code, vars, secure));
                        break;
                    }
                }
            }
            if firmware.is_some() {
                break;
            }
        }
        let (firmware_code_path, firmware_vars_path, firmware_secure_boot_capable) = match firmware
        {
            Some((code, vars, secure)) => (Some(code), Some(vars), secure),
            None => (None, None, false),
        };
        Self {
            qemu_path,
            qemu_img_path,
            firmware_code_path,
            firmware_vars_path,
            swtpm_path,
            guest_tools_iso_path,
            firmware_secure_boot_capable,
        }
    }

    pub fn require<'a>(&'a self, value: &'a Option<PathBuf>, label: &str) -> Result<&'a Path> {
        value.as_deref().ok_or_else(|| Error::new("dependency_missing", format!("{label} is unavailable. Run scripts/bootstrap.sh or set the documented PERPENDICULAR tool override.")))
    }
}

pub fn run_output(command: &mut Command, description: &str) -> Result<()> {
    let output = command.output().map_err(|e| Error::io(description, e))?;
    if !output.status.success() {
        return Err(Error::new(
            "tool_failed",
            format!(
                "{description} failed ({}): {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        ));
    }
    Ok(())
}

pub fn host_memory_bytes() -> u64 {
    #[cfg(target_os = "macos")]
    return sysctl_number("hw.memsize");
    #[cfg(not(target_os = "macos"))]
    return 0;
}

pub fn hypervisor_available() -> bool {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    return sysctl_number("kern.hv_support") == 1;
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    return false;
}

#[cfg(target_os = "macos")]
fn sysctl_number(key: &str) -> u64 {
    Command::new("/usr/sbin/sysctl")
        .args(["-n", key])
        .output()
        .ok()
        .and_then(|result| String::from_utf8(result.stdout).ok())
        .and_then(|result| result.trim().parse().ok())
        .unwrap_or(0)
}
