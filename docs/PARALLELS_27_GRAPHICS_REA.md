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
operations outside that counter-specific pair. The follow-up below traces
their direct callers and one event constructor. Connection to Windows scanout
remains unresolved. There is no evidence here for a particular pool size,
a cross-process shared-event handle, or the synchronization of the texture
imported from IOSurface.

## Direct callers, event origin and retirement follow-up

A fresh scan of every aligned instruction in `__text` included both direct
`BL` calls and `B` tail branches. It found three signal/wait caller intervals:
`0x1001f82a0` (460 bytes), `0x1001f8474` (72 bytes), and `0x1001f84bc`
(76 bytes). The last adjusts the incoming receiver by `-0x88`; it is not
evidence for a third independent synchronization object. No direct B/BL into
the previously selected IOSurface importer or drawable submission entry was
found in that scan. Indirect dispatch is outside this negative result.

Original assembly in all three callers loads the event at receiver offset
`0x90`, increments the 64-bit value at `0x98`, passes both to the signal
wrapper, then reloads them for a tail branch to the wait wrapper. The longer
routine takes this path when its input tag equals 3; the two short entries
first invoke a virtual method with argument 4. Those numeric tags have no
recovered domain names. The virtual transition's effects and actual queue
identity remain unknown: adjacent signal/wait calls do not by themselves
prove a cross-queue handoff or framebuffer reuse barrier.

For the constructor's primary virtual table, slot `+0xa8` contains
`0x1001f7348`; original assembly there forwards the receiver's `0xd8` object
to `0x1001e1e04`. This gives a concrete next target for the transition rather
than assigning semantics from its numeric argument. Other derived tables
and runtime dispatch have not been exhausted.

The constructor-like interval at `0x1001f6fc8` (632 bytes) calls the decoded
`newEvent` selector, stores its result at `0x90`, and initializes `0x98` to
zero. Its stores of two virtual-table addresses are corroborated by original
64-bit pointer entries to the caller methods and an adjusting thunk. This
supports associating the constructor and callers. This event is created with
**`newEvent`, not `newSharedEvent`**; the counter branch above is separate.
No exported event handle or interprocess ownership contract was established.

The submission interval at `0x100244fdc` (600 bytes) registers distinct
scheduled and completed blocks, commits the current command buffer, clears
its field and releases its reference. The scheduled block at `0x10024527c`
(16 bytes) only copies a captured 32-bit value to receiver offset `0x14`.
The completed block at `0x10024528c` (628 bytes) checks sequence continuity
and command-buffer status, records diagnostic state under a mutex, updates a
separate completed value at `0x18`, releases eligible retained objects from a
tagged collection under another mutex, and notifies a condition variable.
It can also invoke a captured callback. The collection's element types,
insertion sites and connection to imported surfaces have not been identified;
these releases must not yet be labeled framebuffer retirement.

| Selected interval | REA evidence |
| --- | --- |
| `0x1001f82a0` | `ev_61525015e753046db790bca77925e12ca2239307839baa992ef19d234b034497` |
| `0x1001f8474` | `ev_e250d4c4c3737f9e5453906462dc4ed5016553d0fe661b03bc66e9d0d63d5ba4` |
| `0x1001f84bc` | `ev_1263e14ff6642ba49020f1abec5a90518dd7d858fe1236aa007dd2ee8fcec3a0` |
| `0x1001f6fc8` | `ev_4b6fa6e8a181c462ba0750a808f6bbac3b7ed1a0fbfdfb4fcb389561cceb6a4c` |
| `0x100244fdc` | `ev_23999f7aa80419ac6f76adca2849f5d52f124bd40cef6bb8205ba059dd28518e` |
| `0x10024527c` | `ev_ca423aab6595d30367e6abc7df2d26ea148dd859b8b32733128868cb3d84f9f8` |
| `0x10024528c` | `ev_2941643e4cee2e0ca17ffc6e71f220ef15c344e745c8e9ea1ff76f5d3eaa90bc` |

All seven slices were compared byte-for-byte with the source executable at
their mapped addresses and their digests verified. The original executable
still matches the identity above. Full receipts and the direct-branch scan
are retained privately. The caller decompilations truncate external tails,
and the submission interval has an incomplete exceptional tail; original
assembly supplies the tail-branch and selector argument observations.
Constructor and callback normal returns were recovered. This remains static
evidence with no new VM execution, graphics benchmark or runtime attribution.

## Independent implementation implications

This evidence separates encoder boundaries, GPU event ordering, completion
callbacks and drawable scheduling. It does not justify replacing our existing
producer-copy completion requirement or consumer GPU retirement with a
scheduled callback. Our transport's immutable snapshot and ACK lifetime rules
remain necessary until actual producer ownership is proven for our renderer.

Next investigation: identify the virtual transition's command-buffer effects
and the completed block's collection insertion sites, then connect the actual
texture writer/reader to those release sites. A runtime trace is needed to
establish which branch runs in the user's VM.
There is no Windows performance, latency, buffer-reuse or installed 3D result
from this static analysis.
