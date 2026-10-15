use crate::error::{Error, Result};
use fs2::FileExt;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Serialize, Deserialize)]
struct Owner {
    format_version: u32,
    application: String,
    instance_id: Uuid,
}

pub struct Store {
    pub root: PathBuf,
    pub runtime_root: PathBuf,
    _lock: File,
}

pub fn private_dir(path: &Path) -> Result<()> {
    if path
        .symlink_metadata()
        .is_ok_and(|meta| meta.file_type().is_symlink())
    {
        return Err(Error::new(
            "unsafe_path",
            format!("Refusing symbolic-link directory {}", path.display()),
        ));
    }
    fs::create_dir_all(path)?;
    let metadata = fs::metadata(path)?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err(Error::new(
            "ownership_mismatch",
            format!(
                "Directory {} is not owned by the current user",
                path.display()
            ),
        ));
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub fn assert_regular(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|e| Error::io(&format!("Cannot access {}", path.display()), e))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(Error::new(
            "unsafe_path",
            format!("Expected a regular user-owned file: {}", path.display()),
        ));
    }
    Ok(())
}

pub fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T> {
    assert_regular(path)?;
    let mut input = Vec::new();
    File::open(path)?
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut input)?;
    if input.len() > 4 * 1024 * 1024 {
        return Err(Error::new("invalid_config", "Metadata file exceeds 4 MiB"));
    }
    Ok(serde_json::from_slice(&input)?)
}

pub fn atomic_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::new("unsafe_path", "Metadata has no parent directory"))?;
    let temp = parent.join(format!(".write-{}", Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        serde_json::to_writer_pretty(&mut file, value)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

impl Store {
    pub fn open(root: PathBuf) -> Result<Self> {
        if !root.is_absolute() {
            return Err(Error::new(
                "invalid_data_dir",
                "PERPENDICULAR_DATA_DIR must be an absolute path",
            ));
        }
        private_dir(&root)?;
        let root = root.canonicalize()?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(root.join(".engine.lock"))?;
        lock.lock_exclusive()?;
        let owner_path = root.join("owner.json");
        let owner: Owner = if owner_path.exists() {
            read_json(&owner_path)?
        } else {
            let owner = Owner {
                format_version: 1,
                application: "perpendicular-desktop".into(),
                instance_id: Uuid::new_v4(),
            };
            atomic_json(&owner_path, &owner)?;
            owner
        };
        if owner.application != "perpendicular-desktop" || owner.format_version != 1 {
            return Err(Error::new(
                "ownership_mismatch",
                "Application data belongs to another application or unsupported format",
            ));
        }
        for directory in ["VMs", "Snapshots", "Trash"] {
            private_dir(&root.join(directory))?;
        }
        // /tmp is intentionally used instead of TMPDIR: macOS TMPDIR paths can
        // already consume nearly the entire 104-byte sockaddr_un limit.
        let runtime_root = PathBuf::from(format!(
            "/tmp/perp-{}-{}",
            unsafe { libc::geteuid() },
            &owner.instance_id.simple().to_string()[..12]
        ));
        private_dir(&runtime_root)?;
        Ok(Self {
            root,
            runtime_root,
            _lock: lock,
        })
    }

    pub fn id(id: &str) -> Result<Uuid> {
        let uuid = Uuid::parse_str(id)
            .map_err(|_| Error::new("invalid_id", "VM and snapshot identifiers must be UUIDs"))?;
        if uuid.to_string() != id {
            return Err(Error::new(
                "invalid_id",
                "Use the canonical lowercase UUID identifier",
            ));
        }
        Ok(uuid)
    }
    pub fn vm_dir(&self, id: &str) -> Result<PathBuf> {
        Self::id(id)?;
        Ok(self.root.join("VMs").join(id))
    }
    pub fn snapshots_dir(&self, id: &str) -> Result<PathBuf> {
        Self::id(id)?;
        Ok(self.root.join("Snapshots").join(id))
    }
    pub fn runtime_dir(&self, id: &str) -> Result<PathBuf> {
        Self::id(id)?;
        Ok(self.runtime_root.join(id))
    }
}

pub fn copy_tree(source: &Path, destination: &Path) -> Result<()> {
    private_dir(source)?;
    private_dir(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let target = destination.join(entry.file_name());
        if kind.is_symlink() {
            return Err(Error::new(
                "unsafe_path",
                "Refusing a symbolic link inside VM state",
            ));
        }
        if kind.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            assert_regular(&entry.path())?;
            fs::copy(entry.path(), target)?;
        } else {
            return Err(Error::new(
                "unsafe_path",
                "VM state contains a non-regular file",
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identifiers_cannot_escape_vm_root() {
        for input in [
            "../other",
            "/tmp/vm",
            "",
            "8F14E45F-EA1D-4B93-8E48-1BCE011BFF55",
        ] {
            assert!(Store::id(input).is_err());
        }
        assert!(Store::id("8f14e45f-ea1d-4b93-8e48-1bce011bff55").is_ok());
    }
    #[test]
    fn metadata_is_atomic_private_and_symlinks_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("metadata.json");
        atomic_json(&path, &serde_json::json!({"value":1})).unwrap();
        atomic_json(&path, &serde_json::json!({"value":2})).unwrap();
        assert_eq!(read_json::<serde_json::Value>(&path).unwrap()["value"], 2);
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        let alias = dir.path().join("alias");
        std::os::unix::fs::symlink(&path, &alias).unwrap();
        assert!(read_json::<serde_json::Value>(&alias).is_err());
    }
}
