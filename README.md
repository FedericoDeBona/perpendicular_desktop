# Perpendicular Desktop

An independent, native macOS desktop virtualization application for **Windows 11 ARM on Apple Silicon**. Written in SwiftUI/AppKit and Rust, with an initial QEMU/HVF backend and an embedded native VM console.

**Active reconstruction, not a finished replacement for Parallels Desktop.** The full feature and verification checklist is tracked in [docs/FEATURES.md](docs/FEATURES.md). UI appearance, a successful build and reaching the Windows installer are milestones, not proof of complete Windows desktop functionality or graphics parity.

## Build

Requires an Apple Silicon Mac with macOS 14+, Apple's Command Line Tools and Homebrew. Provision the Rust toolchain, native dependencies and pinned QEMU runtime:

```sh
./scripts/bootstrap.sh
```

Build the secure ARM firmware from the pinned QEMU/EDK2 source snapshot. It includes the linear framebuffer driver needed by Windows. During development, an installed UTM distribution supplies the separate variable template containing public platform and Microsoft trust certificates:

```sh
brew install aarch64-elf-gcc acpica
PERPENDICULAR_ENROLLED_VARS="/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-secure-vars.fd" ./scripts/build-secure-firmware.sh
./scripts/provision-secure-firmware.sh
./scripts/build-app.sh
open "build/Perpendicular Desktop.app"
```

The provisioning script also accepts an explicit directory containing the code, variables and corresponding `edk2-licenses.txt`. The source archive, compiler flags and separate variable-template provenance are recorded in generated manifests. Supplying and enrolling public certificates without an installed UTM template remains follow-up work. EDK2 currently requires the project path to contain no spaces.

Optional ARM64 VirtIO drivers can be prepared before packaging with `brew install sevenzip` and `python3 scripts/provision-guest-drivers.py`. This verifies a pinned source hash, includes the driver license, and builds a driver-only disc without unattended Windows setup or security-policy changes. If the upstream download changes, review and update the artifact pin explicitly.

The app bundle contains the Rust engine, QEMU executables, private runtime libraries and firmware. Development builds use ad-hoc code signatures, including the hypervisor entitlement. Signing/notarization for a distributed release remains separate work.

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
