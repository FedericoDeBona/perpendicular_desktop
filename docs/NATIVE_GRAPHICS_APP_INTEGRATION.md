# Native graphics in the normal application launch

The engine and settings now support `virtio-ramfb-gl` as an explicit experimental
3D mode. It launches the bundled `Resources/Native3D/bin/qemu-system-aarch64`
directly, without a shell wrapper or Cocoa window. The existing normal runtime
continues to serve RAMFB/adaptive 2D. The 3D choice is disabled unless both the
native receiver and the complete matching runtime are included in the app.

The native runtime has fixed Wire1/host-v3/DMTX-v2 versions. It includes the
already pinned HID backpressure patch and the reviewed, default-off STP Q PCI
hole handler. The engine enables that narrow handler only for this 3D mode.
The QEMU binary retains only the Hypervisor entitlement; no private HVF API,
driver signature exception, TPM reset or guest security change is introduced.
The matched fork does not expose QEMU 11's optional `ppi` property; its real
TPM and persistent state are retained with its supported syntax.

Native launch uses 4-KiB guest mappings, GPU PCI slot 7, existing disk/EFI/TPM
files, normal QMP identity/lifecycle and the existing private VNC socket for
boot/2D/input. Native display authentication uses the same engine-generated
launch token/PID as the existing receiver. Library/server paths are fixed inside
the bundle; firmware/keymaps come from the preserved normal runtime share.

## Private build

Build the matched QEMU overlay with `--headless --vm-runtime`, qualify it using
`graphics-qemu-probe.py --swift-receiver --headless`, then set:

```sh
PERPENDICULAR_NATIVE_GRAPHICS_PROFILE=<qualified-QEMU-profile> \
PERPENDICULAR_NATIVE_GRAPHICS_QUALIFICATION=<passing-probe-result.json> \
PERPENDICULAR_APP_OUTPUT=<fresh-private-application.app> \
scripts/build-app.sh
```

The build automatically includes the native Swift receiver. Packaging checks
the exact source candidate/qualification/protected inputs, relocates the
renderer, backend, ANGLE and dependency libraries, retains notices and signs
the copies. It refuses an incomplete or unsafe test profile. To preserve an
existing known-good 2D runtime, copy that application to a fresh private output
and use `PERPENDICULAR_BUNDLE_RUNTIME=0` during this build.

`graphics-qemu-probe.py --packaged-runtime <app>/Contents/Resources/Native3D`
also checks the actual relocated binaries and rejects graphics libraries loaded
from `.tools`. It exercises real QEMU/Wire1/native GPU commands with the app's
production Swift receiver/renderer; it executes no guest CPU or disks.

## Verified checkpoint, 2026-10-17

Private candidate: `.build/candidates/native3d3/Perpendicular Desktop.app`.
Strict deep bundle signatures pass. Its engine reports native graphics available,
and its settings show the enabled experimental 3D choice. The relocated runtime
passes 1,015,802 exact pixels, resize/reconnect/held-image checks, zero publisher
maps/backing allocations, zero second-copy operations and retirement of all 46
worker snapshots. Neither startup nor shutdown creates a Cocoa application/window.
Receipt `.tools/graphics-rebuild-qemu-native-20261016/native-app-packaged2/result.json`,
SHA-256 `aaa20ad3d20cba18a873289cde14201ae6f0a1922d22d767386737e5c0fceb2b`.

Clippy, 32 Rust unit tests and 23 CLI tests pass (three existing ignored tests
remain ignored). The Swift engine-client boundary check passes. The carried
input patch passes its real-function sanitizer/socket checks and its causal
control reproduces ten dropped HID transitions when admission is bypassed.
STP decode/address/fault checks pass 4,194,314 cases; these do not prove runtime
HVF fault handling on a running guest.

The same existing Windows VM boots through the private app's normal 2D path.
Guest Tools 0.2.0 connects and reports the Red Hat VirtIO GPU **DOD** controller
at 1920×1200. Its configuration remains adaptive 2D. This confirms that the
candidate app preserves that working path; it does not qualify Windows 3D.
The installed `/Applications` bundle has not been replaced. A suitable signed
3D driver, actual Windows producer admission, visible frame pacing/input latency
and real shutdown/resize/fullscreen acceptance remain required before promotion.
Qualification so far is on this macOS 27 host, not a macOS 14 runtime claim.
