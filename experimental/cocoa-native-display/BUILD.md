# Isolated Cocoa native-display builder

`build.py` prepares or builds a **fresh private binary only**. It never packages,
registers, installs or launches QEMU/an app/VM, changes VM configuration, or
modifies the original source/build graph/object/runtime. Full compilation is an
explicit `--build` operation, to be used only after the publisher and transport
owners have declared their sources ready. Default mode is read-only checking.

```sh
python3 experimental/cocoa-native-display/build.py --check --self-test
# Needs complete publisher.h/.m and native-display-transport/ndt.h/.c:
python3 experimental/cocoa-native-display/build.py --prepare --output "$PWD/.tools/cocoa-native-display-build/review1"
# After the coordinated source freeze; choose another fresh directory:
python3 experimental/cocoa-native-display/build.py --build --output "$PWD/.tools/cocoa-native-display-build/build1"
```

Output parent and every build directory are private, owned, real directories.
Existing output paths, including symlinks, are rejected. Plans, sources,
receipts/logs are mode0600; the resulting signed candidate is mode0700. The
receipt has no claim about live capture, correctness, latency or Windows.
Candidate packaging is a separate root-owned step with a fresh destination.

The exact source gate is UTM QEMU
`88e5ee7ec6703662fec7b638cca74c4769e683d6`, pristine `ui/cocoa.m` SHA-256
`1924b6069e19a2e1b58fa2ccf586fe2188b0910f7e0d70abba202f1535841cf9`, and
existing `build.ninja` SHA-256
`3d7c980892aab9b8f4a26018fc84fd58c0cfd41b7084762e23bc11c810b2bfe4`.
Only a **copy** is patched: include `publisher.h` after the Metal include;
inside the default branch of `drawFrame:` call
`perp_native_display_capture(commandBuffer, drawable.texture);` immediately
after the existing `[blit endEncoding];`, before its original completion
handler. `perp_native_display_reset()` is the first Metal operation in
`cocoa_gl_scanout_disable`, before its previous state changes, invalidating
stale consumer output. Unique function/include/full-boundary anchors and no previous hook are
required. Pure fixtures reject changed/ambiguous/already-patched anchors.

With the explicit process environment `PERP_NATIVE_DISPLAY_DIRECT=1`, an earlier
branch instead calls `perp_native_display_capture_region` with the exact read
texture/origin/size and commits its command buffer, releasing the Cocoa read
only after actual GPU completion. It returns before `nextDrawable`; no
drawable capture or presentation is performed in that branch. The publisher
still makes an immutable GPU snapshot, and the source's producer-fence
qualification is unchanged. Cocoa context/window removal is a separate step.

The copied read structure has one retry flag for its owned deferred bottom
half. A direct-mode admission guard in `cocoa_gl_read_dispatch` preserves dirty
demand while disconnected/full without allocating or dispatching. Transient
failure/GPU-error cleanup schedules that deferred bottom half on QEMU's main
loop, with no immediate redispatch. The normal refresh resumes after capacity
returns. This avoids feeding a full budget into the old completion bottom
half's immediate retry loop; it does not fall back to a drawable. The worker
queue never reads or changes QEMU/Cocoa scanout state. Patch fixtures check the
exact source/crop/commit/completion branch, absence of drawable use there, the
deferred retry/admission hook, changed anchors and full byte-for-byte reversal.

The copied `cocoa_gl_refresh` also polls
`perp_native_display_needs_refresh()` immediately after `cocoa_refresh(dcl)`.
When a native scanout exists, it sets the existing atomic `gl_dirty` flag and
uses the original read-inflight/no-drawable retry path. Only QEMU's existing
main loop accesses the scanout texture and dispatches `drawFrame:`; the
publisher worker never accesses Cocoa/QEMU state. The generation-bound request
survives allocation/GPU failure or a full snapshot budget until a completed
snapshot is successfully queued. No new redraw timer or guest input is added.
The pure patch fixture also rejects a missing/duplicated refresh anchor and
proves removing all hooks restores the entire original source byte for byte.

The standalone Ninja graph copies the pinned C, Objective-C and link rules,
but includes **none** of the original build graph. All old objects/libraries
remain immutable inputs; even Ninja log/dependency files go to the new output.
It compiles three private objects: normal Cocoa with explicit MRC, publisher
with ARC/blocks, independent transport as C17. Original flags/SDK selection and
link order are retained; Metal and Foundation frameworks are added.
No compile-time endpoint, VM identity or runtime environment is injected.

The existing actual trace3 GPU diagnostic object is reused unchanged:
`.tools/graphics-experiment/build/gpu-command-diagnostics-3/virtio-gpu-virgl.c.o`,
SHA-256 `2005f72322153732efd111f8d220f0e63787e96e9bf8d9b7f38e62d5ed330dce`.
Its context-init-gated receipt, patched source and candidate hashes are checked.
Thus this candidate retains that command diagnostic behavior, rather than
silently relinking the original uninstrumented GPU object.

`protected-inputs.json` inventories/hashes the original Cocoa/Ninja files,
trace3 source/object/receipt/candidate, original QEMU binaries, current trace3
app binary, all reused link inputs/archives/explicit libraries and the previous
Cocoa compile's actual header dependencies. It also protects the matched Wire1
renderer/server and old-ABI DXMT backend. Symlink resolution/targets and
contents are rechecked after compilation/signing. New publisher/transport
sources are copied and hashed in the build receipt; after a full build the new
three-object header closure is recorded separately in `compiled-dependencies.json`.
Compiler/Ninja/SDK versions are included. A dry plan must contain
exactly three private compilations and one private link. Ad-hoc signing grants
**only** `com.apple.security.hypervisor`, followed by strict verification and
an exact entitlement readback. No other entitlement or security policy is
added.
