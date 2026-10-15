# Runtime verification ledger

Development host: Apple M4, 24 GiB RAM, macOS 27.2. Checks below were performed on 2026-10-15. This is a development record, not a claim of feature parity with Parallels Desktop.

## Native application and engine

- Optimized Swift 6 application built targeting macOS 14. The app bundle was signed ad hoc and passed `codesign --verify --deep --strict`.
- QEMU, qemu-img, swtpm and 23 private runtime libraries were bundled. Inspection found no non-system absolute dylib dependencies. Executables run from the generated bundle, and engine discovery selects its bundled paths.
- Creation through the actual native app selected the supplied ARM64 ISO and created a stopped VM with 4 CPUs, 8 GiB RAM and an 80 GiB sparse disk. The library displayed the result.
- Rust unit/integration tests, native console/client/window tests and lint checks run with `scripts/check.sh`. The initial console cancellation fixture had a handshake/request race; its fix passed ten consecutive complete console runs.
- Independent raw import and stopped clone were checked with real qemu-img: source bytes preserved, no backing-file dependencies, source unchanged, clone still valid after the disposable source was removed.

## Windows runtime

A separate private VM uses 4 CPUs, 8 GiB RAM, a 64 GiB qcow2 disk and the user-supplied Windows ARM64 ISO. Windows PE reports version 10.0.26100.9457. The guest reached the Italian Windows 11 installation language screen.

The successful combination is QEMU/HVF, the upstream EDK2 ArmVirt build with RAMFB, explicit USB-BOT/SCSI CD-ROMs, NVMe, USB input and swtpm. The guest has **not yet completed Windows installation or reached a Windows desktop**.

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

Actual fullscreen testing exposed an observer/state mismatch despite synthetic window tests passing. That behavior is being repaired and requires a fresh native transition check.

## Diagnosed compatibility failures

1. The UTM variable template is QCOW2 despite its `.fd` name. Decoding it to a 64 MiB raw flash bank fixed the flash-size failure. Existing offline malformed templates are repaired with a backup.
2. QEMU 11's TPM PPI creates a sub-page RAM region rejected by HVF on a Mac with 16 KiB pages. `ppi=off` avoids that region while retaining TPM2. This removes firmware-mediated physical-presence operations such as Clear-Tpm. See [the upstream QEMU report](https://gitlab.com/qemu-project/qemu/-/work_items/4587) and [Lima's workaround](https://github.com/lima-vm/lima/pull/5544).
3. VirtIO GPU's firmware GOP uses PixelBltOnly. The observed Windows CD boot path attempted direct framebuffer access and entered its exception loop. Building ArmVirt with the RAMFB driver provides a nonzero linear framebuffer and permits Windows boot. Sources: [RAMFB implementation](https://github.com/tianocore/edk2/blob/master/OvmfPkg/QemuRamfbDxe/QemuRamfb.c), [VirtIO GOP implementation](https://github.com/tianocore/edk2/blob/master/OvmfPkg/VirtioGpuDxe/Gop.c). REA caller analysis evidence: `ev_2569ca74c5f6df16eece2aba9a066e65f88ca21353508878f99fbaee8aa15fa3`. Exact intermediate register/memory observations remain local; this is an observed compatibility diagnosis, not a universal claim about every Windows release.
4. A generic USB storage frontend over a pure block node presented the ISO as a removable RAW disk to Windows PE. Explicit USB-BOT plus `scsi-cd` changed it to optical media and removed the missing-media-driver screen.

## Remaining required work

Complete installation and reach a usable Windows desktop; verify Windows TPM and networking; audio; guest tools and integration channel; clipboard, shared folders/transfers and USB integration; native display resizing and graphics acceleration; actual Windows snapshot recovery; standalone moved-app runtime verification; independent public-certificate enrollment and release packaging. The authoritative feature checklist remains [FEATURES.md](FEATURES.md).
