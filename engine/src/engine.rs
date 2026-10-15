use crate::command::image_tool;
use crate::disk::inspect_import;
use crate::error::{Error, Result};
use crate::firmware::{prepare_variables, repair_variables};
use crate::guest;
use crate::model::{
    validate_keyboard_layout, validate_name, validate_resources, Config, Runtime, Snapshot,
    UpdateOptions, Vm,
};
use crate::process::{
    launch_process_exists, launch_supervisor, process_state, ExitRecord, LaunchJob, ProcessState,
};
use crate::qmp::Qmp;
use crate::storage::{assert_regular, atomic_json, copy_tree, private_dir, read_json, Store};
use crate::tools::{host_memory_bytes, hypervisor_available, run_output, Tools};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use fs2::FileExt;
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};
use uuid::Uuid;

pub struct Engine {
    pub store: Store,
    pub tools: Tools,
}

impl Engine {
    pub fn open() -> Result<Self> {
        let root = match std::env::var_os("PERPENDICULAR_DATA_DIR") {
            Some(root) => PathBuf::from(root),
            None => PathBuf::from(std::env::var_os("HOME").ok_or_else(|| {
                Error::new(
                    "home_missing",
                    "HOME is unset; specify PERPENDICULAR_DATA_DIR",
                )
            })?)
            .join("Library/Application Support/Perpendicular Desktop"),
        };
        Ok(Self {
            store: Store::open(root)?,
            tools: Tools::discover(),
        })
    }

