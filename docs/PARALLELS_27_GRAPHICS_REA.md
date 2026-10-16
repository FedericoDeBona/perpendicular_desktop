# Installed Parallels 27 graphics: bounded static findings

2026-10-16. Target: installed Parallels Desktop **27.0.3 (58680)**,
`Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app`, a thin ARM64
Mach-O, 13,837,008 bytes. SHA-256:
`79afaead95e143397c0e753ee9a2196fca6226eea74b635f855cb68539d786f3`.
The earlier [26.3 study](PARALLELS_GRAPHICS_REA.md) has different addresses
and hashes and is retained as historical evidence.

The installed executable was neither launched nor modified. Raw slices,
pseudocode, complete REA receipts and selection scripts remain in ignored
`research/private/parallels-current/graphics/`. No proprietary implementation
is included in this document or the product.

## Selection and tool recovery

Apple's existing Command Line Tools decoded Objective-C metadata/stubs and
original assembly. An independent byte scan selected direct ARM64 BL calls to
the relevant selector stubs. The local parser's 31,047 `LC_FUNCTION_STARTS`
entries agree exactly with Apple's LLVM output. Intervals between adjacent
starts were extracted at their original preferred addresses; every extracted
interval was compared byte-for-byte with the unchanged executable afterward.
This identifies bounded intervals, not necessarily complete function bodies
or all indirect/dynamic invocations.

REA 6.5.0 / Ghidra 12.1.4 analyzed nine raw ARM64 intervals at those addresses.
The CLI used its supported `REA_DARWIN_SWIFTC_PATH` and `SDKROOT` variables to
select the existing Command Line Tools for its process-ownership helper,
plus the existing Ghidra and Java 21 installations. This did not accept the
pending Xcode agreement or change persistent MCP configuration. The separate
native `inspect-macho` route still failed through `xcrun`; that failure is
retained rather than presented as a successful REA metadata inspection.

## Findings

Addresses below are preferred, unslid addresses. The byte counts describe the
extracted intervals. API identities come from original selector stubs and
assembly, since raw-target pseudocode does not recover external types.

| Address / bytes | Bounded observation | REA evidence |
| --- | --- | --- |
| `0x1001b1bfc` / 148 | Receives an event and value, calls the encoder-ending helper, then obtains a command buffer and encodes a signal with those arguments. | `ev_28afda67763948e6b35c98f50d9b7a8a8b1c4691af53fda41446131ed28b93ae` |
| `0x1001b1c90` / 148 | Corresponding argument flow into `encodeWaitForEvent:value:` after the same helper calls. | `ev_0df4a1dac05571a3ea133be10f275c410b4cec020079e5ffbddeadbe7af8b980` |
| `0x100244550` / 176 | Ends non-null encoder objects, clears/releases their fields, clears another retained object and updates two state words. Normal return recovered. | `ev_be5aead60f377a7127b66cdacc7a463583372d362db787a4feb12b66e9dffc1f` |
| `0x100244600` / 428 | Conditionally creates a command buffer from an object field and stores it in another field; called by the general signal/wait wrappers and the drawable submission routine. | `ev_aa7f78e6cc6231a54c34e6af4afaefd4c5726565b7c6e099cd249bcf6fec83de` |
| `0x10023a830` / 152 | Calls `newSharedEvent` and stores the returned object at receiver offset `0x40`. Normal return recovered. | `ev_af264043fcf65bb7c6b71fa7af7bc029b270d0eee0c650ce3231243505d02f99` |
| `0x10023a984` / 792 | Configures a blit counter sample, ends encoding, reads `signaledValue` from a field at `0x40`, records value plus one in an output record, encodes that signal and commits. Normal return recovered. | `ev_ec13d2cc84209c980ed5d6388ba0044ddad2977bd6ffa3b62dc30119645cd593` |
| `0x10023ac9c` / 344 | Obtains a command buffer, encodes an event wait using a field at `0x40` and the input record's value, resolves counters through a blit encoder, registers a completion block and commits. Normal return recovered. | `ev_34bf1158e2711e2337ad931570502c64f2e42d37edcd48627dd5b836bca3fffe` |
| `0x1002401f0` / 284 | Builds a texture descriptor and calls `newTextureWithDescriptor:iosurface:plane:` with plane zero and a surface held in an input object. | `ev_91e2fd60be6faaeebd88955e51b2d20c760a7e4b567ac2dc4b9398b8e7b46883` |
| `0x10024346c` / 304 | Sends the supplied drawable to `presentDrawable:`, registers `addScheduledHandler:` and makes a virtual call. Normal return recovered. | `ev_3125802ee048869346cea53570c251eb8ce0cf0341e2d7192e4f66f8c51e674b` |

The original assembly explicitly places event and value in the Objective-C
argument registers for the general wrappers. Their raw decompilations report
PIC/unreachable-block and bad-instruction tail warnings. The original tails
release retained objects through the imported `objc_release` stub. The
command-buffer helper and texture-import decompilations also truncate their
tails; they are not complete recovered implementations. Exception paths and
external control flow remain incomplete in the raw targets.

The counter-resolution routine's block captures its receiver and has invoke
address `0x10023ae28`. Original assembly shows calls to two further helpers;
their semantics are unresolved. Registering this block does not establish
surface release or frame presentation. In particular, the identified
signal/wait pair in this branch concerns **GPU counter collection**. It must
not be reported as the guest framebuffer ownership protocol.

The more general signal/wait wrappers establish explicit command-buffer event
operations outside that counter-specific pair. Their call sites, allocation
ownership and connection to Windows scanout remain untraced. There is no
evidence here for a particular pool size, a cross-process shared-event handle,
or the synchronization of the texture imported from IOSurface.

## Independent implementation implications

This evidence separates encoder boundaries, GPU event ordering, completion
callbacks and drawable scheduling. It does not justify replacing our existing
producer-copy completion requirement or consumer GPU retirement with a
scheduled callback. Our transport's immutable snapshot and ACK lifetime rules
remain necessary until actual producer ownership is proven for our renderer.

Next investigation: trace the general wrappers' callers and event origins,
then connect them to the actual texture writer/reader and release sites. A
runtime trace is needed to establish which branch runs in the user's VM.
There is no Windows performance, latency, buffer-reuse or installed 3D result
from this static analysis.
