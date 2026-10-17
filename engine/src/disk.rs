use crate::error::{Error, Result};
use serde::Deserialize;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Deserialize)]
pub struct DiskInfo {
    pub format: String,
    #[serde(rename = "virtual-size")]
    pub virtual_size: u64,
    #[serde(default)]
    pub encrypted: bool,
    #[serde(rename = "backing-filename")]
    pub backing_filename: Option<String>,
}

pub(crate) fn can_clone_qcow2(info: &serde_json::Value) -> bool {
    let data = &info["format-specific"]["data"];
    info["format"] == "qcow2"
        && info["format-specific"]["type"] == "qcow2"
        && data.is_object()
        && info["virtual-size"].as_u64().is_some_and(|size| size > 0)
        && info["backing-filename"].is_null()
        && info["full-backing-filename"].is_null()
        && info["data-file"].is_null()
        && data["data-file"].is_null()
        && data["encrypt"].is_null()
        && (info["encrypted"].is_null() || info["encrypted"] == false)
}

pub fn inspect_import(image_tool: &Path, source: &Path) -> Result<DiskInfo> {
    let output = Command::new(image_tool)
        .args(["info", "--output=json"])
        .arg(source)
        .output()?;
    if !output.status.success() {
        return Err(Error::new(
            "invalid_disk_image",
            format!(
                "Cannot inspect source disk (it must be offline and readable): {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        ));
    }
    let info: DiskInfo = serde_json::from_slice(&output.stdout)?;
    validate_import(&info)?;
    Ok(info)
}

pub(crate) fn validate_import(info: &DiskInfo) -> Result<()> {
    if info.format != "raw" && info.format != "qcow2" {
        return Err(Error::new(
            "unsupported_disk_format",
            "Disk import currently accepts self-contained raw and qcow2 images",
        ));
    }
    if info.backing_filename.is_some() {
        return Err(Error::new(
            "unsupported_backing_chain",
            "Flatten the source disk's backing chain into a standalone image before importing it",
        ));
    }
    if info.encrypted {
        return Err(Error::new("encrypted_disk_image","Encrypted qcow2 containers require explicit key handling and are not supported by disk import"));
    }
    if info.virtual_size == 0 || info.virtual_size > 16_384 * 1024 * 1024 * 1024 {
        return Err(Error::new(
            "invalid_disk_size",
            "Source disk capacity must be between 1 byte and 16 TiB",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn filesystem_clone_requires_a_known_self_contained_qcow2() {
        let base = serde_json::json!({"format":"qcow2","virtual-size":4096,
            "format-specific":{"type":"qcow2","data":{"compat":"1.1"}}});
        assert!(can_clone_qcow2(&base));
        for field in [
            "backing-filename",
            "full-backing-filename",
            "data-file",
            "encrypted",
        ] {
            let mut value = base.clone();
            value[field] = serde_json::json!("external");
            assert!(!can_clone_qcow2(&value));
        }
        for field in ["data-file", "encrypt"] {
            let mut value = base.clone();
            value["format-specific"]["data"][field] = serde_json::json!("external");
            assert!(!can_clone_qcow2(&value));
        }
        assert!(!can_clone_qcow2(&serde_json::json!({"format":"qcow2"})));
    }
    #[test]
    fn accepts_standalone_formats_but_rejects_unsafe_or_unsupported_images() {
        let mut info = DiskInfo {
            format: "qcow2".into(),
            virtual_size: 64 * 1024 * 1024 * 1024,
            encrypted: false,
            backing_filename: None,
        };
        assert!(validate_import(&info).is_ok());
        info.format = "raw".into();
        assert!(validate_import(&info).is_ok());
        info.format = "vmdk".into();
        assert!(validate_import(&info).is_err());
        info.format = "qcow2".into();
        info.backing_filename = Some("relative-base.qcow2".into());
        assert!(validate_import(&info).is_err());
        info.backing_filename = None;
        info.encrypted = true;
        assert!(validate_import(&info).is_err());
        info.encrypted = false;
        info.virtual_size = 0;
        assert!(validate_import(&info).is_err());
    }
}
