# Runtime verification ledger

Development host: Apple M4, 24 GiB RAM, macOS 27.2. Checks below were performed on 2026-10-15. This is a development record, not a claim of feature parity with Parallels Desktop.

## Native application and engine

- Optimized Swift 6 application built targeting macOS 14. The app bundle was signed ad hoc and passed `codesign --verify --deep --strict`.
- QEMU, qemu-img, swtpm and 23 private runtime libraries were bundled. Inspection found no non-system absolute dylib dependencies. Executables run from the generated bundle, and engine discovery selects its bundled paths.
- The complete bundle was installed under the user's Applications directory and passed deep/strict signature verification there. Its real Windows VM runs with the installed bundled engine and QEMU; all discovered runtime, firmware and driver paths resolve inside that moved app.
- Creation through the actual native app selected the supplied ARM64 ISO and created a stopped VM with 4 CPUs, 8 GiB RAM and an 80 GiB sparse disk. The library displayed the result.
- Rust unit/integration tests, native console/client/window tests and lint checks run with `scripts/check.sh`. The initial console cancellation fixture had a handshake/request race; its fix passed ten consecutive complete console runs.
- Independent raw import and stopped clone were checked with real qemu-img: source bytes preserved, no backing-file dependencies, source unchanged, clone still valid after the disposable source was removed.
- QCOW2/raw export was checked with real qemu-img for bytes, capacity, no backing chains and independence after removing the disposable source. The source was unchanged; existing destinations, dangling symlinks and publication races are refused. Cancellation tests verify that the exact conversion child is reaped and staging is cleaned. The actual native model also exported a stopped, empty private fixture and verified its returned artifact. A separate test app using the real optimized GUI then completed the menu → native save panel → owned test folder → Disk Exported flow; qemu-img independently confirmed the exported disk's contents match the source.

## Windows runtime

A separate private VM uses 4 CPUs, 8 GiB RAM, a 64 GiB qcow2 disk and the user-supplied Windows ARM64 ISO. Windows PE reports version 10.0.26100.9457. The guest reached the Italian Windows 11 installation language screen.

The successful combination is QEMU/HVF, the upstream EDK2 ArmVirt build with RAMFB, explicit USB-BOT/SCSI CD-ROMs, NVMe, USB input and swtpm. Windows 11 Pro completed installation and initial configuration, then reached its Italian desktop. At the network page, the signed NetKVM Windows 11 ARM64 driver was selected from the sanitized driver disc; Windows displayed **Rete — Connessa**. The installed desktop opened Windows PowerShell and executed `whoami` successfully. Optional updates were deferred through the official setup link and still require completion.

The native app's Shut Down action stopped that Windows session normally; all three owned runtime processes exited and `qemu-img check` reported no image errors. While stopped, the disk, EFI code/variables and TPM persistent state were cloned into the app's normal private library. SHA-256 comparisons confirmed exact preservation, including UUID and MAC. The original test copy remains retained. The installed app, launched without a development data-directory override, discovered **Windows 11 Pro** and booted it back to the desktop with the installation ISO ejected. The restart adds the integration serial port and output-only audio, and selects QEMU's Italian keyboard map. Device presence is not yet an end-to-end driver/audio result.

Windows PE's own registry reports:

```text
HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State
UEFISecureBootEnabled    REG_DWORD    0x1
```

This was observed after booting the independently built secure firmware. Its code SHA-256 is `5604f775025d25829fd0313acea2d2aa30ff4e3befc6da2eae1e522efc9ea429`. The compatible enrolled variable template contains active PK, KEK, db and public Microsoft 2011/2023 trust certificates. QMP reports an active emulated TPM TIS device; Windows TPM provisioning/health still needs verification after installation.

![Windows PE Secure Boot observation](images/windows-secure-boot.png)

## Display and input

The actual native `VMConsoleView` received an 800×600 framebuffer. Its raw RGB bytes matched an independent QMP export exactly: **0 differences across 1,440,000 bytes**. The native app displayed the live Windows installer. Guest keyboard input through QMP was used for firmware and Windows PE diagnostics; full native keyboard/layout and pointer behavior still needs an end-to-end Windows desktop check.

An isolated 60-frame, 1920×1080 raw transport benchmark measured a five-run median improvement from 0.612 to 0.505 seconds after contiguous full-width reads. This measures decoder transport, not Windows rendering frame rate or GPU acceleration.

Actual fullscreen testing exposed a race where a retiring SwiftUI accessor could clear its replacement's native window. A causal regression check fails with the old implementation and passes with the repair. The real bundled SwiftUI integration check passed, and the installed app was independently exercised through both native Enter Full Screen and Exit Full Screen transitions: sidebar/controls disappear and return, and AppKit style bits agree with the UI model.

## Independent certificate enrollment

The new offline enrollment path starts with the source-built empty ArmVirt store, creates a local RSA-3072 platform certificate and enrolls it with pinned `virt-firmware 26.10`. The database includes Microsoft Windows Production PCA 2011 and Windows UEFI CA 2023; KEK includes the local public certificate and Microsoft KEK 2011/2023. The private key stays in the ignored build area with mode 0600 and is never packaged. No installed UTM variable template is needed by this path.

