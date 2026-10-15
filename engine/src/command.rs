use crate::error::{Error, Result};
use crate::model::Config;
use crate::tools::Tools;
use serde_json::json;
use std::path::{Path, PathBuf};

fn path_text(path: &Path) -> Result<&str> {
    path.to_str()
        .ok_or_else(|| Error::new("invalid_path", "QEMU requires UTF-8 paths"))
}

/// Every element is passed directly to Command::arg; user input is never shell
/// expanded. File paths use JSON block nodes so commas cannot inject options.
pub fn qemu_arguments(
    config: &Config,
    vm_dir: &Path,
    runtime_dir: &Path,
    launch_name: &str,
) -> Result<Vec<String>> {
    let qmp = runtime_dir.join("qmp.sock");
    let vnc = runtime_dir.join("vnc.sock");
    let agent = runtime_dir.join("agent.sock");
    if qmp.as_os_str().len() >= 104
        || vnc.as_os_str().len() >= 104
        || agent.as_os_str().len() >= 104
    {
        return Err(Error::new(
            "socket_path_too_long",
            "VM control socket path exceeds macOS sockaddr_un limit",
        ));
    }
    let mut args: Vec<String> = vec![
        "-name".into(),
        launch_name.into(),
        "-uuid".into(),
        config.id.clone(),
        "-machine".into(),
        "virt,gic-version=3,highmem=on,pflash0=ueficode,pflash1=uefivars".into(),
        "-accel".into(),
        "hvf".into(),
        "-cpu".into(),
        "host".into(),
        "-smp".into(),
        format!(
            "cpus={},sockets=1,cores={},threads=1",
            config.cpus, config.cpus
        ),
        "-m".into(),
        config.memory_mib.to_string(),
        "-k".into(),
        config.keyboard_layout.clone(),
        "-nodefaults".into(),
        "-display".into(),
        "none".into(),
        "-vga".into(),
        "none".into(),
        "-device".into(),
        "ramfb".into(),
        "-device".into(),
        "qemu-xhci,id=usb".into(),
        "-device".into(),
        "usb-kbd,bus=usb.0".into(),
        "-device".into(),
        "usb-tablet,bus=usb.0".into(),
        "-netdev".into(),
        "user,id=net0".into(),
        "-device".into(),
        format!("virtio-net-pci,netdev=net0,mac={}", config.mac_address),
        "-device".into(),
        "virtio-rng-pci".into(),
        "-boot".into(),
        "menu=on".into(),
        "-rtc".into(),
        "base=localtime".into(),
        "-qmp".into(),
        format!("unix:{},server=on,wait=off", path_text(&qmp)?),
        "-vnc".into(),
        format!("unix:{}", path_text(&vnc)?),
        "-serial".into(),
        format!("file:{}", path_text(&vm_dir.join("serial.log"))?),
        "-monitor".into(),
        "none".into(),
        "-S".into(),
    ];
    for (node, path, readonly, format) in [
        ("ueficode", config.firmware_code_path.clone(), true, "raw"),
        ("uefivars", vm_dir.join("efi-vars.fd"), false, "raw"),
        ("system", vm_dir.join("system.qcow2"), false, "qcow2"),
    ] {
        args.extend(["-blockdev".into(),json!({"driver":"file","node-name":format!("{node}-file"),"filename":path,"read-only":readonly}).to_string()]);
        args.extend(["-blockdev".into(),json!({"driver":format,"node-name":node,"file":format!("{node}-file"),"read-only":readonly}).to_string()]);
    }
    args.extend([
        "-device".into(),
        format!(
            "nvme,drive=system,serial=perp{},bootindex=1",
            &config.id.replace('-', "")[..12]
        ),
    ]);
    if let Some(iso) = &config.iso_path {
        args.extend([
            "-blockdev".into(),
            json!({"driver":"file","node-name":"installiso-file","filename":iso,"read-only":true})
                .to_string(),
        ]);
        args.extend(["-blockdev".into(),json!({"driver":"raw","node-name":"installiso","file":"installiso-file","read-only":true}).to_string()]);
    } else {
        args.extend([
            "-drive".into(),
            "if=none,media=cdrom,id=installiso,readonly=on".into(),
        ]);
    }
    args.extend([
        "-device".into(),
        "usb-bot,id=installusb,bus=usb.0".into(),
        "-device".into(),
        "scsi-cd,id=installcd,drive=installiso,bus=installusb.0,bootindex=2".into(),
    ]);
    if let Some(iso) = &config.guest_tools_iso_path {
        args.extend([
            "-blockdev".into(),
            json!({"driver":"file","node-name":"guesttools-file","filename":iso,"read-only":true})
                .to_string(),
        ]);
        args.extend(["-blockdev".into(), json!({"driver":"raw","node-name":"guesttools","file":"guesttools-file","read-only":true}).to_string()]);
        args.extend([
            "-device".into(),
            "usb-bot,id=guesttoolsusb,bus=usb.0".into(),
            "-device".into(),
            "scsi-cd,id=guesttoolscd,drive=guesttools,bus=guesttoolsusb.0".into(),
        ]);
    }
    if config.tpm_enabled {
        // -chardev uses QEMU keyval syntax, not QAPI Chardev JSON. Paths here
        // are generated solely by the engine and cannot contain commas.
        args.extend([
            "-chardev".into(),
            format!(
                "socket,id=chrtpm,path={}",
                path_text(&runtime_dir.join("swtpm.sock"))?
            ),
        ]);
        args.extend([
            "-tpmdev".into(),
            "emulator,id=tpm0,chardev=chrtpm".into(),
            "-device".into(),
            // QEMU 11's default PPI MMIO region is only 0x400 bytes. Apple
            // HVF requires host-page aligned mappings (16 KiB on Apple Silicon),
            // so disable this optional physical-presence interface while
            // retaining the real TPM 2.0 device and persistent swtpm state.
            "tpm-tis-device,tpmdev=tpm0,ppi=off".into(),
        ]);
    }
    // Keep newly introduced PCI devices after the existing NVMe controller so
    // older VM UEFI boot device paths retain the same PCI slot assignment.
    args.extend([
        "-device".into(),
        "virtio-serial-pci,id=guestserial".into(),
        "-chardev".into(),
        format!(
            "socket,id=guestagent,path={},server=on,wait=off",
            path_text(&agent)?
        ),
        "-device".into(),
        "virtserialport,bus=guestserial.0,chardev=guestagent,name=org.perpendicular.guest_agent.0"
            .into(),
    ]);
    if config.audio_output {
        args.extend([
            "-audiodev".into(),
            "coreaudio,id=audio0".into(),
            "-device".into(),
            "ich9-intel-hda,id=hda0".into(),
            "-device".into(),
            "hda-output,bus=hda0.0,audiodev=audio0".into(),
        ]);
    }
    Ok(args)
}

