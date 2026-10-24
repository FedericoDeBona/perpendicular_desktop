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
