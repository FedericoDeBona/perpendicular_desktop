//! End-to-end protocol tests with deliberately fake firmware/media and an image
//! tool fixture. These verify lifecycle and data integrity, not Windows boot.
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    iso: PathBuf,
    firmware: PathBuf,
    image: PathBuf,
    qemu: PathBuf,
    trace: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path();
        let root = base.join("data");
        let iso = base.join("Windows, test.iso");
        fs::write(&iso, vec![0; 4096]).unwrap();
        let firmware = base.join("firmware");
        fs::create_dir(&firmware).unwrap();
        fs::write(firmware.join("edk2-aarch64-code.fd"), b"firmware-code").unwrap();
        fs::write(firmware.join("edk2-arm-vars.fd"), b"firmware-vars").unwrap();
        let image = base.join("fake-qemu-img");
        fs::write(&image, MOCK_IMAGE).unwrap();
        fs::set_permissions(&image, fs::Permissions::from_mode(0o700)).unwrap();
        let qemu = base.join("fake-qemu");
        fs::write(&qemu, MOCK_QEMU).unwrap();
        fs::set_permissions(&qemu, fs::Permissions::from_mode(0o700)).unwrap();
        let trace = base.join("qmp-trace.jsonl");
        Self {
            _temp: temp,
            root,
            iso,
            firmware,
            image,
            qemu,
            trace,
        }
    }
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_perpendicular-engine"));
        command
            .env("PERPENDICULAR_DATA_DIR", &self.root)
            .env("PERPENDICULAR_QEMU_IMG", &self.image)
            .env("PERPENDICULAR_FIRMWARE_DIR", &self.firmware)
            .env("PERPENDICULAR_QEMU", &self.qemu)
            .env(
                "PERPENDICULAR_GUEST_TOOLS_ISO",
                self.firmware.join("absent-tools.iso"),
            )
            .env("PERPENDICULAR_SWTPM", self.firmware.join("absent-swtpm"))
            .env("PERPENDICULAR_MOCK_TRACE", &self.trace);
        command
    }
    fn invoke(&self, args: &[&str]) -> Value {
        let output = self.command().args(args).output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stdout).lines().count(),
            1,
            "one JSON object per invocation"
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }
    fn create(&self) -> Value {
        self.invoke(&[
            "create",
            "--name",
            "Windows Test",
            "--iso",
            self.iso.to_str().unwrap(),
            "--cpus",
            "1",
            "--memory-mib",
            "4096",
            "--disk-gib",
            "64",
        ])["vm"]
            .clone()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // Keep the temporary trace/media files alive while QMP quit runs. This
        // guard executes even when an assertion panics after a mock VM starts.
        if let Ok(entries) = fs::read_dir(self.root.join("VMs")) {
            for entry in entries.flatten() {
                let id = entry.file_name().to_string_lossy().into_owned();
                if uuid::Uuid::parse_str(&id).is_err() {
                    continue;
                }
                let _ = self.command().args(["stop", &id, "--force"]).output();
            }
        }
    }
}

