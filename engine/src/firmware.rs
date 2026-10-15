use crate::error::{Error, Result};
use crate::storage::assert_regular;
use crate::tools::run_output;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Command;
use uuid::Uuid;

pub const ARM_FLASH_BYTES: u64 = 64 * 1024 * 1024;

pub fn is_qcow2(path: &Path) -> Result<bool> {
    let mut magic = [0u8; 4];
    let mut file = File::open(path)?;
    Ok(file.read(&mut magic)? == 4 && magic == [b'Q', b'F', b'I', 0xfb])
}

/// UTM's secure variable template is a qcow2 image despite its .fd extension.
/// QEMU's ARM virt flash bank requires a 64 MiB raw backing node. Decode the
/// container; never pad a qcow2 header and expose it as guest flash contents.
pub fn prepare_variables(source: &Path, destination: &Path, image_tool: &Path) -> Result<()> {
    if is_qcow2(source)? {
        let output = Command::new(image_tool)
            .args(["info", "--output=json"])
            .arg(source)
            .output()?;
        if !output.status.success() {
            return Err(Error::new(
                "invalid_firmware",
                format!(
                    "Cannot inspect firmware variable template: {}",
                    String::from_utf8_lossy(&output.stderr)
                ),
            ));
        }
        let info: serde_json::Value = serde_json::from_slice(&output.stdout)?;
        if info.get("backing-filename").is_some()
            || info["virtual-size"].as_u64() != Some(ARM_FLASH_BYTES)
        {
            return Err(Error::new(
                "invalid_firmware",
                "Firmware qcow2 template must be a self-contained 64 MiB image",
            ));
        }
        run_output(
            Command::new(image_tool)
                .args(["convert", "-f", "qcow2", "-O", "raw"])
                .arg(source)
                .arg(destination),
            "Decode firmware variable template",
        )?;
    } else {
        fs::copy(source, destination)?;
    }
    pad_raw_variables(destination)
}

fn pad_raw_variables(path: &Path) -> Result<()> {
    assert_regular(path)?;
    let length = fs::metadata(path)?.len();
    if length == 0 || length > ARM_FLASH_BYTES {
        return Err(Error::new(
            "invalid_firmware",
            "ARM firmware variables must contain 1–67108864 bytes",
        ));
    }
    if is_qcow2(path)? {
        return Err(Error::new(
            "invalid_firmware",
            "Firmware image conversion produced a qcow2 container instead of raw flash",
        ));
    }
    if length < ARM_FLASH_BYTES {
        let mut file = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        file.seek(SeekFrom::Start(length))?;
        let erased = [0xffu8; 64 * 1024];
        let mut remaining = ARM_FLASH_BYTES - length;
        while remaining > 0 {
            let count = usize::try_from(remaining.min(erased.len() as u64)).unwrap();
            file.write_all(&erased[..count])?;
            remaining -= count as u64;
        }
        file.sync_all()?;
    }
    Ok(())
}

/// Repair earlier offline bootstrap data atomically, keeping the original bytes
/// as a recoverable local backup. Caller must already prove the VM is offline.
pub fn repair_variables(path: &Path, image_tool: &Path) -> Result<bool> {
    assert_regular(path)?;
    if !is_qcow2(path)? && fs::metadata(path)?.len() == ARM_FLASH_BYTES {
        return Ok(false);
    }
    let parent = path
        .parent()
        .ok_or_else(|| Error::new("invalid_firmware", "Firmware path has no parent"))?;
    let token = Uuid::new_v4();
    let staging = parent.join(format!(".efi-vars-repair-{token}"));
    let backup = parent.join(format!("efi-vars.before-repair-{token}.fd"));
    if let Err(error) = prepare_variables(path, &staging, image_tool) {
        let _ = fs::remove_file(&staging);
        return Err(error);
    }
    fs::rename(path, &backup)?;
    if let Err(error) = fs::rename(&staging, path) {
        let _ = fs::rename(&backup, path);
        return Err(error.into());
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn raw_flash_extension_preserves_template_and_uses_erased_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source.fd");
        let output = directory.path().join("vars.fd");
        fs::write(&source, b"UEFI-variable-store").unwrap();
        prepare_variables(&source, &output, Path::new("/unused-for-raw")).unwrap();
        assert_eq!(fs::metadata(&output).unwrap().len(), ARM_FLASH_BYTES);
        let mut file = File::open(&output).unwrap();
        let mut prefix = [0u8; 19];
        file.read_exact(&mut prefix).unwrap();
        assert_eq!(&prefix, b"UEFI-variable-store");
        file.seek(SeekFrom::Start(ARM_FLASH_BYTES - 1)).unwrap();
        let mut tail = [0u8; 1];
        file.read_exact(&mut tail).unwrap();
        assert_eq!(tail, [0xff]);
        assert_eq!(fs::read(source).unwrap(), b"UEFI-variable-store");
        assert!(!repair_variables(&output, Path::new("/unused-for-raw")).unwrap());
    }
    #[test]
    #[ignore = "requires PERPENDICULAR_TEST_QEMU_IMG and PERPENDICULAR_TEST_FIRMWARE_VARS"]
    fn real_qcow2_template_conversion_and_offline_repair_preserve_guest_bytes() {
        let image = std::env::var_os("PERPENDICULAR_TEST_QEMU_IMG").expect("set image tool path");
        let template =
            std::env::var_os("PERPENDICULAR_TEST_FIRMWARE_VARS").expect("set qcow2 template path");
        let image = Path::new(&image);
        let template = Path::new(&template);
        assert!(is_qcow2(template).unwrap());
        let directory = tempfile::tempdir().unwrap();
        let raw = directory.path().join("converted.fd");
        prepare_variables(template, &raw, image).unwrap();
        assert_eq!(fs::metadata(&raw).unwrap().len(), ARM_FLASH_BYTES);
        assert!(!is_qcow2(&raw).unwrap());
        let compared = Command::new(image)
            .args(["compare", "-f", "qcow2", "-F", "raw"])
            .arg(template)
            .arg(&raw)
            .output()
            .unwrap();
        assert!(
            compared.status.success(),
            "{}",
            String::from_utf8_lossy(&compared.stdout)
        );
        let old = directory.path().join("efi-vars.fd");
        fs::copy(template, &old).unwrap();
        assert!(repair_variables(&old, image).unwrap());
        assert_eq!(fs::read(&old).unwrap(), fs::read(&raw).unwrap());
        let backups: Vec<_> = fs::read_dir(directory.path())
            .unwrap()
            .flatten()
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("efi-vars.before-repair-")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            fs::read(backups[0].path()).unwrap(),
            fs::read(template).unwrap()
        );
    }

    #[test]
    fn fd_extension_does_not_override_qcow_magic() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("vars.fd");
        fs::write(&source, b"QFI\xfbnot-a-raw-template").unwrap();
        assert!(is_qcow2(&source).unwrap());
        assert!(pad_raw_variables(&source).is_err());
        assert_eq!(
            fs::metadata(&source).unwrap().len(),
            b"QFI\xfbnot-a-raw-template".len() as u64
        );
    }
}
