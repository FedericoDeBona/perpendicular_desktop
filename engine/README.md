# Perpendicular engine

Original Rust VM lifecycle and storage implementation for the native macOS application. The current backend uses upstream QEMU with Apple's HVF accelerator. It is a bootstrap virtualization backend; accelerated Windows graphics, shared folders, clipboard integration, suspend-to-memory and live snapshots still require implementation and guest validation.

Build with `cargo build --release`. The executable is `target/release/perpendicular-engine`. Every public command emits one JSON object on stdout, including errors. See `../docs/ENGINE_PROTOCOL.md` for the app contract.

Additional implemented commands:

- `clone ID --name NAME`: fully copies an offline VM into independent qcow2 storage with a new VM UUID, MAC address and NVMe serial. EFI and TPM state remain coherent with the copied disk. If TPM is enabled its cryptographic state is copied; the result reports this and warns about activation and BitLocker recovery.
- `import-disk --name NAME --disk ABS_PATH [--cpus N] [--memory-mib M] [--iso ABS_PATH]`: imports a self-contained offline raw or qcow2 disk into independent qcow2 storage. Backing chains and encrypted qcow2 containers are rejected. Capacity expands to at least 64 GiB; expanding a guest partition is separate. New EFI and TPM state may require an encrypted guest's recovery key. Disk format alone does not establish ARM64 guest compatibility.
- `update ID --guest-tools-iso ABS_PATH` and `eject-guest-tools ID`: attach an offline driver's disc or independently eject it. An optional sanitized `perpendicular-drivers.iso` is discovered beside the bundled engine or under `.tools/downloads/`; `PERPENDICULAR_GUEST_TOOLS_ISO` overrides this path. The original upstream guest-tools disc is deliberately not auto-discovered because its unattended answer file changes Windows setup and bypasses hardware checks.

Storage is private to the application data root, overridable with an absolute `PERPENDICULAR_DATA_DIR`. VM and snapshot identifiers must be canonical UUIDs. Filesystem operations are serialized, metadata is replaced atomically, symlinked VM state is rejected, and deletion/restoration preserves recovery copies in application Trash.

QMP control requires both the guest UUID and a unique per-launch name. State comes from actual QMP/process evidence and supervisor exit records. PID files never authorize a signal. Forced stop requests QMP `quit`; the supervisor only retains and cleans up exact child handles that it spawned. A live launch with missing metadata remains protected from disk mutations and can be stopped using its verified launch record.

Windows hardware currently includes NVMe, VirtIO networking, a linear RAM framebuffer with UEFI GOP, USB input and an optional persistent swtpm TPM 2.0. TPM physical-presence MMIO is disabled on HVF because QEMU 11's 0x400-byte region is incompatible with Apple's 16 KiB host page mappings. Guest TPM functionality and Secure Boot must be checked inside Windows; a secure firmware filename is not evidence of enrolled keys or enabled guest Secure Boot. ARM flash variables are decoded from qcow2 when necessary and normalized to 64 MiB raw flash. Existing offline bootstrap variables are repaired atomically with a backup.

Run `cargo test` and `cargo clippy --all-targets -- -D warnings`. The normal suite uses synthetic disks, fake firmware/image tools and an actual Unix QMP fixture; it does not claim Windows boot validation. Fixture cleanup stops owned mock VMs even after assertion failures.

Two additional real-image tests are opt-in, keeping CI independent of a local QEMU installation:

```sh
PERPENDICULAR_TEST_QEMU_IMG=/absolute/path/qemu-img \
PERPENDICULAR_TEST_FIRMWARE_VARS=/absolute/path/qcow2-variables.fd \
cargo test real_qcow2_template_conversion_and_offline_repair_preserve_guest_bytes -- --ignored

PERPENDICULAR_TEST_QEMU_IMG=/absolute/path/qemu-img \
cargo test real_image_import_and_clone_are_independent_qcow2_and_preserve_source_bytes -- --ignored
```

These verify real image conversion, byte equivalence, firmware repair backups, independent clone/import storage and integrity after source deletion. They operate on fresh temporary data and never execute an existing Parallels VM.
