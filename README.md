# Perpendicular Desktop

An independent, native macOS desktop virtualization application for **Windows 11 ARM on Apple Silicon**. Written in SwiftUI/AppKit and Rust, with an initial QEMU/HVF backend and an embedded native VM console.

**Active reconstruction, not a finished replacement for Parallels Desktop.** The full feature and verification checklist is tracked in [docs/FEATURES.md](docs/FEATURES.md). UI appearance, a successful build and reaching the Windows installer are milestones, not proof of complete Windows desktop functionality or graphics parity.

## Build

Requires an Apple Silicon Mac with macOS 14+, Apple's Command Line Tools and Homebrew. Provision the Rust toolchain, native dependencies and pinned QEMU runtime:

```sh
./scripts/bootstrap.sh
```

Build the secure ARM firmware from the pinned QEMU/EDK2 source snapshot. It includes the linear framebuffer driver needed by Windows. Enroll an independent local platform certificate and the public Microsoft Windows 2011/2023 trust certificates:

```sh
brew install aarch64-elf-gcc acpica python@3.14
./scripts/build-secure-firmware.sh
python3 scripts/enroll-secure-vars.py
./scripts/provision-secure-firmware.sh .tools/edk2/enrolled
./scripts/build-app.sh
open "build/Perpendicular Desktop.app"
```

The enrollment tools are pinned by version and SHA-256 for macOS ARM64/Python 3.14; DBX authentication checks also require OpenSSL 3. The private platform key stays in `.tools/secure-boot/` with restricted permissions and is never bundled. Generated manifests record source, compiler flags and certificate provenance. New firmware enrollment includes the pinned Microsoft ARM64 factory DBX profile: 26 image hashes, with a separately verified 22-entry signed subset. An isolated firmware test demonstrated hash-based rejection of a benign signed canary; the separate authenticated runtime update was rejected and remains unsupported. [DBX scope, evidence and limits](docs/SECURE_BOOT_DBX.md) distinguish those results. EDK2 currently requires the project path to contain no spaces. Existing VMs keep their own persistent variable stores; these scripts do not replace them.

Optional ARM64 VirtIO drivers and the independently written Guest Tools can be prepared before packaging with `brew install sevenzip` and `python3 scripts/provision-guest-drivers.py`. This verifies a pinned driver-source hash, preserves licenses, and adds the project's explicit Windows installer without unattended Windows setup or system policy changes. If the upstream download changes, review and update the artifact pin explicitly. See [Guest Tools setup and limits](guest-tools/README.md).

The app bundle contains the Rust engine, QEMU executables, private runtime libraries and firmware. Development builds use ad-hoc code signatures, including the hypervisor entitlement. Signing/notarization for a distributed release remains separate work.

For the optional adaptive 2D display and keyboard backpressure runtime, first prepare the normal runtime/firmware above, then build and explicitly select the patched QEMU candidate:

```sh
.tools/build-venv/bin/python experimental/runtime-display/build.py \
  --output .tools/runtime-display/local --jobs 2
PERPENDICULAR_DISPLAY_RUNTIME_MANIFEST=.tools/runtime-display/local/provenance.json \
  ./scripts/build-app.sh
```

The output directory must be fresh. Packaging verifies the candidate, source hashes and signature, and retains its patches and notices; firmware and `qemu-img` still come from the normal runtime. With a VM shut down, select **Configure → Adaptive resolution**. Windows also needs the compatible ARM64 VirtIO display driver and connected Guest Tools; enable **Display → Fit Windows to Window** to adjust its resolution. Existing VMs retain **Standard display** until explicitly changed. This path provides a 2D display, with Windows 3D acceleration still unverified. See [source, reproduction and runtime limits](experimental/runtime-display/README.md).

Choose a Windows 11 **ARM64** installation ISO in the creation wizard. The Windows image and VM data stay outside Git. The Parallels Tools ISO is not a Windows installer and is not a runtime dependency.

## Structure

- `engine/`: Rust configuration, process supervision, QMP control, disk and snapshot operations.
- `macos/PerpendicularDesktop/`: SwiftUI application, native VM library, settings and embedded AppKit/RFB console.
- `macos/Tests/`: independent console protocol verification.
- `scripts/`: pinned runtime build, packaging and firmware provisioning.
- `docs/`: protocol, reconstruction requirements, evidence and verification status.
- `research/private/`: ignored local REA analysis material; never published.

The engine/app contract is documented in [docs/ENGINE_PROTOCOL.md](docs/ENGINE_PROTOCOL.md). Development data can be isolated with `PERPENDICULAR_DATA_DIR`; runtime tool paths can be overridden with `PERPENDICULAR_QEMU`, `PERPENDICULAR_QEMU_IMG`, `PERPENDICULAR_FIRMWARE_DIR` and `PERPENDICULAR_SWTPM`.

## Verification

```sh
./scripts/check.sh
./scripts/build-app.sh
```

Hardware, firmware security, Windows guest behavior and UI integration require actual runtime checks. Their results will be recorded in the feature checklist and verification ledger as those checks are performed.

See [the runtime verification ledger](docs/VERIFICATION.md) for measured results and remaining gaps.

Original source is Apache-2.0. Runtime components retain their own licenses; see [NOTICE](NOTICE).
