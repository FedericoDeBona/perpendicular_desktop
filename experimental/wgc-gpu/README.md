# Single-window WGC GPU trial

Opt-in source overlay; ordinary source, VM and runtime are read-only inputs.
The paired private worker/frontend/renderer require a separate clone. This is
not a production transport or a new Windows graphics driver. **A bounded runtime
trial now passes:** a Classic Notepad WGC window was presented on the Mac, three
packed-pixel hashes matched, later frames carried no pixel payload/readback in
the worker, and the same window/document accepted input after manual TCP+LZ4
fallback. The earlier failed runs remain in the diary. A cold session with the
final padded layout/cache policy worked; the producer timeout did not recur in
this session and its cause remains unresolved. No guard was relaxed.

A brief identical text activity (97 received/presented frames per mode) measured
WGC selection to Metal callback: GPU median 50.89 ms/p95 139.68 ms, TCP+LZ4
58.29/136.54 ms. Worker CPU was 0.531/0.766 seconds over roughly six seconds of
activity; no general CPU or tail-latency win is established. This is not an
optical input-to-photon measurement, long-session qualification, or a reason to
replace the ordinary path. See the
[project diary](../../docs/VERIFICATION.md#24-ottobre--wgc-gpu-primi-frame-esatti-fallback-e-confronto-breve).

The experiment keeps WGC window selection. It obtains its D3D11 texture, copies
the capture crop on the GPU into one owned shared texture, writes 32 bytes of
identity metadata into a reserved row, and waits for an EVENT query on the same
context. The existing stock UMD/KMD shared-resource export reaches the patched
host renderer. That patch forwards an FD plus bounded layout metadata to a
private Unix datagram socket; it does not transmit pixel data through that
socket. The export shape is deliberately distinctive: width rounded to 64
pixels and height rounded to 64 plus one. Only such BGRA shared layouts are
forwarded. A shape alone is not accepted as frame identity: the receiver also
requires the marker in the resource to match the authenticated frame metadata.

The frame channel carries metadata over its existing authenticated TCP session.
The Mac imports the FD using mmap/MTLBuffer bytesNoCopy, then **blits on the GPU
into a separate immutable GuestFrameSurface**. Only after that blit completes
may the normal TCP receipt allow the guest to reuse its texture. Metal draws
from the owned Mac copy, including later redraws; presentation need not block
source reuse. Descriptor cache: at most 16 recent mappings/128 MiB. An active
blit retains its own source while older cached mappings are evicted.

Only the first three GPU frames for a newly allocated surface also read back a
reference in Windows and compare the SHA256 of packed BGRA rows on the Mac.
Padding and the marker row are excluded. Subsequent frames do not read pixel
payloads back to the guest CPU, but still query GPU completion. Those later
frames are not full-hash proofs. A host source/marker/hash rejection disables
GPU negotiation for that frontend session; the worker retains ordinary TCP+LZ4.
The manual application menu also disables the GPU path. Verify actual frame
recovery before claiming fallback success; control reconnection alone is not
sufficient. The diagnostic path is negotiated only on the separate frame channel.

There are still a guest GPU copy, a Mac GPU copy, metadata/query overhead and
Metal presentation. No claim of complete zero-copy or repaired WGC source
pixels. The current prototype admits one selected window, BGRA8 and bounded
geometry (up to four million logical pixels); window switching, extensive resize,
resource retirement across long sessions and product reliability are not
qualified. The host timing diagnostics only report a slow snapshot fence versus its pollable event and preserve the existing failure behavior. The normal desktop broker guards remain enabled; disabling them was
rejected by the current headless runtime and is not an accepted workaround.

Prepare fresh external outputs with `prepare.py --output …`. It validates the
ordinary source fingerprints in source-inputs.json, applies overlay.patch and
copies the new modules. Compile the guest with the same pinned Cargo/xwin toolchain
as scripts/build-guest.sh. `build-host.py --reference … --output …` requires the
current private Wire2 local-source profile and verifies the ordinary runtime
manifest and matches the reference compiled code to the packaged baseline, recompiles npt_shared.c and the paired diagnostic broker/snapshot units, relinks the matching renderer/server and
packages only those changes in a separate runtime. `build-frontend.py --prepared …
--runtime …` builds/signs a fresh private app using that runtime. It does not boot,
install or replace anything. Runtime verification belongs in the diary.
