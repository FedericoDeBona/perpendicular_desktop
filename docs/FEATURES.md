# Reconstruction requirements and evidence

The requested outcome is a functioning independent reconstruction of the Parallels Desktop experience for Windows 11 ARM on Apple Silicon, saved and maintained in this public repository. An application that only launches another VM window, an installer screen, passing unit tests, or an appealing UI is not completion.

## Required product behavior

- [x] Standalone native macOS application, with a bundled working runtime and documented source build.
- [x] Create and configure a Windows 11 ARM VM from a user-supplied ISO.
- [ ] Install and boot Windows to a usable desktop on a private test disk.
- [ ] Embedded interactive display with keyboard, pointer, resize, fullscreen and usable scaling.
- [ ] Accurate start, shutdown, forced stop, pause, resume and crash recovery.
- [ ] CPU/RAM/disk configuration with coherent validation and persistent state.
- [ ] Working disk, NAT networking, input, display, audio and guest drivers.
- [ ] Persistent virtual TPM and verified UEFI/Secure Boot configuration.
- [ ] Snapshots, restore, clone, disk import/export and recovery behavior.
- [ ] Clipboard, shared folders, guest-host transfers and USB device integration.
- [ ] Guest tools installation and an independently implemented host/guest integration channel.
- [ ] Measure and improve graphics/display performance; evaluate accelerated Windows graphics.
- [ ] Document remaining differences in integration and graphics rather than hiding them.
- [ ] Meaningful automated tests plus actual host and Windows runtime verification.
- [ ] Source, third-party notices, build/run documentation and verified public Git push.

The list will be refined against observations of the reference application. Checkboxes require evidence at the scope of the behavior, not a stub or saved configuration field.

## Existing REA findings

Reference: Parallels Desktop 26.3.0, build 57392. Native ARM monitor SHA-256:
`d52bc95d1a86c43f49560e62bc04930fad175127de93a4b1c4156f2d1d39a6a9`.

- `libMonitorArm.dylib` imports Apple Hypervisor VM/vCPU/memory/GIC APIs. Mach-O evidence: `ev_ebce58d3d8ff8c63543b228d13eb3d560cb439b3d08d4e63ac0b0aba88c57132`.
- Monitor entry initializes an internal interface table. Evidence: `ev_9f37e357893491fb1260827653fb94358dee1c93bc9d7026ea7ed75e2e24bd46`.
- An observed function at `0x7b284` invokes `hv_vcpu_run` and dispatches vCPU exits. Evidence: `ev_0f98a6c67fdba0e92ec1fd81ec4977e2369a049c66cb895bcbc4044407170efa`.
- `prl_vm_app` links Hypervisor, Metal and vmnet. Its ARM64 strings indicate TPM, Secure Boot and WDDM/D3D11 subsystems; their complete protocols remain unverified.
- `prl_macvm_app` uses Apple's higher-level Virtualization framework for a distinct macOS guest path.
- The internal ARM Tools ISO contains drivers/agents, not a Windows installation image.

Raw local evidence stays in ignored `research/private/`. Published implementation uses public APIs and independently written code; the repository does not contain Parallels binaries, Windows media, VM disks or copied decompiled functions.

## Implementation choices

- Native SwiftUI/AppKit UI, independent Rust VM management and supervision.
- Bootstrap QEMU/HVF backend with private Unix QMP/VNC sockets.
- Native embedded RFB framebuffer; lifecycle is owned by the engine.
- Standard firmware/devices and independently redistributable guest drivers.
- Keep backend boundaries explicit so the native Rust/HVF investigation can progress without replacing the product objective with a frontend-only deliverable.

## Completion status

Active development. The complete objective is **not achieved**. Runtime evidence and remaining requirements will be recorded here as they are verified.

Verified details and outstanding runtime checks are recorded in [VERIFICATION.md](VERIFICATION.md), including a real Windows PE boot and its `UEFISecureBootEnabled=1` observation. A checked creation/configuration item does not imply that the guest's installation or desktop integration is complete.
