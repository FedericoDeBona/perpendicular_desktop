# Isolated graphics trial: hardware and acceptance gates

Research and paused hardware checks on 2026-10-15. No Windows clone has been
started by these scripts. The main VM and installed application remain separate.

## Repeatable paused preflight

```sh
.tools/build-venv/bin/python scripts/graphics-compatibility.py
```

This script starts three **owned, always paused** QEMU fixtures sequentially:
stable 11.1.2 RAMFB, pinned UTM 10.0.12 RAMFB and UTM 10.0.12 `virtio-ramfb`.
Each uses 128 MiB, one stopped HVF vCPU, no firmware or disk file, a null block
node only to enumerate an NVMe controller, no network backend, a fresh temporary
swtpm TPM2 state, and private Unix QMP/VNC sockets. It never sends `cont` or guest
input. It requires an existing `/opt/homebrew/bin/swtpm` and installs nothing.
Cleanup signals/reaps only the processes it created and removes their state.

All three fixtures pass: QMP reports `prelaunch`, `running:false` and a real
`tpm-tis` emulator backend. Their observed PCI assignments are identical for the
existing devices; appending the hybrid display adds only the final entry:

| Device | Bus / slot / function |
| --- | --- |
| USB XHCI | 0 / 1 / 0 |
| VirtIO network | 0 / 2 / 0 |
| VirtIO RNG | 0 / 3 / 0 |
| NVMe | 0 / 4 / 0 |
| VirtIO serial | 0 / 5 / 0 |
| Intel HDA | 0 / 6 / 0 |
| New hybrid GPU | 0 / 7 / 0 |

Receipt: `.tools/graphics-experiment/provenance/graphics-compatibility.json`.
The check establishes HVF initialization, TPM backend presence and this hardware
ordering. It does **not** verify EFI boot, Secure Boot measurements, persisted
TPM commands, Windows drivers, mode changes or storage compatibility.

## TPM and the PPI difference

Stable QEMU 11.1.2 uses `tpm-tis-device,tpmdev=tpm0,ppi=off`, avoiding the optional
0x400-byte PPI RAM mapping which fails HVF's 16 KiB host-page alignment. The
pinned 10.0.12 fork has **no `ppi` property** on this sysbus device. Its
[`tpm_tis_sysbus.c`](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/hw/tpm/tpm_tis_sysbus.c)
registers the TIS MMIO and TPM backend; it does not construct that PPI RAM
region. Its help output lists IRQ, tpmdev, x-baseaddr and x-size (20480).

Omitting the nonexistent `ppi=off` argument in **this fork only** leaves the
actual TPM enabled. The paused HVF + swtpm fixture succeeds without a PPI patch,
MMIO alignment override, disabled TPM or changed security settings. Do not
blindly apply the same omission to the stable 11.x command. A future guest
trial must still verify Secure Boot and TPM status from Windows; paused QMP
presence is not that verification.

## First visible trial: 2D and real resolution

The private fork's `virtio-ramfb` is the normal VirtIO GPU 2D device wrapped
with a firmware RAMFB fallback. Its
[`virtio-ramfb.c`](https://github.com/utmapp/qemu/blob/88e5ee7ec6703662fec7b638cca74c4769e683d6/hw/display/virtio-ramfb.c)
uses RAMFB until the VirtIO GPU becomes enabled and forwards `ui_info` to the
GPU. This is a suitable *candidate* for the released ARM64 display-only driver
already on the official driver ISO. The DOD has no D3D11 hardware acceleration.

Only after Windows Update has completed, Windows has shut down cleanly and
the source is confirmed stopped may the coordinator create the offline clone.
Use the engine's stopped-only `clone` operation: it converts into an independent
qcow2 with no backing chain and copies matching firmware code, EFI variables
and TPM files. Give the clone new UUID, MAC, runtime paths/sockets and NVMe
serial. Copied TPM cryptographic state is still duplicated until separately
reprovisioned; identity changes can cause activation or BitLocker recovery.
Do not share writable disk/EFI/TPM files or start a second swtpm on existing
state. Confirm independent regular files/inodes and absence of backing chains
before launch. No clone command is executed by these graphics scripts.

Prepare a reviewed experimental launch manifest instead of changing stable
engine defaults. Preserve CPU/HVF, memory, NVMe boot order, USB, network,
firmware code and variables, audio and serial settings. The only initial
hardware/display changes should be:

- Use the **private** QEMU 10.0.12 binary, with its private libraries and data
  prefix; keep `-display none` and the private Unix VNC socket for 2D.
- Remove the standalone `-device ramfb` and append
  `-device virtio-ramfb,id=display0` after NVMe, serial and audio, preserving the
  existing PCI assignments. Verify the actual clone's QMP PCI layout against
  its baseline; the table above is the tested fixture, not a read of the VM.
- Retain the real TPM backend and independent cloned state, omitting only the
  unsupported PPI property as explained above. Retain Secure Boot firmware,
  enrolled keys, TPM, HVCI and normal signature policy.

First boot the clone using RAMFB fallback, record Windows Secure Boot/TPM and
display status, then install only the official ISO's signed
`Drivers/viogpudo/w11/ARM64/viogpudo.inf` package after verifying its catalog on
that guest. Confirm the actual ISO path from its manifest before invoking it.
Do not silently copy the Server 2025 helpers into Windows 11 or enable test mode.
Reboot and require Device Manager without a driver error, a visible native
console, correct colors/orientation, keyboard/pointer and two manually selected
enumerated modes (e.g. 1280×720 and 1920×1080 **if exposed by that driver**).

Then test the implemented guest `display.status`/`display.resize` path and/or
negotiated RFB SetDesktopSize, reporting the **actual** Windows resolution and
rejecting unsupported modes. Host window scaling alone is insufficient.
Bound/debounce requests and test growth/shrinkage, failure, pause/resume and
stop/start. Preserve a stopped baseline copy for recovery. If firmware boot,
trust, TPM or display handoff fails, stop the clone and report the actual error;
do not weaken security or alter the source VM to continue.

## Later 3D trial

Use a further independent offline copy, not the validated 2D baseline itself.
`virtio-ramfb-gl` exposes `blob`, `hostmem`, `neptune`, xres/yres and firmware
RAMFB fallback in the pinned fork. Keep the same appended PCI location. Use
the separately verified signed ARM64X Triton v0.3 package with SHA-256:

```text
af976d1fc6cbd1c8462ba06a45f860ae1638d9a6a007e2bfe95bb9b235251c5d
```

Recheck catalog/kernel signature acceptance and unchanged security inside the
clone before installation. The published signed package is distinct from local
test-signed source builds. Any rejection is a stop condition, not a reason to
enable `testsigning`, disable integrity checks or import a test certificate.
See [the prior package research](../../docs/GRAPHICS.md#signed-guest-package-without-changing-secure-boot).

Initially QEMU's external Cocoa path may test driver load and a known D3D11
hardware scene independently. The integrated headless backend must wait for
the [ordered snapshot bridge](README.md) and actual Neptune RPC/lease tests;
its current upstream handle-only path intentionally rejects frames.
Driver presence, DXGI version, WARP rendering or a smooth 2D desktop do not
establish GPU acceleration. Require a hardware adapter, an exact known scene,
matching Metal GPU work, repeated resize/reboot/teardown, and finally matching
VNC/VMConsoleView pixels. Measure frame pacing/copy overhead only in a later
optimized build and compare actual stable configurations.