An isolated QEMU/HVF firmware VM, separate from the ongoing Windows installation, reported `SecureBoot=01` and `SetupMode=00`. The supplied Windows ISO's signed ARM64 boot loader was accepted and reached its own “Press any key to boot from CD or DVD” prompt. An unsigned ARM64 Shell.efi built from the same EDK2 sources was refused with `Command Error Status: Access Denied`. This checks firmware enforcement, not Windows desktop provisioning or current revocations. That initial template used virt-firmware's placeholder DBX.

A separate negative-control store with SecureBootEnable disabled executed that exact unsigned file and started a second shell, while reporting `SecureBoot=00`. That control was confined to the disposable firmware VM; the Windows installation retained Secure Boot throughout. Both firmware test processes were stopped after capture.

![Independent enrollment rejects unsigned EFI code](images/independent-secure-boot.png)

A subsequent, separately generated factory template contains 26 pinned Microsoft ARM64 image hashes. In disposable firmware VMs, the current Windows loader was accepted; a benign signed EFI canary executed, and the exact same file was rejected after adding only its Authenticode hash to DBX. Host verification of Microsoft's 22-entry signed subset also passed. Firmware rejected the original signed runtime update with `EFI_SECURITY_VIOLATION`, so runtime update/migration remains unverified. The current installed Windows VM and application template have not been changed by these tests. [Exact scope, reproducible tests and remaining limits](SECURE_BOOT_DBX.md).

## Guest integration checks

The Rust guest transport, native explicit clipboard/file controller and independent Windows PowerShell agent pass the normal checks. The native harness uses a recording clipboard and proves that readiness never accesses clipboard contents, failed reads preserve existing text, private clipboard payloads are cleaned up, capabilities gate operations and partial transfers do not count as success. The PowerShell core passed 51 checks in the verified official PowerShell 7.6.7 runtime on macOS, including a full 1 MiB file and strict framing/encoding/path validation. These are **not yet Windows PowerShell 5.1, device, scheduled-task or live clipboard results**.

The display view now ignores unsolicited RFB ServerCutText messages. Only the explicit Guest Tools actions can replace the Mac clipboard with guest text. The console protocol, native drawing/input and explicit Guest Tools controller checks passed again with the full Xcode toolchain; this does not replace live Windows clipboard validation.

The driver disc also includes an explicit Windows GUI installer. It separates the elevated, fixed signed-driver helper from the original desktop user's limited agent installation. Its 25 portable checks pass; the mounted ISO was rebuilt and replaced through QMP without disturbing the Windows disk. Actual Windows Forms, UAC, Windows signature checks, scheduled-task installation and live communication remain required runtime checks.

Saved keyboard layout and output-audio configuration have engine/native tests. A separate paused HVF smoke exposes the output-only HDA controller; actual Windows sound and Italian punctuation still require guest runtime verification.

## Diagnosed compatibility failures

1. The UTM variable template is QCOW2 despite its `.fd` name. Decoding it to a 64 MiB raw flash bank fixed the flash-size failure. Existing offline malformed templates are repaired with a backup.
2. QEMU 11's TPM PPI creates a sub-page RAM region rejected by HVF on a Mac with 16 KiB pages. `ppi=off` avoids that region while retaining TPM2. This removes firmware-mediated physical-presence operations such as Clear-Tpm. See [the upstream QEMU report](https://gitlab.com/qemu-project/qemu/-/work_items/4587) and [Lima's workaround](https://github.com/lima-vm/lima/pull/5544).
3. VirtIO GPU's firmware GOP uses PixelBltOnly. The observed Windows CD boot path attempted direct framebuffer access and entered its exception loop. Building ArmVirt with the RAMFB driver provides a nonzero linear framebuffer and permits Windows boot. Sources: [RAMFB implementation](https://github.com/tianocore/edk2/blob/master/OvmfPkg/QemuRamfbDxe/QemuRamfb.c), [VirtIO GOP implementation](https://github.com/tianocore/edk2/blob/master/OvmfPkg/VirtioGpuDxe/Gop.c). REA caller analysis evidence: `ev_2569ca74c5f6df16eece2aba9a066e65f88ca21353508878f99fbaee8aa15fa3`. Exact intermediate register/memory observations remain local; this is an observed compatibility diagnosis, not a universal claim about every Windows release.
4. A generic USB storage frontend over a pure block node presented the ISO as a removable RAW disk to Windows PE. Explicit USB-BOT plus `scsi-cd` changed it to optical media and removed the missing-media-driver screen.

## Remaining required work

Verify Windows TPM health and desktop networking; finish deferred Windows updates; audio; live guest tools and integration channel; clipboard, shared folders/transfers and USB integration; native display resizing and graphics acceleration; actual Windows snapshot recovery; current DBX revocation provisioning and release packaging. The authoritative feature checklist remains [FEATURES.md](FEATURES.md).