#[test]
fn offline_snapshot_restores_disk_efi_and_configuration_and_keeps_recovery_copy() {
    let f = Fixture::new();
    let vm = f.create();
    let id = vm["id"].as_str().unwrap();
    assert_eq!(vm["state"], "stopped");
    assert_eq!(vm["tpm_enabled"], false);
    assert_eq!(vm["secure_boot_state"], "unsupported_firmware");
    let directory = PathBuf::from(vm["directory"].as_str().unwrap());
    let snapshot = f.invoke(&["snapshot-create", id, "--name", "Before changes"]);
    let snapshot_id = snapshot["snapshot"]["id"].as_str().unwrap();
    fs::write(directory.join("system.qcow2"), b"changed-disk").unwrap();
    fs::write(directory.join("efi-vars.fd"), b"changed-vars").unwrap();
    f.invoke(&["update", id, "--name", "Changed name"]);
    let restored = f.invoke(&["snapshot-restore", id, snapshot_id]);
    assert_eq!(restored["vm"]["name"], "Windows Test");
    assert_eq!(
        fs::read(directory.join("system.qcow2")).unwrap(),
        b"original-disk"
    );
    assert!(fs::read(directory.join("efi-vars.fd"))
        .unwrap()
        .starts_with(b"firmware-vars"));
    let backup = Path::new(restored["previous_state_directory"].as_str().unwrap());
    assert_eq!(
        fs::read(backup.join("system.qcow2")).unwrap(),
        b"changed-disk"
    );
    assert_eq!(
        f.invoke(&["snapshots", id])["snapshots"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let deleted = f.invoke(&["snapshot-delete", id, snapshot_id]);
    assert!(Path::new(deleted["trash_directory"].as_str().unwrap()).exists());
    let deleted = f.invoke(&["delete", id]);
    assert_eq!(deleted["deleted"], id);
    assert!(Path::new(deleted["trash_directory"].as_str().unwrap())
        .join("vm/system.qcow2")
        .exists());
    assert!(f.invoke(&["list"])["vms"].as_array().unwrap().is_empty());
}

#[test]
fn malformed_requests_and_identity_tampering_fail_without_writing_disks() {
    let f = Fixture::new();
    let output = f
        .command()
        .args(["delete", "../../another-app"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
        "invalid_id"
    );
    let output = f
        .command()
        .args(["create", "--name", "invalid"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
        "invalid_arguments"
    );
    let vm = f.create();
    let directory = PathBuf::from(vm["directory"].as_str().unwrap());
    let mut config: Value =
        serde_json::from_slice(&fs::read(directory.join("config.json")).unwrap()).unwrap();
    config["id"] = Value::String("00000000-0000-0000-0000-000000000000".into());
    fs::write(
        directory.join("config.json"),
        serde_json::to_vec(&config).unwrap(),
    )
    .unwrap();
    let output = f
        .command()
        .args(["delete", vm["id"].as_str().unwrap()])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(directory.join("system.qcow2").exists());
    assert_eq!(f.invoke(&["list"])["errors"].as_array().unwrap().len(), 1);
}

#[test]
fn optional_driver_media_is_persisted_and_can_be_ejected_independently() {
    let f = Fixture::new();
    let output = f
        .command()
        .env("PERPENDICULAR_GUEST_TOOLS_ISO", &f.iso)
        .args([
            "create",
            "--name",
            "Drivers",
            "--iso",
            f.iso.to_str().unwrap(),
            "--cpus",
            "1",
            "--memory-mib",
            "4096",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    let created: Value = serde_json::from_slice(&output.stdout).unwrap();
    let vm = &created["vm"];
    let id = vm["id"].as_str().unwrap();
    let canonical_iso = f.iso.canonicalize().unwrap();
    assert_eq!(vm["guest_tools_iso_path"], canonical_iso.to_str().unwrap());
    let ejected = f.invoke(&["eject-guest-tools", id]);
    assert!(ejected["vm"]["guest_tools_iso_path"].is_null());
    assert_eq!(ejected["vm"]["iso_path"], canonical_iso.to_str().unwrap());
    let updated = f.invoke(&["update", id, "--guest-tools-iso", f.iso.to_str().unwrap()]);
    assert_eq!(
        updated["vm"]["guest_tools_iso_path"],
        canonical_iso.to_str().unwrap()
    );
}

#[test]
fn guest_status_is_truthfully_unavailable_for_stopped_vm_and_transfers_validate_inputs() {
    let f = Fixture::new();
    let vm = f.create();
    let id = vm["id"].as_str().unwrap();
    assert_eq!(
        f.invoke(&["guest-status", id])["status"]["connected"],
        false
    );
    let output = f
        .command()
        .args(["guest-clipboard-read", id])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
        "guest_agent_unavailable"
    );
    let source = f._temp.path().join("large.bin");
    fs::write(&source, vec![0u8; 1024 * 1024 + 1]).unwrap();
    for name in ["../escape.txt", "CON.txt", "good.bin"] {
        let output = f
            .command()
            .args([
                "guest-file-push",
                id,
                "--source",
                source.to_str().unwrap(),
                "--name",
                name,
            ])
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert_eq!(
            serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
            if name == "good.bin" {
                "guest_file_too_large"
            } else {
                "invalid_guest_filename"
            }
        );
    }
    let text = f._temp.path().join("invalid-clipboard.txt");
    fs::write(&text, [0xff, 0xfe]).unwrap();
    let output = f
        .command()
        .args([
            "guest-clipboard-write",
            id,
            "--text-file",
            text.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
        "invalid_clipboard_encoding"
    );
}

#[test]
fn keyboard_audio_settings_persist_validate_and_default_for_older_metadata() {
    let f = Fixture::new();
    let vm = f.create();
    let id = vm["id"].as_str().unwrap();
    assert_eq!(vm["keyboard_layout"], "en-us");
    assert_eq!(vm["audio_output"], false);
    let updated = f.invoke(&[
        "update",
        id,
        "--keyboard-layout",
        "it",
        "--audio-output",
        "true",
    ]);
    assert_eq!(updated["vm"]["keyboard_layout"], "it");
    assert_eq!(updated["vm"]["audio_output"], true);
    let output = f
        .command()
        .args(["update", id, "--keyboard-layout", "unknown"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(f.invoke(&["list"])["vms"][0]["keyboard_layout"], "it");
    let path = Path::new(vm["directory"].as_str().unwrap()).join("config.json");
    let mut legacy: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    legacy.as_object_mut().unwrap().remove("keyboard_layout");
    legacy.as_object_mut().unwrap().remove("audio_output");
    fs::write(path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let listed = f.invoke(&["list"]);
    assert_eq!(listed["vms"][0]["keyboard_layout"], "en-us");
    assert_eq!(listed["vms"][0]["audio_output"], false);
}

#[test]
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn guest_operations_use_owned_qmp_and_explicit_bounded_ndjson_exchanges() {
    use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
    let f = Fixture::new();
    let vm = f.create();
    let id = vm["id"].as_str().unwrap();
    f.invoke(&["start", id]);
    let socket = Path::new(vm["qmp_socket"].as_str().unwrap())
        .parent()
        .unwrap()
        .join("agent.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        for expected in [
            "status",
            "clipboard.read",
            "clipboard.write",
            "clipboard.write",
            "file.write",
        ] {
            let (mut peer, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(peer.try_clone().unwrap())
                .read_line(&mut line)
                .unwrap();
            assert!(line.len() <= perpendicular_engine::guest::MAX_REQUEST_BYTES);
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["op"], expected);
            let result = match expected {
                "status" => {
                    serde_json::json!({"protocol":1,"agent_version":"0.1.0","os_build":"Windows test","architecture":"ARM64","username":"Test","capabilities":{"clipboard":true,"file_write":true},"secure_boot":"unknown","tpm":{"present":"unknown","ready":"unknown"}})
                }
                "clipboard.read" => serde_json::json!({"text":"Guest clipboard\n"}),
                "clipboard.write" => {
                    assert_eq!(request["params"]["text"], "Host clipboard");
                    serde_json::json!({"written":true})
                }
                _ => {
                    let content = BASE64
                        .decode(request["params"]["content_base64"].as_str().unwrap())
                        .unwrap();
                    assert_eq!(content.len(), 1024 * 1024);
                    assert!(line.len() > 1024 * 1024);
                    serde_json::json!({"name":"transfer.bin","bytes_written":content.len(),"path":"C:\\Users\\Test\\Downloads\\transfer.bin"})
                }
            };
            writeln!(
                peer,
                "{}",
                serde_json::json!({"id":request["id"],"ok":true,"result":result})
            )
            .unwrap();
        }
    });
    let status = f.invoke(&["guest-status", id]);
    assert_eq!(status["status"]["connected"], true);
    assert_eq!(status["status"]["capabilities"]["max_file_bytes"], 1048576);
    assert_eq!(
        f.invoke(&["guest-clipboard-read", id])["text"],
        "Guest clipboard\n"
    );
    assert_eq!(
        f.invoke(&["guest-clipboard-write", id, "--text", "Host clipboard"])["written"],
        true
    );
    let text_file = f._temp.path().join("clipboard.txt");
    fs::write(&text_file, b"Host clipboard").unwrap();
    fs::set_permissions(&text_file, fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        f.invoke(&[
            "guest-clipboard-write",
            id,
            "--text-file",
            text_file.to_str().unwrap()
        ])["written"],
        true
    );
    let source = f._temp.path().join("source.bin");
    fs::write(&source, vec![42u8; 1024 * 1024]).unwrap();
    let result = f.invoke(&[
        "guest-file-push",
        id,
        "--source",
        source.to_str().unwrap(),
        "--name",
        "transfer.bin",
    ]);
    assert_eq!(result["bytes_written"], 1048576);
    worker.join().unwrap();
}

#[test]
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn guest_ipc_never_connects_when_vm_ownership_check_fails() {
    let f = Fixture::new();
    let vm = f.create();
    let id = vm["id"].as_str().unwrap();
    f.invoke(&["start", id]);
    let runtime = Path::new(vm["qmp_socket"].as_str().unwrap())
        .parent()
        .unwrap();
    let listener = UnixListener::bind(runtime.join("agent.sock")).unwrap();
    listener.set_nonblocking(true).unwrap();
    let original = fs::read(runtime.join("runtime.json")).unwrap();
    let mut edited: Value = serde_json::from_slice(&original).unwrap();
    edited["launch_name"] = serde_json::json!("different-owner");
    fs::write(
        runtime.join("runtime.json"),
        serde_json::to_vec(&edited).unwrap(),
    )
    .unwrap();
    let output = f.command().args(["guest-status", id]).output().unwrap();
    fs::write(runtime.join("runtime.json"), original).unwrap(); // restore before assertions/fixture cleanup
    assert!(!output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
        "ownership_mismatch"
    );
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[test]
fn stopped_clone_copies_guest_state_with_new_identity_and_independent_disk() {
    let f = Fixture::new();
    let source = f.create();
    let source_id = source["id"].as_str().unwrap();
    let cloned = f.invoke(&["clone", source_id, "--name", "Windows Clone"]);
    let clone = &cloned["vm"];
    assert_ne!(source["id"], clone["id"]);
    assert_ne!(source["mac_address"], clone["mac_address"]);
    assert_eq!(clone["name"], "Windows Clone");
    assert_eq!(clone["state"], "stopped");
    assert_eq!(cloned["independent_disk"], true);
    let source_disk = Path::new(source["disk_path"].as_str().unwrap());
    let clone_disk = Path::new(clone["disk_path"].as_str().unwrap());
    assert_eq!(
        fs::read(source_disk).unwrap(),
        fs::read(clone_disk).unwrap()
    );
    fs::write(source_disk, b"source changed").unwrap();
    assert_eq!(fs::read(clone_disk).unwrap(), b"original-disk");
    f.invoke(&["delete", source_id]);
    assert!(clone_disk.exists());
}

#[test]
fn import_copies_a_standalone_disk_without_mutating_source() {
    let f = Fixture::new();
    let disk = f._temp.path().join("import disk.qcow2");
    fs::write(&disk, b"source disk bytes").unwrap();
    let imported = f.invoke(&[
        "import-disk",
        "--name",
        "Imported Windows",
        "--disk",
        disk.to_str().unwrap(),
        "--cpus",
        "1",
        "--memory-mib",
        "4096",
    ]);
    let vm = &imported["vm"];
    assert_eq!(vm["disk_gib"], 64);
    assert!(vm["iso_path"].is_null());
    assert_eq!(imported["independent_disk"], true);
    let target = Path::new(vm["disk_path"].as_str().unwrap());
    assert_eq!(fs::read(target).unwrap(), b"source disk bytes");
    fs::write(target, b"imported vm changes").unwrap();
    assert_eq!(fs::read(disk).unwrap(), b"source disk bytes");
}

#[test]
#[ignore = "requires PERPENDICULAR_TEST_QEMU_IMG"]
fn real_image_import_and_clone_are_independent_qcow2_and_preserve_source_bytes() {
    let image =
        PathBuf::from(std::env::var_os("PERPENDICULAR_TEST_QEMU_IMG").expect("set qemu-img path"));
    let f = Fixture::new();
    let source = f._temp.path().join("small.raw");
    let mut content = vec![0u8; 65536];
    content[..b"synthetic-raw-disk!".len()].copy_from_slice(b"synthetic-raw-disk!");
    fs::write(&source, &content).unwrap();
    let invoke = |args: &[&str]| -> Value {
        let output = f
            .command()
            .env("PERPENDICULAR_QEMU_IMG", &image)
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    };
    let imported = invoke(&[
        "import-disk",
        "--name",
        "Real raw import",
        "--disk",
        source.to_str().unwrap(),
        "--cpus",
        "1",
        "--memory-mib",
        "4096",
    ]);
    assert_eq!(imported["source_format"], "raw");
    assert_eq!(fs::read(&source).unwrap(), content);
    let imported_id = imported["vm"]["id"].as_str().unwrap();
    let target = PathBuf::from(imported["vm"]["disk_path"].as_str().unwrap());
    let cloned = invoke(&["clone", imported_id, "--name", "Real independent clone"]);
    let clone = PathBuf::from(cloned["vm"]["disk_path"].as_str().unwrap());
    for disk in [&target, &clone] {
        let output = Command::new(&image)
            .args(["info", "--output=json"])
            .arg(disk)
            .output()
            .unwrap();
        assert!(output.status.success());
        let info: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(info["format"], "qcow2");
        assert_eq!(info["virtual-size"], 64u64 * 1024 * 1024 * 1024);
        assert!(info.get("backing-filename").is_none());
        let compared = Command::new(&image)
            .args(["compare", "-f", "raw", "-F", "qcow2"])
            .arg(&source)
            .arg(disk)
            .output()
            .unwrap();
        assert!(
            compared.status.success(),
            "{}",
            String::from_utf8_lossy(&compared.stdout)
        );
    }
    invoke(&["delete", imported_id]);
    assert!(Command::new(&image)
        .args(["check", "-f", "qcow2"])
        .arg(&clone)
        .output()
        .unwrap()
        .status
        .success());
    assert_eq!(fs::read(&source).unwrap(), content);
}

#[test]
fn moved_bundle_discovers_its_own_tools_firmware_and_drivers_before_developer_paths() {
    let f = Fixture::new();
    let resources = f._temp.path().join("Moved App.app/Contents/Resources");
    let binaries = resources.join("QEMU/bin");
    let firmware = resources.join("QEMU/share/qemu");
    fs::create_dir_all(&binaries).unwrap();
    fs::create_dir_all(&firmware).unwrap();
    for name in ["qemu-system-aarch64", "qemu-img", "swtpm"] {
        fs::copy(&f.image, binaries.join(name)).unwrap();
    }
    for name in ["edk2-aarch64-secure-code.fd", "edk2-arm-secure-vars.fd"] {
        fs::write(firmware.join(name), b"bundle firmware").unwrap();
    }
    fs::write(resources.join("perpendicular-drivers.iso"), vec![0; 4096]).unwrap();
    let engine = resources.join("perpendicular-engine");
    fs::copy(env!("CARGO_BIN_EXE_perpendicular-engine"), &engine).unwrap();
    let output = Command::new(engine)
        .arg("system-info")
        .env("PERPENDICULAR_DATA_DIR", &f.root)
        .env_remove("PERPENDICULAR_QEMU")
        .env_remove("PERPENDICULAR_QEMU_IMG")
        .env_remove("PERPENDICULAR_FIRMWARE_DIR")
        .env_remove("PERPENDICULAR_SWTPM")
        .env_remove("PERPENDICULAR_GUEST_TOOLS_ISO")
        .output()
        .unwrap();
    assert!(output.status.success());
    let info: Value = serde_json::from_slice(&output.stdout).unwrap();
    for (key, path) in [
        ("qemu_path", binaries.join("qemu-system-aarch64")),
        ("qemu_img_path", binaries.join("qemu-img")),
        ("swtpm_path", binaries.join("swtpm")),
        (
            "firmware_code_path",
            firmware.join("edk2-aarch64-secure-code.fd"),
        ),
        (
            "firmware_vars_path",
            firmware.join("edk2-arm-secure-vars.fd"),
        ),
        (
            "guest_tools_iso_path",
            resources.join("perpendicular-drivers.iso"),
        ),
    ] {
        assert_eq!(
            info[key],
            path.canonicalize().unwrap().to_str().unwrap(),
            "{key}"
        );
    }
}

#[test]
fn unrelated_live_pid_cannot_authorize_stop_or_persistent_vm_mutation() {
    let f = Fixture::new();
    let vm = f.create();
    let id = vm["id"].as_str().unwrap();
    let runtime_dir = Path::new(vm["qmp_socket"].as_str().unwrap())
        .parent()
        .unwrap();
    fs::create_dir(runtime_dir).unwrap();
    fs::set_permissions(runtime_dir, fs::Permissions::from_mode(0o700)).unwrap();
    let pid = std::process::id();
    let runtime = perpendicular_engine::model::Runtime {
        pid,
        process_started_at: perpendicular_engine::process::started_at(pid).unwrap(),
        launch_name: "not-the-test-process".into(),
        shutdown_requested: false,
        last_error: None,
    };
    perpendicular_engine::storage::atomic_json(&runtime_dir.join("runtime.json"), &runtime)
        .unwrap();
    for arguments in [
        vec!["stop", id, "--force"],
        vec!["delete", id],
        vec!["update", id, "--name", "Unsafe"],
        vec!["clone", id, "--name", "Unsafe"],
    ] {
        let output = f.command().args(arguments).output().unwrap();
        assert!(!output.status.success());
    }
    assert_eq!(std::process::id(), pid);
    assert!(Path::new(vm["disk_path"].as_str().unwrap()).exists());
    fs::remove_file(runtime_dir.join("runtime.json")).unwrap();
}

#[test]
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn fixture_cleanup_stops_its_owned_mock_vm_after_assertion_failure() {
    let socket = std::cell::RefCell::new(None);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let f = Fixture::new();
        let vm = f.create();
        let id = vm["id"].as_str().unwrap();
        let started = f.invoke(&["start", id]);
        *socket.borrow_mut() = Some(PathBuf::from(started["vm"]["qmp_socket"].as_str().unwrap()));
        panic!("Deliberate fixture cleanup exercise");
    }));
    assert!(result.is_err());
    assert!(std::os::unix::net::UnixStream::connect(socket.borrow().as_ref().unwrap()).is_err());
}

#[test]
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn incomplete_runtime_metadata_keeps_live_vm_guarded_and_qmp_stop_recovers_it() {
    let f = Fixture::new();
    let vm = f.create();
    let id = vm["id"].as_str().unwrap();
    f.invoke(&["start", id]);
    f.invoke(&["pause", id]);
    let runtime = Path::new(vm["qmp_socket"].as_str().unwrap())
        .parent()
        .unwrap()
        .join("runtime.json");
    fs::remove_file(runtime).unwrap();
    assert_eq!(f.invoke(&["list"])["vms"][0]["state"], "paused");
    for args in [
        vec!["delete", id],
        vec!["start", id],
        vec!["clone", id, "--name", "Unsafe incomplete clone"],
    ] {
        assert!(!f.command().args(args).output().unwrap().status.success());
    }
    assert_eq!(f.invoke(&["stop", id])["vm"]["state"], "stopping");
    assert_shutdown_resumed_paused_vm(&f.trace);
    assert_eq!(f.invoke(&["stop", id, "--force"])["vm"]["state"], "stopped");
}

#[test]
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn qmp_lifecycle_reports_real_server_state_and_blocks_live_mutations() {
    let f = Fixture::new();
    let vm = f.create();
    let id = vm["id"].as_str().unwrap();
    assert_eq!(f.invoke(&["start", id])["vm"]["state"], "running");
    assert_eq!(f.invoke(&["pause", id])["vm"]["state"], "paused");
    let output = f.command().args(["delete", id]).output().unwrap();
    assert!(!output.status.success());
    let output = f
        .command()
        .args(["snapshot-create", id, "--name", "Unsafe online snapshot"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!f
        .command()
        .args(["clone", id, "--name", "Unsafe live clone"])
        .output()
        .unwrap()
        .status
        .success());
    assert_eq!(f.invoke(&["resume", id])["vm"]["state"], "running");
    assert!(f.invoke(&["eject-iso", id])["vm"]["iso_path"].is_null());
    f.invoke(&["pause", id]);
    assert_eq!(f.invoke(&["stop", id])["vm"]["state"], "stopping");
    assert_shutdown_resumed_paused_vm(&f.trace);
    assert_eq!(f.invoke(&["stop", id, "--force"])["vm"]["state"], "stopped");
    assert_eq!(f.invoke(&["list"])["vms"][0]["state"], "stopped");
    let trace = fs::read_to_string(&f.trace).unwrap();
    assert!(trace.lines().any(|line| line.contains("system_powerdown")));
    assert!(trace
        .lines()
        .any(|line| line.contains("blockdev-remove-medium")));
}

fn assert_shutdown_resumed_paused_vm(trace: &Path) {
    let commands: Vec<String> = fs::read_to_string(trace)
        .unwrap()
        .lines()
        .map(|line| {
            serde_json::from_str::<Value>(line).unwrap()["execute"]
                .as_str()
                .unwrap()
                .into()
        })
        .collect();
    let powerdown = commands
        .iter()
        .rposition(|command| command == "system_powerdown")
        .unwrap();
    assert!(powerdown > 0);
    assert_eq!(
        commands[powerdown - 1],
        "cont",
        "paused guest must be resumed immediately before ACPI powerdown"
    );
}

const MOCK_IMAGE: &str = r#"#!/bin/sh
case "$1" in
create) printf 'original-disk' > "$4";;
convert) while [ "$#" -gt 2 ]; do shift; done; /bin/cp "$1" "$2";;
info) printf '{"format":"qcow2","virtual-size":8589934592}\n';;
resize) exit 0;;
*) exit 3;;
esac
"#;

const MOCK_QEMU: &str = r#"#!/usr/bin/python3
import json, os, socket, sys
args=sys.argv[1:]
def option(name): return args[args.index(name)+1]
uuid=option('-uuid'); name=option('-name'); path=option('-qmp')[5:].split(',')[0]
state='prelaunch'
listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);listener.bind(path);listener.listen(8)
while True:
    conn,_=listener.accept()
    try:
        conn.sendall(b'{"QMP":{"version":{}}}\r\n')
        reader=conn.makefile('rb')
        for line in reader:
            request=json.loads(line); command=request['execute']
            with open(os.environ['PERPENDICULAR_MOCK_TRACE'],'a') as trace: trace.write(json.dumps(request)+'\n')
            result={}
            if command=='query-uuid': result={'UUID':uuid}
            elif command=='query-name': result={'name':name}
            elif command=='query-status': result={'status':state}
            elif command=='cont': state='running'
            elif command=='stop': state='paused'
            conn.sendall((json.dumps({'return':result,'id':request['id']})+'\r\n').encode())
            if command=='quit': conn.close(); listener.close();sys.exit(0)
    except (BrokenPipeError, ConnectionResetError): pass
    finally: reader.close(); conn.close()
"#;