pub fn swtpm_arguments(runtime_dir: &Path) -> Result<Vec<String>> {
    Ok(vec![
        "socket".into(),
        "--tpm2".into(),
        "--tpmstate".into(),
        // The supervisor sets cwd to the VM directory. This fixed relative
        // path avoids swtpm keyval parsing user-controlled directory commas.
        "dir=tpm".into(),
        "--ctrl".into(),
        format!(
            "type=unixio,path={}",
            path_text(&runtime_dir.join("swtpm.sock"))?
        ),
        "--terminate".into(),
    ])
}

pub fn image_tool(tools: &Tools) -> Result<PathBuf> {
    Ok(tools
        .require(&tools.qemu_img_path, "qemu-img")?
        .to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> Config {
        Config {
            format_version: 1,
            id: "8f14e45f-ea1d-4b93-8e48-1bce011bff55".into(),
            name: "Windows,Guest".into(),
            cpus: 4,
            memory_mib: 8192,
            disk_gib: 64,
            iso_path: Some("/Volumes/Windows, installer.iso".into()),
            guest_tools_iso_path: Some("/Volumes/Drivers, tools.iso".into()),
            created_at: "now".into(),
            firmware_code_path: "/tools/code.fd".into(),
            tpm_enabled: true,
            secure_boot_state: "unverified".into(),
            mac_address: "52:54:00:12:34:56".into(),
            keyboard_layout: "en-us".into(),
            audio_output: false,
        }
    }
    #[test]
    fn hardware_has_inbox_disk_local_sockets_and_no_shell_injection() {
        let args = qemu_arguments(
            &config(),
            Path::new("/VM data/windows"),
            Path::new("/tmp/perp/unit"),
            "owned-launch",
        )
        .unwrap();
        assert!(args.windows(2).any(|p| p == ["-accel", "hvf"]));
        assert!(args.iter().any(|arg| arg.starts_with("nvme,drive=system")));
        assert!(args.iter().any(|arg| arg.starts_with("virtio-net-pci")));
        assert!(args.windows(2).any(|pair| pair == ["-device", "ramfb"]));
        assert!(
            args.iter()
                .any(|arg| arg
                    == "scsi-cd,id=installcd,drive=installiso,bus=installusb.0,bootindex=2")
        );
        assert!(!args.iter().any(|arg| arg.starts_with("usb-storage")));
        assert!(args
            .iter()
            .any(|arg| arg == "tpm-tis-device,tpmdev=tpm0,ppi=off"));
        assert!(!args.iter().any(|arg| arg.contains("tcp:")));
        assert!(args.iter().any(|arg|arg=="virtserialport,bus=guestserial.0,chardev=guestagent,name=org.perpendicular.guest_agent.0"));
        assert!(
            args.iter()
                .position(|arg| arg.starts_with("nvme,drive=system"))
                .unwrap()
                < args
                    .iter()
                    .position(|arg| arg == "virtio-serial-pci,id=guestserial")
                    .unwrap()
        );
        assert!(args
            .iter()
            .any(|arg| arg
                == "socket,id=guestagent,path=/tmp/perp/unit/agent.sock,server=on,wait=off"));
        let block = args
            .iter()
            .filter_map(|arg| serde_json::from_str::<serde_json::Value>(arg).ok())
            .find(|arg| arg["node-name"] == "installiso-file")
            .unwrap();
        assert_eq!(block["filename"], "/Volumes/Windows, installer.iso");
        assert!(!args.iter().any(|arg| arg.contains("Windows,Guest")));
        let tools = args
            .iter()
            .filter_map(|arg| serde_json::from_str::<serde_json::Value>(arg).ok())
            .find(|arg| arg["node-name"] == "guesttools-file")
            .unwrap();
        assert_eq!(tools["filename"], "/Volumes/Drivers, tools.iso");
        assert!(args
            .iter()
            .any(|arg| arg == "scsi-cd,id=guesttoolscd,drive=guesttools,bus=guesttoolsusb.0"));
    }
    #[test]
    fn ejected_install_media_keeps_empty_removable_drive() {
        let mut c = config();
        c.iso_path = None;
        c.tpm_enabled = false;
        let args =
            qemu_arguments(&c, Path::new("/vm"), Path::new("/tmp/runtime"), "launch").unwrap();
        assert!(args
            .iter()
            .any(|arg| arg == "if=none,media=cdrom,id=installiso,readonly=on"));
        assert!(!args.iter().any(|arg| arg == "-tpmdev"));
    }

    #[test]
    fn italian_keyboard_and_optional_coreaudio_have_output_codec_only() {
        let mut c = config();
        c.keyboard_layout = "it".into();
        c.audio_output = true;
        let args =
            qemu_arguments(&c, Path::new("/vm"), Path::new("/tmp/runtime"), "launch").unwrap();
        assert!(args.windows(2).any(|pair| pair == ["-k", "it"]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["-audiodev", "coreaudio,id=audio0"]));
        assert!(args
            .iter()
            .any(|arg| arg == "hda-output,bus=hda0.0,audiodev=audio0"));
        assert!(!args.iter().any(|arg| arg.contains("hda-duplex")
            || arg.contains("hda-micro")
            || arg.contains("capture")));
    }
}
