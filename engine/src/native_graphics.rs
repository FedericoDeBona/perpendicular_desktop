//! One optional, bundled native graphics runtime. No shell launch wrappers.
use crate::error::{Error, Result};
use crate::tools::Tools;
use serde::Deserialize;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Deserialize)]
struct Manifest {
    schema: u32,
    guest_wire_version: u32,
    host_transport_version: u32,
    native_descriptor_version: u32,
    input_backpressure: bool,
    hvf_stp_hole_default_off: bool,
}

pub struct NativeGraphics {
    pub root: PathBuf,
    pub qemu: PathBuf,
}

impl NativeGraphics {
    pub fn discover(tools: &Tools) -> Result<Self> {
        let root = std::env::var_os("PERPENDICULAR_NATIVE_GRAPHICS_DIR")
            .map(PathBuf::from)
            .or_else(|| {
                Some(
                    tools
                        .qemu_path
                        .as_ref()?
                        .parent()?
                        .parent()?
                        .parent()?
                        .join("Native3D"),
                )
            })
            .ok_or_else(unavailable)?;
        Self::from_directory(&root)
    }

    pub fn from_directory(root: &Path) -> Result<Self> {
        let root = root.canonicalize().map_err(|_| unavailable())?;
        if !root
            .parent()
            .ok_or_else(unavailable)?
            .join("QEMU/share/qemu")
            .is_dir()
        {
            return Err(unavailable());
        }
        let path = root.join("runtime.json");
        if path.metadata().map_err(|_| unavailable())?.len() > 65536 {
            return Err(unavailable());
        }
        let manifest: Manifest =
            serde_json::from_slice(&std::fs::read(path)?).map_err(|_| unavailable())?;
        if manifest.schema != 1
            || manifest.guest_wire_version != 1
            || manifest.host_transport_version != 3
            || manifest.native_descriptor_version != 2
            || !manifest.input_backpressure
            || !manifest.hvf_stp_hole_default_off
        {
            return Err(unavailable());
        }
        for name in [
            "bin/qemu-system-aarch64",
            "bin/virgl_render_server",
            "lib/libdxmt-native.dylib",
            "lib/libvirglrenderer.1.dylib",
        ] {
            if !root.join(name).is_file() {
                return Err(unavailable());
            }
            if name.starts_with("bin/")
                && root.join(name).metadata()?.permissions().mode() & 0o111 == 0
            {
                return Err(unavailable());
            }
        }
        Ok(Self {
            qemu: root.join("bin/qemu-system-aarch64"),
            root,
        })
    }

    pub fn configure(
        &self,
        command: &mut Command,
        runtime: &Path,
        launch_name: &str,
    ) -> Result<()> {
        let token = launch_name.rsplit('-').next().ok_or_else(unavailable)?;
        if token.len() != 32 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::new(
                "invalid_launch_identity",
                "Native display requires the engine's launch identity",
            ));
        }
        let libraries = self.root.join("lib");
        command.arg("-L").arg(
            self.root
                .parent()
                .ok_or_else(unavailable)?
                .join("QEMU/share/qemu"),
        );
        command
            .env("DYLD_LIBRARY_PATH", &libraries)
            .env("DYLD_FALLBACK_LIBRARY_PATH", &libraries)
            .env("NPT_BACKEND", "dxmt")
            .env("ANGLE_DEFAULT_PLATFORM", "metal")
            .env(
                "RENDER_SERVER_EXEC_PATH",
                self.root.join("bin/virgl_render_server"),
            )
            .env("PERP_NEPTUNE_SCANOUT_BROKER", "1")
            .env("PERP_NATIVE_DISPLAY_DIRECT", "1")
            .env("PERP_NATIVE_DISPLAY_DIR", runtime)
            .env("PERP_NATIVE_DISPLAY_SESSION", token)
            .env("PERP_HVF_STP_Q_PCI_HOLE", "1");
        for name in [
            "NPT_D3D11_LIBRARY_PATH",
            "NPT_DXGI_LIBRARY_PATH",
            "NPT_D3D12_LIBRARY_PATH",
        ] {
            command.env(name, libraries.join("libdxmt-native.dylib"));
        }
        Ok(())
    }
}

fn unavailable() -> Error {
    Error::new(
        "native_graphics_unavailable",
        "This application does not contain the complete compatible native 3D runtime",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn incomplete_or_mixed_runtime_is_rejected_and_session_is_exact() {
        let directory = tempfile::tempdir().unwrap();
        let root_path = directory.path().join("Resources/Native3D");
        std::fs::create_dir_all(&root_path).unwrap();
        std::fs::create_dir_all(directory.path().join("Resources/QEMU/share/qemu")).unwrap();
        let root = root_path.as_path();
        assert!(NativeGraphics::from_directory(root).is_err());
        let mut manifest = serde_json::json!({"schema":1,"guest_wire_version":1,"host_transport_version":3,
            "native_descriptor_version":2,"input_backpressure":true,"hvf_stp_hole_default_off":true});
        std::fs::write(root.join("runtime.json"), manifest.to_string()).unwrap();
        assert!(NativeGraphics::from_directory(root).is_err());
        for name in [
            "bin/qemu-system-aarch64",
            "bin/virgl_render_server",
            "lib/libdxmt-native.dylib",
            "lib/libvirglrenderer.1.dylib",
        ] {
            let path = root.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, b"fixture").unwrap();
        }
        assert!(NativeGraphics::from_directory(root).is_err());
        for name in ["bin/qemu-system-aarch64", "bin/virgl_render_server"] {
            std::fs::set_permissions(root.join(name), std::fs::Permissions::from_mode(0o700))
                .unwrap();
        }
        let runtime = NativeGraphics::from_directory(root).unwrap();
        let mut command = Command::new(&runtime.qemu);
        let token = "0123456789abcdef0123456789abcdef";
        runtime
            .configure(
                &mut command,
                Path::new("/tmp/owned"),
                &format!("perpendicular-vm-{token}"),
            )
            .unwrap();
        let env: std::collections::BTreeMap<_, _> = command
            .get_envs()
            .map(|(k, v)| (k.to_str().unwrap(), v.unwrap().to_str().unwrap()))
            .collect();
        assert_eq!(env["PERP_NATIVE_DISPLAY_SESSION"], token);
        assert_eq!(env["PERP_NATIVE_DISPLAY_DIR"], "/tmp/owned");
        assert!(runtime.configure(&mut command, root, "invalid").is_err());
        manifest["guest_wire_version"] = serde_json::json!(2);
        std::fs::write(root.join("runtime.json"), manifest.to_string()).unwrap();
        assert!(NativeGraphics::from_directory(root).is_err());
    }
}