    pub fn system_info(&self) -> Value {
        let mut info = serde_json::to_value(&self.tools).unwrap_or_else(|_| json!({}));
        info["architecture"] = json!(std::env::consts::ARCH);
        info["memory_bytes"] = json!(host_memory_bytes());
        info["logical_cpus"] = json!(std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1));
        info["hypervisor_available"] = json!(hypervisor_available());
        info["data_dir"] = json!(self.store.root);
        info["secure_boot_verified"] = json!(false);
        info["windows_readiness"] = json!({"tpm_available":self.tools.swtpm_path.is_some(),"tpm_physical_presence_interface":false,"secure_boot":"guest_verification_required","graphics":"Linear RAM framebuffer with UEFI GOP; Windows accelerated display driver is not implemented","network":"VirtIO guest driver required"});
        info
    }

    fn config(&self, id: &str) -> Result<Config> {
        let directory = self.store.vm_dir(id)?;
        if !directory.exists() {
            return Err(Error::new(
                "vm_not_found",
                format!("VM {id} does not exist"),
            ));
        }
        private_dir(&directory)?;
        let config: Config = read_json(&directory.join("config.json"))?;
        if config.id != id
            || config.format_version != 1
            || config.firmware_code_path != directory.join("efi-code.fd")
        {
            return Err(Error::new(
                "invalid_config",
                "VM metadata identity, firmware path, or format does not match its owned directory",
            ));
        }
        validate_name(&config.name)?;
        validate_resources(config.cpus, config.memory_mib, config.disk_gib)?;
        validate_keyboard_layout(&config.keyboard_layout)?;
        let octets: Vec<_> = config.mac_address.split(':').collect();
        if octets.len() != 6
            || octets
                .iter()
                .any(|octet| octet.len() != 2 || u8::from_str_radix(octet, 16).is_err())
        {
            return Err(Error::new("invalid_config", "Invalid VM network address"));
        }
        Ok(config)
    }

    fn runtime(&self, id: &str) -> Result<Option<Runtime>> {
        let directory = self.store.runtime_dir(id)?;
        if !directory.exists() {
            return Ok(None);
        }
        private_dir(&directory)?;
        let path = directory.join("runtime.json");
        if path.exists() {
            Ok(Some(read_json(&path)?))
        } else {
            Ok(None)
        }
    }

    fn qmp(&self, id: &str, runtime: &Runtime) -> Result<Qmp> {
        let mut qmp = Qmp::connect(&self.store.runtime_dir(id)?.join("qmp.sock"))?;
        qmp.verify(id, &runtime.launch_name)?;
        Ok(qmp)
    }

    fn launch_job(&self, id: &str) -> Result<Option<LaunchJob>> {
        let runtime = self.store.runtime_dir(id)?;
        let path = runtime.join("launch.json");
        if !path.exists() {
            return Ok(None);
        }
        let job: LaunchJob = read_json(&path)?;
        let prefix = format!("perpendicular-{id}-");
        if job.config.id != id
            || job.vm_dir != self.store.vm_dir(id)?
            || job.runtime_dir != runtime
            || job
                .launch_name
                .strip_prefix(&prefix)
                .is_none_or(|token| Uuid::parse_str(token).is_err())
        {
            return Err(Error::new(
                "ownership_mismatch",
                "Launch record does not belong to this VM and application storage",
            ));
        }
        Ok(Some(job))
    }

    fn launch_qmp(&self, id: &str, job: &LaunchJob) -> Result<Qmp> {
        let mut qmp = Qmp::connect(&self.store.runtime_dir(id)?.join("qmp.sock"))?;
        qmp.verify(id, &job.launch_name)?;
        Ok(qmp)
    }

    pub fn vm(&self, id: &str) -> Result<Vm> {
        self.view(&self.config(id)?)
    }

    fn view(&self, config: &Config) -> Result<Vm> {
        let directory = self.store.vm_dir(&config.id)?;
        let runtime_dir = self.store.runtime_dir(&config.id)?;
        let qmp_socket = runtime_dir.join("qmp.sock");
        let vnc_socket = runtime_dir.join("vnc.sock");
        let (mut state, mut last_error) = ("stopped".to_owned(), None);
        if let Some(runtime) = self.runtime(&config.id)? {
            match self
                .qmp(&config.id, &runtime)
                .and_then(|mut qmp| qmp.status())
            {
                Ok(status) => {
                    state = match status.as_str() {
                        "running" => {
                            if runtime.shutdown_requested {
                                "stopping"
                            } else {
                                "running"
                            }
                        }
                        "paused" | "prelaunch" | "suspended" => "paused",
                        "shutdown" => "stopping",
                        "internal-error" | "io-error" | "guest-panicked" => "crashed",
                        _ => "starting",
                    }
                    .into();
                    if state == "crashed" {
                        last_error = Some(format!("QEMU reports {status}; see qemu.log"));
                    }
                }
                Err(error) => {
                    if matches!(process_state(&runtime, &qmp_socket), ProcessState::Gone) {
                        let exit_path = runtime_dir.join("exit.json");
                        if exit_path.exists() {
                            let exit: ExitRecord = read_json(&exit_path)?;
                            if exit.launch_name == runtime.launch_name && exit.success {
                                state = "stopped".into();
                            } else {
                                state = "crashed".into();
                                last_error = Some(exit.error.unwrap_or_else(|| {
                                    format!(
                                        "QEMU exited with code {:?}. {}",
                                        exit.exit_code,
                                        log_tail(&directory.join("qemu.log"))
                                    )
                                }));
                            }
                        } else {
                            state = "crashed".into();
                            last_error=Some("QEMU exited without a supervisor exit record; the previous launch was interrupted".into());
                        }
                    } else {
                        state = "crashed".into();
                        last_error = Some(format!(
                            "VM may still be running, but control is unavailable. {}",
                            error.message
                        ));
                    }
                }
            }
        } else if runtime_dir.join("launch.json").exists() {
            let job = self
                .launch_job(&config.id)?
                .ok_or_else(|| Error::new("invalid_launch", "VM launch record disappeared"))?;
            if let Ok(status) = self
                .launch_qmp(&config.id, &job)
                .and_then(|mut qmp| qmp.status())
            {
                state = match status.as_str() {
                    "running" => {
                        if runtime_dir.join("shutdown-requested.json").exists()
                            && read_json::<Value>(&runtime_dir.join("shutdown-requested.json"))?
                                ["launch_name"]
                                == job.launch_name
                        {
                            "stopping"
                        } else {
                            "running"
                        }
                    }
                    "paused" | "prelaunch" => "paused",
                    "shutdown" => "stopping",
                    _ => "crashed",
                }
                .into();
                last_error=Some("Live QEMU status recovered from its launch record; runtime metadata is incomplete. Stop this VM before changing persistent state.".into());
            } else if runtime_dir.join("exit.json").exists() {
                let exit: ExitRecord = read_json(&runtime_dir.join("exit.json"))?;
                state = "crashed".into();
                last_error = exit.error.or(Some(
                    "QEMU could not start; see qemu.log and supervisor.log".into(),
                ));
            } else {
                state = "starting".into();
            }
        } else if std::os::unix::net::UnixStream::connect(&qmp_socket).is_ok() {
            state = "crashed".into();
            last_error=Some("A live control socket exists without an owned launch record; persistent VM changes are blocked.".into());
        }
        if !directory.join("system.qcow2").is_file() {
            state = "crashed".into();
            last_error = Some("VM system.qcow2 is missing".into());
        }
        Ok(Vm {
            id: config.id.clone(),
            name: config.name.clone(),
            state,
            cpus: config.cpus,
            memory_mib: config.memory_mib,
            disk_gib: config.disk_gib,
            iso_path: config.iso_path.clone(),
            guest_tools_iso_path: config.guest_tools_iso_path.clone(),
            directory: directory.clone(),
            disk_path: directory.join("system.qcow2"),
            created_at: config.created_at.clone(),
            backend: "qemu-hvf",
            qmp_socket,
            vnc_socket,
            last_error,
            tpm_enabled: config.tpm_enabled,
            secure_boot_state: config.secure_boot_state.clone(),
            mac_address: config.mac_address.clone(),
            keyboard_layout: config.keyboard_layout.clone(),
            audio_output: config.audio_output,
        })
    }

    pub fn list(&self) -> Result<Value> {
        let mut vms = Vec::new();
        let mut errors = Vec::new();
        for entry in fs::read_dir(self.store.root.join("VMs"))? {
            let entry = entry?;
            let id = entry.file_name().to_string_lossy().into_owned();
            if id.starts_with('.') {
                continue;
            }
            match self.vm(&id) {
                Ok(vm) => vms.push(vm),
                Err(error) => errors.push(json!({"id":id,"error":error})),
            }
        }
        vms.sort_by(|a, b| a.created_at.cmp(&b.created_at));
        Ok(json!({"vms":vms,"errors":errors}))
    }

    pub fn create(
        &self,
        name: &str,
        iso: &Path,
        cpus: u16,
        memory_mib: u64,
        disk_gib: u64,
    ) -> Result<Value> {
        validate_name(name)?;
        validate_resources(cpus, memory_mib, disk_gib)?;
        self.validate_host(cpus, memory_mib)?;
        let iso_path = validate_iso(iso)?;
        let guest_tools_iso_path = self
            .tools
            .guest_tools_iso_path
            .as_deref()
            .map(validate_iso)
            .transpose()?;
        let image = image_tool(&self.tools)?;
        let code = self
            .tools
            .require(&self.tools.firmware_code_path, "AArch64 UEFI firmware")?;
        let vars = self.tools.require(
            &self.tools.firmware_vars_path,
            "AArch64 UEFI variables template",
        )?;
        let id = Uuid::new_v4().to_string();
        let destination = self.store.vm_dir(&id)?;
        let staging = self.store.root.join("VMs").join(format!(".create-{id}"));
        private_dir(&staging)?;
        let config = Config {
            format_version: 1,
            id: id.clone(),
            name: name.trim().into(),
            cpus,
            memory_mib,
            disk_gib,
            iso_path: Some(iso_path),
            guest_tools_iso_path,
            created_at: chrono::Utc::now().to_rfc3339(),
            firmware_code_path: destination.join("efi-code.fd"),
            tpm_enabled: self.tools.swtpm_path.is_some(),
            secure_boot_state: if self.tools.firmware_secure_boot_capable {
                "unverified"
            } else {
                "unsupported_firmware"
            }
            .into(),
            mac_address: new_mac(&id)?,
            keyboard_layout: "en-us".into(),
            audio_output: false,
        };
        let result = (|| {
            run_output(
                Command::new(&image)
                    .args(["create", "-f", "qcow2"])
                    .arg(staging.join("system.qcow2"))
                    .arg(format!("{disk_gib}G")),
                "Create VM disk",
            )?;
            fs::copy(code, staging.join("efi-code.fd"))?;
            prepare_variables(vars, &staging.join("efi-vars.fd"), &image)?;
            if config.tpm_enabled {
                private_dir(&staging.join("tpm"))?;
            }
            atomic_json(&staging.join("config.json"), &config)?;
            fs::rename(&staging, &destination)?;
            Ok(json!({"vm":self.view(&config)?}))
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(&staging);
        }
        result
    }

    pub fn clone_vm(&self, id: &str, name: &str) -> Result<Value> {
        validate_name(name)?;
        let source = self.require_stopped(id)?;
        let image = image_tool(&self.tools)?;
        let new_id = Uuid::new_v4().to_string();
        let destination = self.store.vm_dir(&new_id)?;
        let staging = self.store.root.join("VMs").join(format!(".clone-{new_id}"));
        private_dir(&staging)?;
        let mut config = source.clone();
        config.id = new_id.clone();
        config.name = name.trim().into();
        config.created_at = chrono::Utc::now().to_rfc3339();
        config.firmware_code_path = destination.join("efi-code.fd");
        config.mac_address = new_mac(&new_id)?;
        let result = (|| {
            self.copy_vm_state(&self.store.vm_dir(id)?, &staging, &image)?;
            repair_variables(&staging.join("efi-vars.fd"), &image)?;
            if config.tpm_enabled && !staging.join("tpm").is_dir() {
                return Err(Error::new("missing_tpm_state","Source TPM state is missing; cloning it could make encrypted guest data inaccessible"));
            }
            atomic_json(&staging.join("config.json"), &config)?;
            fs::rename(&staging, &destination)?;
            let mut warnings=vec!["The clone has a new VM UUID, network MAC and NVMe serial. Windows may request reactivation or BitLocker recovery."];
            if config.tpm_enabled {
                warnings.push("EFI and TPM state were copied with the disk to preserve guest consistency; TPM cryptographic state is shared with the source until independently reprovisioned inside the guest.");
            }
            Ok(
                json!({"vm":self.view(&config)?,"source_vm_id":id,"independent_disk":true,"tpm_state_copied":config.tpm_enabled,"warnings":warnings}),
            )
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(&staging);
        }
        result
    }

    fn guest_request(&self, id: &str, op: &str, params: Value) -> Result<Value> {
        self.config(id)?;
        let qmp = if let Some(runtime) = self.runtime(id)? {
            self.qmp(id, &runtime)
        } else if let Some(job) = self.launch_job(id)? {
            self.launch_qmp(id, &job)
        } else {
            return Err(Error::new(
                "guest_agent_unavailable",
                "VM is stopped; start it and run Perpendicular Guest Tools inside Windows",
            ));
        };
        let mut qmp = qmp.map_err(|error| {
            if error.code == "ownership_mismatch" {
                error
            } else {
                Error::new(
                    "guest_agent_unavailable",
                    format!(
                        "Cannot establish the owned running VM before guest IPC: {}",
                        error.message
                    ),
                )
            }
        })?;
        if qmp.status()? != "running" {
            return Err(Error::new(
                "guest_agent_unavailable",
                "Guest-agent operations require a running VM; resume a paused guest first",
            ));
        }
        drop(qmp);
        // Every IPC exchange follows this QMP UUID+launch-name ownership check.
        // The application lock also prevents an engine-controlled VM restart
        // between verification and connection to its private serial socket.
        guest::exchange(&self.store.runtime_dir(id)?.join("agent.sock"), op, params)
    }

    pub fn guest_status(&self, id: &str) -> Result<Value> {
        self.config(id)?;
        match self
            .guest_request(id, "status", json!({}))
            .and_then(guest::validate_status)
        {
            Ok(status) => Ok(json!({"status":status})),
            Err(error) if error.code == "ownership_mismatch" => Err(error),
            Err(error) => Ok(
                json!({"status":{"connected":false,"code":error.code,"reason":error.message,"capabilities":{"clipboard":false,"file_write":false}}}),
            ),
        }
    }

    pub fn guest_clipboard_read(&self, id: &str) -> Result<Value> {
        let result = self.guest_request(id, "clipboard.read", json!({}))?;
        let text = result.get("text").and_then(Value::as_str).ok_or_else(|| {
            Error::new(
                "guest_agent_protocol",
                "Guest clipboard response has no text string",
            )
        })?;
        guest::validate_clipboard(text)?;
        Ok(json!({"text":text}))
    }

    pub fn guest_clipboard_write(&self, id: &str, text: &str) -> Result<Value> {
        guest::validate_clipboard(text)?;
        let result = self
            .guest_request(id, "clipboard.write", json!({"text":text}))
            .map_err(|error| {
                if error.code == "guest_request_too_large" {
                    Error::new(
                        "clipboard_too_large",
                        "Escaped clipboard text exceeds the serialized request limit",
                    )
                } else {
                    error
                }
            })?;
        if result.get("written").and_then(Value::as_bool) != Some(true) {
            return Err(Error::new(
                "guest_agent_protocol",
                "Guest agent did not acknowledge the clipboard write",
            ));
        }
        Ok(json!({"written":true}))
    }

    pub fn guest_file_push(&self, id: &str, source: &Path, name: &str) -> Result<Value> {
        self.config(id)?;
        guest::validate_filename(name)?;
        if !source.is_absolute() {
            return Err(Error::new(
                "invalid_source_path",
                "File transfer source must be an absolute path",
            ));
        }
        let source = source
            .canonicalize()
            .map_err(|error| Error::io("Cannot access file transfer source", error))?;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&source)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            return Err(Error::new(
                "invalid_source_path",
                "File transfer source must be a regular file",
            ));
        }
        if metadata.len() > guest::MAX_FILE_BYTES as u64 {
            return Err(Error::new(
                "guest_file_too_large",
                "File transfer supports at most1MiB of decoded file content",
            ));
        }
        let mut content = Vec::new();
        Read::by_ref(&mut file)
            .take(guest::MAX_FILE_BYTES as u64 + 1)
            .read_to_end(&mut content)?;
        if content.len() > guest::MAX_FILE_BYTES {
            return Err(Error::new(
                "guest_file_too_large",
                "File grew beyond the1MiB transfer limit",
            ));
        }
        let result = self.guest_request(
            id,
            "file.write",
            json!({"name":name,"content_base64":BASE64.encode(&content)}),
        )?;
        if result.get("name").and_then(Value::as_str) != Some(name)
            || result.get("bytes_written").and_then(Value::as_u64) != Some(content.len() as u64)
        {
            return Err(Error::new(
                "guest_agent_protocol",
                "Guest agent file acknowledgment does not match the requested file",
            ));
        }
        let path = result.get("path").and_then(Value::as_str).ok_or_else(|| {
            Error::new(
                "guest_agent_protocol",
                "Guest file acknowledgment has no informational guest path",
            )
        })?;
        if path.len() > 4096 {
            return Err(Error::new(
                "guest_agent_protocol",
                "Guest file path exceeds the protocol limit",
            ));
        }
        // Guest-reported paths are returned for display only and are never
        // opened, evaluated or resolved against the host filesystem.
        Ok(json!({"name":name,"bytes_written":content.len(),"path":path}))
    }

    pub fn guest_clipboard_write_file(&self, id: &str, path: &Path) -> Result<Value> {
        self.config(id)?;
        if !path.is_absolute() {
            return Err(Error::new(
                "invalid_source_path",
                "Clipboard text file path must be absolute",
            ));
        }
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            return Err(Error::new(
                "invalid_source_path",
                "Clipboard text source must be a regular file",
            ));
        }
        if metadata.len() > guest::MAX_CLIPBOARD_BYTES as u64 {
            return Err(Error::new(
                "clipboard_too_large",
                "Clipboard text exceeds256KiB of UTF-8",
            ));
        }
        let mut bytes = Vec::new();
        Read::by_ref(&mut file)
            .take(guest::MAX_CLIPBOARD_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > guest::MAX_CLIPBOARD_BYTES {
            return Err(Error::new(
                "clipboard_too_large",
                "Clipboard text file grew beyond256KiB",
            ));
        }
        let text = String::from_utf8(bytes).map_err(|_| {
            Error::new(
                "invalid_clipboard_encoding",
                "Clipboard text source must be valid UTF-8",
            )
        })?;
        self.guest_clipboard_write(id, &text)
    }

    pub fn import_disk(
        &self,
        name: &str,
        source: &Path,
        cpus: u16,
        memory_mib: u64,
        iso: Option<&Path>,
    ) -> Result<Value> {
        validate_name(name)?;
        self.validate_host(cpus, memory_mib)?;
        if !source.is_absolute() {
            return Err(Error::new(
                "invalid_disk_path",
                "Disk import source path must be absolute",
            ));
        }
        let source = source
            .canonicalize()
            .map_err(|e| Error::io("Cannot access source disk", e))?;
        if !fs::metadata(&source)?.is_file() {
            return Err(Error::new(
                "invalid_disk_path",
                "Disk import source must be a regular image file",
            ));
        }
        let image = image_tool(&self.tools)?;
        let info = inspect_import(&image, &source)?;
        let disk_gib = info.virtual_size.div_ceil(1024 * 1024 * 1024).max(64);
        validate_resources(cpus, memory_mib, disk_gib)?;
        let iso_path = iso.map(validate_iso).transpose()?;
        let guest_tools_iso_path = self
            .tools
            .guest_tools_iso_path
            .as_deref()
            .map(validate_iso)
            .transpose()?;
        let code = self
            .tools
            .require(&self.tools.firmware_code_path, "AArch64 UEFI firmware")?;
        let vars = self.tools.require(
            &self.tools.firmware_vars_path,
            "AArch64 UEFI variables template",
        )?;
        let id = Uuid::new_v4().to_string();
        let destination = self.store.vm_dir(&id)?;
        let config = Config {
            format_version: 1,
            id: id.clone(),
            name: name.trim().into(),
            cpus,
            memory_mib,
            disk_gib,
            iso_path,
            guest_tools_iso_path,
            created_at: chrono::Utc::now().to_rfc3339(),
            firmware_code_path: destination.join("efi-code.fd"),
            tpm_enabled: self.tools.swtpm_path.is_some(),
            secure_boot_state: if self.tools.firmware_secure_boot_capable {
                "unverified"
            } else {
                "unsupported_firmware"
            }
            .into(),
            mac_address: new_mac(&id)?,
            keyboard_layout: "en-us".into(),
            audio_output: false,
        };
        let staging = self.store.root.join("VMs").join(format!(".import-{id}"));
        private_dir(&staging)?;
        let result = (|| {
            run_output(
                Command::new(&image)
                    .args(["convert", "-f", &info.format, "-O", "qcow2"])
                    .arg(&source)
                    .arg(staging.join("system.qcow2")),
                "Import independent VM disk",
            )?;
            let capacity = disk_gib * 1024 * 1024 * 1024;
            if capacity > info.virtual_size {
                run_output(
                    Command::new(&image)
                        .args(["resize", "-f", "qcow2"])
                        .arg(staging.join("system.qcow2"))
                        .arg(capacity.to_string()),
                    "Expand imported disk capacity",
                )?;
            }
            fs::copy(code, staging.join("efi-code.fd"))?;
            prepare_variables(vars, &staging.join("efi-vars.fd"), &image)?;
            if config.tpm_enabled {
                private_dir(&staging.join("tpm"))?;
            }
            atomic_json(&staging.join("config.json"), &config)?;
            fs::rename(&staging, &destination)?;
            Ok(
                json!({"vm":self.view(&config)?,"source_disk_path":source,"source_format":info.format,"independent_disk":true,
                "warnings":["Import copies disk contents into a new VM with fresh firmware and TPM state. An encrypted guest may need its recovery key; Windows may need drivers or activation. ARM64 guest compatibility is not established by the disk container format."]}),
            )
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(&staging);
        }
        result
    }

    fn validate_host(&self, cpus: u16, memory_mib: u64) -> Result<()> {
        let available = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1);
        if usize::from(cpus) > available {
            return Err(Error::new(
                "host_resources",
                format!("This host has {available} logical CPUs; requested {cpus}"),
            ));
        }
        let memory = host_memory_bytes();
        if memory > 0
            && memory_mib.saturating_mul(1024 * 1024) > memory.saturating_sub(1024 * 1024 * 1024)
        {
            return Err(Error::new(
                "host_resources",
                "VM memory must leave at least 1 GiB for macOS",
            ));
        }
        Ok(())
    }

    /// Return only when an actual process probe establishes that the VM is
    /// offline. An unreadable or mismatched live process always blocks writes.
    fn ensure_offline(&self, id: &str) -> Result<()> {
        if let Some(runtime) = self.runtime(id)? {
            if self.qmp(id, &runtime).is_ok()
                || !matches!(
                    process_state(&runtime, &self.store.runtime_dir(id)?.join("qmp.sock")),
                    ProcessState::Gone
                )
            {
                return Err(Error::new("vm_running","VM must be completely stopped before this operation; control or process evidence still indicates a live VM"));
            }
        } else if let Some(job) = self.launch_job(id)? {
            if self.launch_qmp(id, &job).is_ok()
                || launch_process_exists(
                    &job.launch_name,
                    &self.store.runtime_dir(id)?.join("qmp.sock"),
                )?
            {
                return Err(Error::new("vm_running","This VM's runtime metadata is incomplete, but its owned QEMU launch is still live. Stop it before changing persistent state."));
            }
        } else if std::os::unix::net::UnixStream::connect(
            self.store.runtime_dir(id)?.join("qmp.sock"),
        )
        .is_ok()
        {
            return Err(Error::new("untracked_vm","A live VM control socket has no launch metadata. Refusing to change persistent state or signal an unverified process."));
        }
        let directory = self.store.runtime_dir(id)?;
        if directory.exists() {
            let lock = OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(directory.join("supervisor.lock"))?;
            lock.try_lock_exclusive().map_err(|_| {
                Error::new(
                    "vm_starting",
                    "The VM supervisor is still active; wait for it to finish",
                )
            })?;
        }
        Ok(())
    }

    fn clear_runtime(&self, id: &str) -> Result<()> {
        self.ensure_offline(id)?;
        let directory = self.store.runtime_dir(id)?;
        if directory.exists() {
            private_dir(&directory)?;
            fs::remove_dir_all(directory)?;
        }
        Ok(())
    }

    fn require_stopped(&self, id: &str) -> Result<Config> {
        let config = self.config(id)?;
        self.ensure_offline(id)?;
        if self.view(&config)?.state != "stopped" {
            return Err(Error::new("vm_not_stopped","VM is not stopped. Acknowledge a terminated/crashed launch with stop --force before changing persistent state"));
        }
        Ok(config)
    }

    pub fn start(&self, id: &str) -> Result<Value> {
        let config = self.config(id)?;
        self.ensure_offline(id)?;
        if !hypervisor_available() {
            return Err(Error::new(
                "hypervisor_unavailable",
                "The HVF backend requires an Apple Silicon Mac with Hypervisor.framework support",
            ));
        }
        self.validate_host(config.cpus, config.memory_mib)?;
        let qemu = self
            .tools
            .require(&self.tools.qemu_path, "qemu-system-aarch64")?
            .to_path_buf();
        if config.tpm_enabled {
            self.tools
                .require(&self.tools.swtpm_path, "swtpm (required by this VM)")?;
        }
        let directory = self.store.vm_dir(id)?;
        for name in ["system.qcow2", "efi-code.fd", "efi-vars.fd"] {
            assert_regular(&directory.join(name))?;
        }
        if config.tpm_enabled && !directory.join("tpm").is_dir() {
            return Err(Error::new(
                "missing_tpm_state",
                "This VM's persistent TPM directory is missing; refusing to silently reset its TPM",
            ));
        }
        repair_variables(&directory.join("efi-vars.fd"), &image_tool(&self.tools)?)?;
        if let Some(iso) = &config.iso_path {
            validate_iso(iso)?;
        }
        if let Some(iso) = &config.guest_tools_iso_path {
            validate_iso(iso)?;
        }
        self.clear_runtime(id)?;
        let runtime_dir = self.store.runtime_dir(id)?;
        private_dir(&runtime_dir)?;
        let launch_name = format!("perpendicular-{}-{}", id, Uuid::new_v4().simple());
        let job = LaunchJob {
            config: config.clone(),
            vm_dir: directory.clone(),
            runtime_dir: runtime_dir.clone(),
            launch_name,
            qemu,
            swtpm: self.tools.swtpm_path.clone(),
        };
        let mut supervisor = launch_supervisor(&job)?;
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if let Some(runtime) = self.runtime(id)? {
                if let Ok(mut qmp) = self.qmp(id, &runtime) {
                    qmp.execute("cont", json!({}))?;
                    drop(qmp);
                    return Ok(json!({"vm":self.view(&config)?}));
                }
            }
            if runtime_dir.join("exit.json").exists() || supervisor.try_wait()?.is_some() {
                return Err(Error::new(
                    "vm_start_failed",
                    format!(
                        "VM could not start. {} {}",
                        self.view(&config)?.last_error.unwrap_or_default(),
                        log_tail(&directory.join("qemu.log"))
                    ),
                ));
            }
            if Instant::now() > deadline {
                return Err(Error::new("vm_start_timeout","QEMU has not exposed a valid control endpoint within 20 seconds. Its supervisor remains tracked; inspect list and the VM logs before retrying."));
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn pause_or_resume(&self, id: &str, resume: bool) -> Result<Value> {
        let config = self.config(id)?;
        let runtime = self
            .runtime(id)?
            .ok_or_else(|| Error::new("vm_not_running", "VM is not running"))?;
        let mut qmp = self.qmp(id, &runtime)?;
        let state = qmp.status()?;
        if resume && state != "paused" && state != "prelaunch" {
            return Err(Error::new(
                "invalid_state",
                format!("Cannot resume a VM with QEMU state {state}"),
            ));
        }
        if !resume && state != "running" {
            return Err(Error::new(
                "invalid_state",
                format!("Cannot pause a VM with QEMU state {state}"),
            ));
        }
        qmp.execute(if resume { "cont" } else { "stop" }, json!({}))?;
        drop(qmp);
        Ok(json!({"vm":self.view(&config)?}))
    }

    pub fn stop(&self, id: &str, force: bool) -> Result<Value> {
        let config = self.config(id)?;
        let Some(mut runtime) = self.runtime(id)? else {
            if let Some(job) = self.launch_job(id)? {
                if let Ok(mut qmp) = self.launch_qmp(id, &job) {
                    if force {
                        qmp.execute("quit", json!({}))?;
                    } else {
                        qmp.guest_shutdown()?;
                    }
                    drop(qmp);
                    if force {
                        return self.wait_for_stop(id, &config);
                    }
                    atomic_json(
                        &self.store.runtime_dir(id)?.join("shutdown-requested.json"),
                        &json!({"launch_name":job.launch_name,"requested_at":chrono::Utc::now().to_rfc3339()}),
                    )?;
                    return Ok(json!({"vm":self.view(&config)?}));
                }
            }
            self.clear_runtime(id)?;
            return Ok(json!({"vm":self.view(&config)?}));
        };
        let mut qmp = match self.qmp(id, &runtime) {
            Ok(qmp) => qmp,
            Err(error) => {
                if matches!(
                    process_state(&runtime, &self.store.runtime_dir(id)?.join("qmp.sock")),
                    ProcessState::Gone
                ) {
                    self.clear_runtime(id)?;
                    return Ok(json!({"vm":self.view(&config)?}));
                }
                return Err(Error::new("control_unavailable",format!("Cannot stop safely because the owned VM control endpoint is unavailable. No PID was signalled. {}",error.message)));
            }
        };
        if force {
            let result = qmp.execute("quit", json!({}));
            drop(qmp);
            if let Err(error) = result {
                if error.code != "qmp_closed" {
                    return Err(error);
                }
            }
            return self.wait_for_stop(id, &config);
        }
        qmp.guest_shutdown()?;
        drop(qmp);
        runtime.shutdown_requested = true;
        atomic_json(&self.store.runtime_dir(id)?.join("runtime.json"), &runtime)?;
        Ok(json!({"vm":self.view(&config)?}))
    }

    fn wait_for_stop(&self, id: &str, config: &Config) -> Result<Value> {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if self.ensure_offline(id).is_ok() {
                self.clear_runtime(id)?;
                return Ok(json!({"vm":self.view(config)?}));
            }
            thread::sleep(Duration::from_millis(50));
        }
        Err(Error::new(
            "stop_pending",
            "QEMU accepted quit; the supervisor has not finished yet. Refresh the VM list.",
        ))
    }

    pub fn eject_iso(&self, id: &str) -> Result<Value> {
        self.eject_media(id, false)
    }

    pub fn eject_guest_tools(&self, id: &str) -> Result<Value> {
        self.eject_media(id, true)
    }

    fn eject_media(&self, id: &str, guest_tools: bool) -> Result<Value> {
        let mut config = self.config(id)?;
        if guest_tools && config.guest_tools_iso_path.is_none() {
            return Ok(json!({"vm":self.view(&config)?}));
        }
        let device = if guest_tools {
            "guesttoolscd"
        } else {
            "installcd"
        };
        if let Some(runtime) = self.runtime(id)? {
            match self.qmp(id, &runtime) {
                Ok(mut qmp) => {
                    qmp.execute("blockdev-open-tray", json!({"id":device,"force":true}))?;
                    qmp.execute("blockdev-remove-medium", json!({"id":device}))?;
                }
                Err(_) => self.ensure_offline(id)?,
            }
        } else {
            self.ensure_offline(id)?;
        }
        if guest_tools {
            config.guest_tools_iso_path = None;
        } else {
            config.iso_path = None;
        }
        atomic_json(&self.store.vm_dir(id)?.join("config.json"), &config)?;
        Ok(json!({"vm":self.view(&config)?}))
    }

    pub fn update(&self, id: &str, options: UpdateOptions<'_>) -> Result<Value> {
        let mut config = self.require_stopped(id)?;
        if let Some(name) = options.name {
            validate_name(name)?;
            config.name = name.trim().into();
        }
        if let Some(cpus) = options.cpus {
            config.cpus = cpus;
        }
        if let Some(memory) = options.memory_mib {
            config.memory_mib = memory;
        }
        if let Some(iso) = options.iso {
            config.iso_path = Some(validate_iso(iso)?);
        }
        if let Some(iso) = options.guest_tools_iso {
            config.guest_tools_iso_path = Some(validate_iso(iso)?);
        }
        if let Some(layout) = options.keyboard_layout {
            validate_keyboard_layout(layout)?;
            config.keyboard_layout = layout.into();
        }
        if let Some(enabled) = options.audio_output {
            config.audio_output = enabled;
        }
        validate_resources(config.cpus, config.memory_mib, config.disk_gib)?;
        self.validate_host(config.cpus, config.memory_mib)?;
        atomic_json(&self.store.vm_dir(id)?.join("config.json"), &config)?;
        Ok(json!({"vm":self.view(&config)?}))
    }

    pub fn delete(&self, id: &str) -> Result<Value> {
        self.require_stopped(id)?;
        self.clear_runtime(id)?;
        let trash = self
            .store
            .root
            .join("Trash")
            .join(format!("{id}-{}", Uuid::new_v4()));
        private_dir(&trash)?;
        atomic_json(
            &trash.join("deletion.json"),
            &json!({"id":id,"deleted_at":chrono::Utc::now().to_rfc3339(),"reason":"user_deleted"}),
        )?;
        let directory = self.store.vm_dir(id)?;
        fs::rename(&directory, trash.join("vm"))?;
        let snapshots = self.store.snapshots_dir(id)?;
        if snapshots.exists() {
            if let Err(error) = fs::rename(&snapshots, trash.join("snapshots")) {
                let _ = fs::rename(trash.join("vm"), directory);
                return Err(error.into());
            }
        }
        Ok(json!({"deleted":id,"trash_directory":trash}))
    }

    pub fn snapshots(&self, id: &str) -> Result<Value> {
        self.config(id)?;
        let mut snapshots = Vec::new();
        let root = self.store.snapshots_dir(id)?;
        if root.exists() {
            private_dir(&root)?;
            for entry in fs::read_dir(root)? {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                Store::id(&name)?;
                let snapshot: Snapshot = read_json(&entry.path().join("snapshot.json"))?;
                if snapshot.vm_id != id || snapshot.id != name {
                    return Err(Error::new(
                        "invalid_snapshot",
                        "Snapshot identity does not match its directory",
                    ));
                }
                snapshots.push(snapshot);
            }
        }
        snapshots.sort_by(|a, b| a.created_at.cmp(&b.created_at));
        Ok(json!({"snapshots":snapshots}))
    }

    pub fn snapshot_create(&self, id: &str, name: &str) -> Result<Value> {
        validate_name(name)?;
        let config = self.require_stopped(id)?;
        let image = image_tool(&self.tools)?;
        let root = self.store.snapshots_dir(id)?;
        private_dir(&root)?;
        let snapshot_id = Uuid::new_v4().to_string();
        let staging = root.join(format!(".create-{snapshot_id}"));
        private_dir(&staging)?;
        let snapshot = Snapshot {
            id: snapshot_id.clone(),
            name: name.trim().into(),
            created_at: chrono::Utc::now().to_rfc3339(),
            vm_id: id.into(),
            consistency: "offline_disk_firmware_tpm".into(),
        };
        let result = (|| {
            self.copy_vm_state(&self.store.vm_dir(id)?, &staging, &image)?;
            atomic_json(&staging.join("config.json"), &config)?;
            atomic_json(&staging.join("snapshot.json"), &snapshot)?;
            fs::rename(&staging, root.join(&snapshot_id))?;
            Ok(json!({"snapshot":snapshot}))
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(staging);
        }
        result
    }

    fn copy_vm_state(&self, source: &Path, target: &Path, image: &Path) -> Result<()> {
        for name in ["system.qcow2", "efi-code.fd", "efi-vars.fd"] {
            assert_regular(&source.join(name))?;
        }
        run_output(
            Command::new(image)
                .args(["convert", "-f", "qcow2", "-O", "qcow2"])
                .arg(source.join("system.qcow2"))
                .arg(target.join("system.qcow2")),
            "Copy offline VM disk",
        )?;
        for name in ["efi-code.fd", "efi-vars.fd"] {
            fs::copy(source.join(name), target.join(name))?;
        }
        if source.join("tpm").exists() {
            copy_tree(&source.join("tpm"), &target.join("tpm"))?;
        }
        Ok(())
    }

    fn snapshot(&self, id: &str, snapshot_id: &str) -> Result<(PathBuf, Snapshot)> {
        Store::id(snapshot_id)?;
        let path = self.store.snapshots_dir(id)?.join(snapshot_id);
        private_dir_existing(&path)?;
        let snapshot: Snapshot = read_json(&path.join("snapshot.json"))?;
        if snapshot.id != snapshot_id || snapshot.vm_id != id {
            return Err(Error::new(
                "invalid_snapshot",
                "Snapshot belongs to another VM",
            ));
        }
        Ok((path, snapshot))
    }

    pub fn snapshot_restore(&self, id: &str, snapshot_id: &str) -> Result<Value> {
        self.require_stopped(id)?;
        let (snapshot, _) = self.snapshot(id, snapshot_id)?;
        let image = image_tool(&self.tools)?;
        let config: Config = read_json(&snapshot.join("config.json"))?;
        if config.id != id
            || config.firmware_code_path != self.store.vm_dir(id)?.join("efi-code.fd")
        {
            return Err(Error::new(
                "invalid_snapshot",
                "Snapshot configuration identity is invalid",
            ));
        }
        validate_name(&config.name)?;
        validate_resources(config.cpus, config.memory_mib, config.disk_gib)?;
        let staging = self
            .store
            .root
            .join("VMs")
            .join(format!(".restore-{}", Uuid::new_v4()));
        private_dir(&staging)?;
        let result = (|| {
            self.copy_vm_state(&snapshot, &staging, &image)?;
            atomic_json(&staging.join("config.json"), &config)?;
            self.clear_runtime(id)?;
            let directory = self.store.vm_dir(id)?;
            let backup = self
                .store
                .root
                .join("Trash")
                .join(format!("{id}-before-restore-{}", Uuid::new_v4()));
            fs::rename(&directory, &backup)?;
            if let Err(error) = fs::rename(&staging, &directory) {
                let _ = fs::rename(&backup, &directory);
                return Err(error.into());
            }
            Ok(
                json!({"vm":self.view(&config)?,"restored_snapshot":snapshot_id,"previous_state_directory":backup}),
            )
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(staging);
        }
        result
    }

    pub fn snapshot_delete(&self, id: &str, snapshot_id: &str) -> Result<Value> {
        self.require_stopped(id)?;
        let (path, _) = self.snapshot(id, snapshot_id)?;
        let trash = self
            .store
            .root
            .join("Trash")
            .join(format!("snapshot-{snapshot_id}-{}", Uuid::new_v4()));
        fs::rename(path, &trash)?;
        Ok(json!({"deleted_snapshot":snapshot_id,"trash_directory":trash}))
    }
}

fn new_mac(id: &str) -> Result<String> {
    let uuid = Store::id(id)?;
    let bytes = uuid.as_bytes();
    Ok(format!(
        "52:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
        bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

fn private_dir_existing(path: &Path) -> Result<()> {
    if !path.exists() {
        return Err(Error::new("snapshot_not_found", "Snapshot does not exist"));
    }
    private_dir(path)
}

fn validate_iso(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        return Err(Error::new(
            "invalid_iso",
            "Windows installation ISO path must be absolute",
        ));
    }
    let canonical = path
        .canonicalize()
        .map_err(|e| Error::io("Cannot access installation ISO", e))?;
    let metadata = fs::metadata(&canonical)?;
    if !metadata.is_file() || metadata.len() < 2048 {
        return Err(Error::new(
            "invalid_iso",
            "Installation media must be a readable ISO image of at least 2048 bytes",
        ));
    }
    File::open(&canonical).map_err(|e| Error::io("Cannot read installation ISO", e))?;
    Ok(canonical)
}

fn log_tail(path: &Path) -> String {
    let Ok(mut file) = File::open(path) else {
        return String::new();
    };
    let Ok(size) = file.metadata().map(|m| m.len()) else {
        return String::new();
    };
    let _ = file.seek(SeekFrom::Start(size.saturating_sub(4096)));
    let mut data = Vec::new();
    let _ = file.take(4096).read_to_end(&mut data);
    String::from_utf8_lossy(&data).trim().to_owned()
}
