# Source and license attribution

This checkpoint builds QEMU 11.1.2 from the upstream source archive:

- Source: https://download.qemu.org/qemu-11.1.2.tar.xz
- SHA-256: `731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016`.
- Copyright: Fabrice Bellard, the QEMU team and the individual authors identified in the upstream source files.
- QEMU as a whole is distributed under GNU GPL version 2. Individual source notices remain applicable. The upstream license explanation is retained verbatim in `QEMU-LICENSE`, and the full GPL version 2 text in `COPYING.GPL-2.0`.

The hybrid 2D firmware framebuffer wrapper derives from UTM's QEMU fork:

- Repository: https://github.com/utmapp/qemu.git
- Exact source revision: `88e5ee7ec6703662fec7b638cca74c4769e683d6`.
- Files: `hw/display/virtio-ramfb.c` and `hw/display/virtio-ramfb.h`.
- Those files have no separate license header. The fork's `LICENSE` applies the QEMU rule that source files without specific licensing information are GPL version 2 or, at the recipient's option, any later version.
- The original source hashes and adapted source hashes are recorded in `source-pins.json`. `hybrid-2d.patch` retains the source and makes the QEMU 11 callback/header/setup changes plus a RAMFB setup error check. It adds only the 2D device; no GL, VirGL, Neptune or ANGLE implementation is included.

The HID backpressure changes are adapted from this repository's frozen `experimental/input-backpressure/qemu-10.0.12-backpressure.patch` checkpoint. `hid-backpressure.patch` targets QEMU 11's Linux keycodes and destructible VNC displays, retains upstream notices, and adds a bounded cleanup pool and active-handler identity checks. The older patch remains unchanged. Source components retaining permissive upstream notices remain subject to those notices; the linked QEMU distribution remains GPL version 2 as explained above.

Corresponding source consists of the exact upstream archive plus the two production patches, source pins and the build instructions in this directory. `build.py` reproduces the source assembly and build in a fresh private tree. `qtest-probe.patch` is a separately identified test aid and is excluded from the candidate executable. No firmware binary, Windows driver, TPM state, virtual disk or Parallels code is included by this checkpoint.

The QEMU archive's Slirp subproject is built as a private runtime dependency. Its original copyright/license notice is retained verbatim in `Slirp-COPYRIGHT`; its individual source notices also remain in the exact upstream archive. The private library path/hash is included in build provenance. Existing Homebrew libraries are reused as dependencies and remain subject to their own notices, which the root bundler collects.
