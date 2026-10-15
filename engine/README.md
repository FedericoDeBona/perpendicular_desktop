# Perpendicular engine

Original Rust VM lifecycle and storage implementation for the native macOS application. The current backend uses upstream QEMU with Apple's HVF accelerator. Accelerated Windows graphics, shared folders, suspend-to-memory and live snapshots still require implementation. Explicit clipboard and file transfers require the Windows guest tools and guest validation.

Build with `cargo build --release`. The executable is `target/release/perpendicular-engine`. Every public command emits one JSON object on stdout, including errors. See `../docs/ENGINE_PROTOCOL.md` for the app contract.

Additional implemented commands:

- `guest-status ID`: queries the private guest agent and returns `status.connected` plus protocol/capability/security information, or an explicit unavailable reason. It requires a running VM whose UUID and launch name were verified through QMP.
- `guest-clipboard-read ID` and `guest-clipboard-write ID --text TEXT` (or `--text-file ABS_PATH`): explicit clipboard transfer only. The GUI can use a temporary UTF-8 file with mode 0600 to keep clipboard contents out of process arguments; the engine never changes the host clipboard itself.
- `guest-file-push ID --source ABS_PATH --name NAME`: explicitly transfers a regular file of at most 1 MiB into guest Downloads. Names must be safe Windows basenames. Guest paths are informational and are never opened on the host.
- `update ID --keyboard-layout en-us|it --audio-output true|false`: saves settings for the next VM start. Old VM metadata defaults to US keyboard and disabled audio. Optional CoreAudio playback uses an HDA output codec with no microphone device.
- `clone ID --name NAME`: fully copies an offline VM into independent qcow2 storage with a new VM UUID, MAC address and NVMe serial. EFI and TPM state remain coherent with the copied disk. If TPM is enabled its cryptographic state is copied; the result reports this and warns about activation and BitLocker recovery.
- `export-disk ID --destination ABS_PATH --format qcow2|raw`: exports only a stopped VM's disk into an independent image. Format is required, the destination folder must already exist, and any existing destination entry (including a broken symlink) is refused. A private temporary directory on the destination filesystem holds conversion output until atomic publication without replacement. The result is `{"export":{"vm_id":"…","path":"/canonical/path","format":"qcow2","virtual_size_bytes":0,"size_bytes":0}}`, with actual byte counts. EFI variables, TPM state and snapshots are separate VM data and are not included. SIGINT or SIGTERM cancels an unfinished conversion, stops only its owned converter and removes its staging files; after publication the completed export remains. SIGKILL or a power loss can leave a private staging directory for manual recovery.
- `import-disk --name NAME --disk ABS_PATH [--cpus N] [--memory-mib M] [--iso ABS_PATH]`: imports a self-contained offline raw or qcow2 disk into independent qcow2 storage. Backing chains and encrypted qcow2 containers are rejected. Capacity expands to at least 64 GiB; expanding a guest partition is separate. New EFI and TPM state may require an encrypted guest's recovery key. Disk format alone does not establish ARM64 guest compatibility.
- `update ID --guest-tools-iso ABS_PATH` and `eject-guest-tools ID`: attach an offline driver's disc or independently eject it. An optional sanitized `perpendicular-drivers.iso` is discovered beside the bundled engine or under `.tools/downloads/`; `PERPENDICULAR_GUEST_TOOLS_ISO` overrides this path. The original upstream guest-tools disc is deliberately not auto-discovered because its unattended answer file changes Windows setup and bypasses hardware checks.

Storage is private to the application data root, overridable with an absolute `PERPENDICULAR_DATA_DIR`. VM and snapshot identifiers must be canonical UUIDs. Filesystem operations are serialized, metadata is replaced atomically, symlinked VM state is rejected, and deletion/restoration preserves recovery copies in application Trash.

QMP control requires both the guest UUID and a unique per-launch name. State comes from actual QMP/process evidence and supervisor exit records. PID files never authorize a signal. Forced stop requests QMP `quit`; the supervisor only retains and cleans up exact child handles that it spawned. A live launch with missing metadata remains protected from disk mutations and can be stopped using its verified launch record.

Guest-agent IPC uses a VirtIO serial port named `org.perpendicular.guest_agent.0` and a Unix socket inside the VM's private runtime directory (mode 0700). Each operation uses one request/response with a random integer ID; malformed, mismatched and unsolicited records are rejected. The absolute exchange deadline is 5 seconds, including connect, send and receive. Serialized requests are bounded to 1.5 MiB, responses to 1 MiB, and clipboard text to 256 KiB of UTF-8. A 1 MiB file's base64 expansion is accounted for. The Windows guest tools must be installed and running before these capabilities are available; host fixtures do not establish guest installation success.

Windows hardware currently includes NVMe, VirtIO networking, a linear RAM framebuffer with UEFI GOP, USB input and an optional persistent swtpm TPM 2.0. TPM physical-presence MMIO is disabled on HVF because QEMU 11's 0x400-byte region is incompatible with Apple's 16 KiB host page mappings. Guest TPM functionality and Secure Boot must be checked inside Windows; a secure firmware filename is not evidence of enrolled keys or enabled guest Secure Boot. ARM flash variables are decoded from qcow2 when necessary and normalized to 64 MiB raw flash. Existing offline bootstrap variables are repaired atomically with a backup.

Physical USB passthrough remains unavailable. The [read-only USB investigation](USB_RESEARCH.md) records the confirmed inventory path, missing macOS capture authorization and upstream QEMU selection behavior that must be resolved before exposing explicit attach/detach.

Run `cargo test` and `cargo clippy --all-targets -- -D warnings`. The normal suite uses synthetic disks, fake firmware/image tools and an actual Unix QMP fixture; it does not claim Windows boot validation. Fixture cleanup stops owned mock VMs even after assertion failures.

Additional real-image tests are opt-in, keeping CI independent of a local QEMU installation:

```sh
PERPENDICULAR_TEST_QEMU_IMG=/absolute/path/qemu-img \
PERPENDICULAR_TEST_FIRMWARE_VARS=/absolute/path/qcow2-variables.fd \
cargo test real_qcow2_template_conversion_and_offline_repair_preserve_guest_bytes -- --ignored

PERPENDICULAR_TEST_QEMU_IMG=/absolute/path/qemu-img \
cargo test real_image_import_and_clone_are_independent_qcow2_and_preserve_source_bytes -- --ignored

PERPENDICULAR_TEST_QEMU_IMG=/absolute/path/qemu-img \
cargo test real_disk_exports_are_standalone_preserve_bytes_and_refuse_replacement -- --ignored
```

These verify real image conversion, byte equivalence, firmware repair backups, independent clone/import storage and integrity after source deletion. They operate on fresh temporary data and never execute an existing Parallels VM.
