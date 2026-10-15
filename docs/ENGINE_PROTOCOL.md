# Perpendicular engine protocol

This is the initial contract between the independent Rust engine and the native macOS app. The product target is a complete Windows 11 ARM desktop virtualization experience on Apple Silicon. The QEMU/HVF backend is a bootstrap backend; it is not the definition of completion.

The executable is `perpendicular-engine`. Every invocation prints one JSON object to stdout. Diagnostics go to stderr. An unsuccessful invocation exits nonzero and prints `{"error":{"code":"...","message":"..."}}`. Use snake_case JSON field names. Paths are absolute. User-facing text is English for this first implementation.

## Commands

- `system-info`: returns `{"architecture":"aarch64","memory_bytes":25769803776,"hypervisor_available":true,"qemu_path":null,"qemu_img_path":null,"firmware_code_path":null,"firmware_vars_path":null,"swtpm_path":null,"data_dir":"..."}`. Missing tools are represented by null.
- `list`: returns `{"vms":[Vm],"errors":[]}`. Per-VM read errors remain visible without hiding successfully loaded VMs.
- `create --name NAME --iso PATH --cpus 4 --memory-mib 8192 --disk-gib 64`: creates a new VM and returns `{"vm":Vm}`.
- `start ID`, `pause ID`, `resume ID`, `stop ID [--force]`, `eject-iso ID`: return `{"vm":Vm}`. Stop without force requests guest shutdown; state is refreshed by list. Force stops only the owned QEMU process for this VM.
- `update ID [--name NAME] [--cpus N] [--memory-mib M] [--iso PATH] [--keyboard-layout en-us|it] [--audio-output true|false]`: stopped VM configuration, returns `{"vm":Vm}`. Keyboard layout and output-only CoreAudio apply at the next start; no microphone device is exposed.
- `clone ID --name NAME`: stopped source only; independent storage, new identity/MAC and returned guest activation/TPM warnings.
- `import-disk --name NAME --disk PATH [--cpus N] [--memory-mib M] [--iso PATH]`: independent import of self-contained raw/qcow2, no backing chains. Returns the new VM and relevant recovery warnings.
- `export-disk ID --destination ABS_PATH --format qcow2|raw`: stopped VM only. Converts to an independent disk and publishes it without replacement at a new destination. Returns `{"export":{"vm_id":"...","path":"...","format":"qcow2","virtual_size_bytes":68719476736,"size_bytes":...}}`. The disk export excludes firmware, TPM state and snapshots. SIGINT/SIGTERM terminates and reaps only the owned conversion child and removes its staging area; abrupt power loss or SIGKILL can leave an unpublished private staging folder.
- `update ID --guest-tools-iso PATH`, `eject-guest-tools ID`: attach a stopped VM's optional driver disc or eject it independently.
- `delete ID`: stopped VM only, moves its directory to an application-owned recoverable trash and returns `{"deleted":ID}`.
- `snapshots ID`: returns `{"snapshots":[{"id":"...","name":"...","created_at":"ISO8601"}]}`.
- `snapshot-create ID --name NAME`, `snapshot-restore ID SNAPSHOT_ID`, `snapshot-delete ID SNAPSHOT_ID`: return JSON and support stopped VMs initially. Online snapshot support remains in the feature checklist until implemented and verified.
- `guest-status ID`: returns `{"status":{...}}` with `connected`, explicit capabilities and guest-reported security values. A stopped guest, absent channel, timeout or unavailable agent returns an unavailable status with its actual reason.
- `guest-clipboard-read ID`: returns `{"text":"..."}` only on an explicit successful guest read.
- `guest-clipboard-write ID --text-file PATH` (or `--text TEXT`): returns `{"written":true}` only after a guest acknowledgement. The GUI uses a private temporary UTF-8 file to keep clipboard text out of arguments.
- `guest-file-push ID --source PATH --name BASENAME`: sends at most 1 MiB to the logged-in Windows user's Downloads folder without replacement; returns `name`, `bytes_written` and the guest-only path.

`Vm` has these fields:

```json
{
  "id":"UUID", "name":"Windows 11", "state":"stopped",
  "cpus":4, "memory_mib":8192, "disk_gib":64,
  "iso_path":"/path/to/windows.iso", "directory":"/path/to/vm",
  "disk_path":"/path/to/system.qcow2", "created_at":"ISO8601",
  "backend":"qemu-hvf", "qmp_socket":"/tmp/.../qmp.sock",
  "vnc_socket":"/tmp/.../vnc.sock", "last_error":null,
  "tpm_enabled":true, "secure_boot_state":"unverified",
  "guest_tools_iso_path":null, "keyboard_layout":"en-us", "audio_output":false
}
```

`state` is one of `stopped`, `starting`, `running`, `paused`, `stopping`, `crashed`. `iso_path` is nullable after ejection. Other fields above are always present. Additional fields are allowed and ignored by the app. Status must reflect an actual process/QMP query, not merely a saved PID or lock file.

## Storage and tool discovery

Default storage: `~/Library/Application Support/Perpendicular Desktop/VMs/ID`. Override the application data root using `PERPENDICULAR_DATA_DIR` for isolated tests. Put runtime sockets under an owned directory in `/tmp` to avoid the macOS Unix socket path limit. Bind no unauthenticated network listeners. Use 0700 runtime directories.

Tool overrides: `PERPENDICULAR_QEMU`, `PERPENDICULAR_QEMU_IMG`, `PERPENDICULAR_FIRMWARE_DIR`, `PERPENDICULAR_SWTPM`. Discover tools beside the application resources, in the repository `.tools` directory and then common executable paths. Root build tooling will provision `.tools/qemu/bin`, `.tools/qemu/share/qemu`, and `.tools/bin`.

## Bootstrap VM hardware

QEMU aarch64 `virt`, HVF accelerator, host CPU, UEFI firmware and private writable EFI variables, NVMe boot disk, USB keyboard/tablet, RAM framebuffer, user-mode NAT with VirtIO network. Start with a VNC Unix socket for the native app's embedded console and a separate QMP Unix socket for control. Windows drivers must come from independently redistributable upstream packages. Implement real TPM and Secure Boot support as part of Windows readiness, not installer bypasses. Never run the user's existing Parallels VMs as a test target.

Optical media uses explicit USB-BOT and `scsi-cd` devices. A generic storage frontend does not convey CD-ROM media type for a pure QAPI block node. TPM2 uses persistent swtpm state, with physical-presence MMIO disabled for QEMU 11/HVF page compatibility. Secure Boot capability is separate from a verified guest observation; filenames and provisioned configuration must not make the app report guest verification automatically.

The macOS app locates the engine via `PERPENDICULAR_ENGINE`, `Contents/Resources/perpendicular-engine`, or the repository build output. The framebuffer component accepts a Unix VNC socket path and forwards keyboard and pointer events. It does not own VM lifecycle.

Guest Tools use an additional private VirtIO serial Unix socket. Each exchange first verifies the VM's identity through its owned QMP channel, then applies a five-second absolute deadline, strict correlated response IDs and bounded UTF-8 NDJSON. Requests are at most 1.5 MiB, responses 1 MiB, clipboard text 256 KiB and decoded files 1 MiB. Readiness never fetches clipboard contents. The protocol and the interactive-user Windows installer are documented in [guest-tools/README.md](../guest-tools/README.md).
