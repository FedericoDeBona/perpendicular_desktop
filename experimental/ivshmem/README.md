# IVSHMEM host experiment

This isolated QEMU 10.0.12 device tests the memory/notification path described in
[the evaluation](../../docs/IVSHMEM_EVALUATION.md). It does not replace the ordinary
runtime or the graphics driver. No Windows frame transport is integrated yet.

`ivshmem-host.c` implements a distinct `perp-ivshmem-plain` device with the standard
PCI identity 1af4:1110/revision 1, 256-byte BAR0, no MSI-X BAR1, and shared RAM BAR2.
The optional `host-notify` chardev sends one byte after a write to BAR0+12.
BAR0+8 reads peer ID zero. BAR0+16 reads local extension signature 0x50525001 when
host-notify is configured. Writes to reserved mask/status registers are ignored.
This is a local extension, not a standard IVSHMEM peer/server implementation.

The device deliberately keeps BAR0: the 2021 patch's no-doorbell configuration
removes BAR0, but the examined Windows driver expects its registers even without
interrupts. A separate experimental type avoids silently changing upstream plain
semantics. Migration is disabled. Reset/reconnect frame ownership remains a
transport responsibility and is not implemented by this memory device.

The notifier uses a nonblocking chardev write; backpressure retains a coalesced
pending wake and a writable watch. Opening the connection forces a queue scan.
The host queue remains authoritative; wake bytes do not count frames. The initial
host check covers mapping and a notification only, not saturation/reconnection,
Windows cache coherence, frame ownership, Metal presentation or TCP fallback.

Build with the pinned local October 19 QEMU profile and the current Native3D:

```sh
python3 experimental/ivshmem/build-host.py \
  --tools-root /path/to/retained/.tools \
  --runtime /path/to/current/Native3D \
  --output /private/new/ivshmem-build
python3 experimental/ivshmem/check-host.py \
  --qemu /private/new/ivshmem-build/Native3D/bin/qemu-system-aarch64 \
  --report /private/new/host-check.json
```

The builder verifies the current runtime and 1186 pinned link inputs, reproduces
its two existing monitor overlays, compares unchanged QEMU code against the
current executable, then links one extra device unit. The file-prefix mapping is
specific to the current baseline's embedded `__FILE__` strings; a changed baseline
fails the code comparison. No source reference or installed runtime is changed.
Artifacts and logs must stay outside Git. Existing source/NOTICE licenses remain
in the copied Native3D; the device is GPL-2.0-or-later, derived from QEMU IVSHMEM.

The checker creates a temporary 64 MiB backing file and sockets in `/tmp`, starts
QEMU/HVF paused with no disks, obtains ECAM from QMP rather than assuming its
address, assigns the BARs, checks a pattern each way and receives the MMIO wake.
QMP shuts down this process; temporary resources are removed. It does not execute
CPU instructions in Windows or prove guest publication barriers.

## Windows mapping/publication check

A separate APFS clone of the ordinary VM now passes the minimal Windows path
with the Fedora 2022 ARM64 driver, Secure Boot still enabled and no driver edits
or new signatures. The device initially appeared as `machine.inf`/status OK;
that generic binding did not expose the IVSHMEM interface. The explicit driver
install is required. See the verification diary for hashes and exact evidence.

`guest/MappingProbe.cs` is a small diagnostic invoked through PowerShell Add-Type;
C# avoids installing another guest compiler for this check. Production capture
remains Rust. The probe opens the device interface, requests a noncached user
mapping via the stock IOCTL, reads the Mac challenge and publishes two 4096-byte
patterns with explicit memory barriers followed by the MMIO IOCTL. It verifies
that an attempted publish while the host owns the slot is rejected. The Mac
retains that slot for two seconds, confirms its bytes are unchanged, then
releases it; the guest can subsequently publish sequence 2.

The Mac half is `observe-windows.py`. It creates a **fresh** backing file and
socket outside the repository and must start before QEMU. Configure that same
file with `memory-backend-file,share=on`, use the experimental device and point
`host-notify` to its socket. Do not reset or truncate a live mapping. The check
uses offsets 64 (guest sequence), 72 (host release), 4096 (challenge), and 8192
(response); these are diagnostic offsets, not the final three-slot frame ABI.

After the stock ARM64 package is verified/installed in the isolated VM:

```powershell
Add-Type -Path 'D:\MappingProbe.cs'
[IvshmemMappingProbe]::Run() | ConvertTo-Json
```

The actual qualified run used the same observer logic in a private launch script;
this portable CLI preserves the behavior and adds refusal to overwrite a backing
file. This check establishes the observed guest→host memory/notification and
ownership path. It does not establish long-run reliability, raw WGC presentation,
TCP fallback or a performance advantage. Do not rerun it without a relevant change.

## Raw WGC frame overlay (private clone only)

`prepare-frames.py --output /private/new/frame-build` copies the ordinary Rust
and Swift sources to a fresh external directory and applies a small experiment
there. It does not edit the ordinary sources or install the result. The Rust
`guest/frames.rs` is opt-in with `PERP_IVSHMEM=1`; the private Swift receiver is
`SharedFrames.swift`. Windows capture remains the existing WGC hardware readback.
The ordinary graphics driver and renderer are not rebuilt.

Frame ABI: 64 MiB region, magic 0x49565331 at 0, host enabled flag at 4, nonzero
session epoch at 8. Three slots start at 4096, each with size
`floor((64MiB-4096)/3/4096)*4096`. Each has aligned u32 published/released counters
at 0/4, metadata/pixel lengths at 8/12, JSON metadata at 64 (maximum 16384 bytes),
and raw BGRA pixels at 32768. No shared pointers. Slot payload is bounded; a
full slot drops the newly selected frame without overwriting owned data.
All publication/release reads and writes use full memory barriers. Counter wrap
and invalid metadata are explicit failures, not silent reuse.

The host creates a new backing filename and epoch per frontend/VM session. Start
this prototype only with its VM stopped; attach the matching backing and socket
at VM creation. It is not a general frontend-reattach implementation. Never
truncate an old region while QEMU or a reader still owns it. The receiver copies
the pixels to an owned Metal buffer (or owned Data fallback), then releases the
slot. Metal never reads a slot that the guest can overwrite.

The existing authenticated TCP frame connection still carries its hello and one
receipt byte after each received frame. This deliberately preserves the current
single-outstanding-frame backpressure policy for a comparable experiment. Pixel
payloads and their JSON metadata are read from IVSHMEM after the MMIO wake;
control commands stay on their existing TCP connection. This is not full
zero-copy and does not remove every TCP operation.

On receiver failure or the private `ivshmem_disable` local-control command, the
host disables this region and disconnects the bridge. The existing guest retry
reconnects; the next frame writer sees the disabled session and sends pixels over
TCP. The successful fallback check kept the same window ID, text and input.
Startup worker replacement before the first shared frame does not disable the
experiment. After shared use, a disconnect permanently disables it for that
frontend session; a fresh boot/session is required to repeat IVSHMEM.

A private `frame-mode` file in the clone directory selects `ivshmem`, `raw`, or
`lz4` for the comparison. It is experimental configuration, not a product UI.
The overlay logs received and Metal-presented frame metadata in the clone's
`frame-events.jsonl`. These are diagnostic callback times, not optical latency.
The initial real-frame run established delivery/presentation/input and fallback;
a typo in the external launcher prevented the optional pixel hashes. That run
must not be presented as an exact frame-byte comparison or as a benchmark.
