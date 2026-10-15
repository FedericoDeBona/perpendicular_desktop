# Native app verification

Run `scripts/check.sh` from the repository root for the normal engine, console and native client checks. These checks do not require a Windows installation.

## GPU presentation

`run-display-presenter-tests.sh [REPORT.json]` exercises the production Metal pipeline on the Mac's actual GPU. It checks BGRA channels, top-row orientation, opaque output despite unused RFB alpha bytes, aspect-fit margins, framebuffer and viewport resizing, sharp integer scaling and linear fractional scaling. A disposable native window is never ordered on screen; its real drawable checks one command buffer in flight, replacement of pending frames, resize without another guest update, and cleanup. A separate check releases a renderer with GPU work in flight and requires that command to finish. No VM, guest input or screen-capture access is used. The normal console suite also injects a presenter failure and requires the real last frame and input focus to survive through Core Graphics fallback.

The report compares the previous Core Graphics image-creation/draw path with Metal upload/encoding on the main thread and separate offscreen GPU completion, with 60 samples after warm-up. It reports median, 95th percentile and samples over 16.67 ms. Results vary with concurrent host/GPU work; they do not measure Windows FPS, RFB transport, visible compositor latency or responsiveness of the guest. Missing Metal support is a failed GPU check, while the application itself falls back to Core Graphics. Set `PERPENDICULAR_DISPLAY_RENDERER=coregraphics` before launching the app to force that fallback during diagnostics.

`PERPENDICULAR_DISPLAY_DIAGNOSTICS=1` logs the first completed Metal frame per display generation, its received framebuffer and drawable dimensions, source `rfb`, and fallback state. A completion belonging to an old generation or a newly allocated frame with no received pixels is excluded. No frame contents, input, socket path or per-frame messages are logged.

## Automatic Windows display sizing

`run-display-sizing-tests.sh [FIXTURE]` uses the real native console and controller, a private Unix-domain RFB peer and real short-lived engine-fixture subprocesses. It never accesses a VM, guest input or clipboard. Thirteen integration fixtures verify:

- Explicit advertising and decoding of ExtendedDesktopSize, a single screen ID, and exact 251 request bytes on the input writer.
- Forwarded status 4 with the old size and status 0 announcements cannot complete a resize. Both measured guest dimensions and pixels received at the new framebuffer dimensions must agree.
- Retina points become physical guest pixels and an advisory DPI hint. Windows scaling is unchanged.
- RFB rejection, missing acknowledgements, size-only metadata without pixels, absent framebuffer confirmation, unsupported guest modes, and an applied flag with mismatched actual dimensions remain failures.
- One in-flight attempt coalesces 100 viewport updates into the final advertised mode, with at least 750 ms between attempts. Host CLI processes are checked for overlap with an exclusive fixture lock.
- Stopping during a held guest command ignores its late success; stale connection/VM events are ignored. Failed or unavailable capabilities do not retry on viewport changes, and replacement backends reset the capability check.
- After an acknowledgement timeout, no new request can reuse an uncorrelated late reply. The connection must drain that reply or reconnect first.

The ordinary UI selects only a driver-advertised mode, exposes “Fit Windows to Window”, and gives human instructions when the channel or driver cannot resize. Raw reasons are confined to optional Display Details. The shared engine worker serializes display operations with lifecycle commands and library polls. Fullscreen uses the same observed content bounds/backing scale as ordinary window resizing. Live Windows driver behavior still needs acceptance in the app; passing fixtures do not imply that RAMFB supports another mode.

## Console keyboard events

`run-console-tests.sh` compiles the real console with a native `NSEvent` harness and checks its exact RFB key sequence over private local sockets. Fifteen modifier regressions cover flags-only Control+C, omitted modifier releases, normal and delayed `flagsChanged`, duplicate events, synthetic-to-physical handoff, all four modifier groups and their left/right sides, Command key equivalents, Option shortcuts/taps, Control punctuation, Right Shift punctuation, and focus loss. The peer rejects premature releases, duplicate key messages and wrong ordering. It never connects to a VM or sends system input.

Native device-side flags identify which physical modifier remains held. Aggregate-only events have no such information: a duplicate cannot be distinguished from releasing one side while the other is held. The console conservatively preserves tracked physical sides until side flags or a cleared group flag establish a release. Caps Lock keeps its separate toggle behavior.

Four application-release fixtures exercise the real `NSApplication.sendEvent` local-monitor stage in an unordered hidden window. They require Command+R's release to reach the focused console, reject another window's release, avoid duplicate releases, and retain the exact text sequence during incoming framebuffer traffic. The local monitor handles only a held key's actual release in this console's own focused window; it does not observe global keyboard events or invent a release. All four fixtures fail against the pre-fix console.

`KeyboardEventFixtures.json` contains only approved known strings captured by the separate native diagnostic: Command+R, `powershell.exe -NoProfile`, Control+Shift+Return, `/ * { } [ ] @ # 5"`, and Command+Q. Timestamps and process identifiers are removed. The two `recorded-keyboard-it` and `recorded-keyboard-en-us` fixtures replay those actual event flags, codes and differing key-down/key-up characters through the console. Their peer independently specifies Windows physical key locations and actual Shift/Right Alt transitions. This catches QEMU's dropped Shift/AltGr map hints and the ambiguous Italian XKB aliases; the Italian fixture fails when only text normalization is disabled. Control and Command shortcuts bypass normalization, and genuine left/right modifier tracking remains intact. Aggregate Option events with code 0 are deferred until a base key distinguishes text from an Alt shortcut; a lone Option tap is retained.

The `rapid-keyboard` fixture instantly enqueues 440 down/up transitions. It verifies every ordered wire event including the final release, and the background writer's minimum 10 ms interval matching QEMU 11.1.2's default VNC key delay. A source-derived model of QEMU's finite delayed-input queue must report no drops. With only pacing disabled, the same burst overflows that model. Ordinary input spaced beyond that interval incurs no added wait; no sleeping occurs on the main thread. This fixture models the identified bottleneck and does not establish that actual Windows input loss is resolved; live acceptance remains necessary.

The input writer reserves at most 1,024 messages and 2 MiB, including its in-flight message and protocol headers. Overflow closes that display connection and reports a human-readable error through its normal failure/reconnection path; it cannot skip a single key, modifier, click or release and keep sending the remaining queue. Two deterministic fixtures hold only their private background writer, independently exceed the message and byte limits, require socket EOF without queued input escaping, reject later input, and verify that all reservations are released within one second after unblocking the worker. Disabling both limits makes these fixtures fail.

`PERPENDICULAR_INPUT_DIAGNOSTICS=1` enables burst summaries on stderr after 250 ms of inactivity. Each `input_diagnostics` JSON object contains only numeric counts/timing: application-stage events from the focused console's local monitor; responder events; accepted/written key transitions; peak queue reservations; maximum wait; and native/wire gaps. It never retains or logs characters, key codes, keysyms, modifier values, clipboard content or VM paths. One bounded timer serves each connection's counters; ordinary operation leaves the instrumentation disabled. The `input-diagnostics` fixture independently checks counts at each stage and rejects every non-metric field or non-numeric value. Its direct key-down calls and application-dispatched key-ups must remain distinguishable. Real acceptance confirmed symbols and Command+R releases, but whole-burst Windows input still lost characters with the 10 ms writer interval; these diagnostics locate that remaining failure rather than imply a timing fix.

For a single console fixture, pass its name to `run-console-tests.sh`, such as `modifiers-missing-control`, `recorded-keyboard-it`, or `rapid-keyboard`. The original eleven modifier scenarios were also verified to fail against their original implementation and pass with the prior correction. These checks verify native event handling and wire messages; actual Windows text and shortcut behavior still require live acceptance.

## Offline disk export

```sh
swiftc -parse-as-library -D PERPENDICULAR_UI_RENDER \
  -target arm64-apple-macosx14.0 -swift-version 6 \
  macos/PerpendicularDesktop/*.swift macos/Tests/DiskExportCheck.swift \
  -o /tmp/perpendicular-export-check
/tmp/perpendicular-export-check
```

The harness uses a real subprocess fixture and a native `NSSavePanel`. It never starts a VM, contacts a guest, or accesses the system clipboard. It checks:

- Export is rejected before invoking the engine unless the current state is exactly stopped, including crashed launches that still need acknowledgement.
- A deliberately held export leaves the main actor responsive while blocking start, clone, and library, host and snapshot polls.
- Both explicit disk formats follow the JSON contract; canonical paths, VM identity, artifact existence and byte counts are verified before reporting success.
- Engine errors and missing or mismatched output clear the busy state and remain failures.
- Existing files remain unchanged, and native destination validation rejects existing files and dangling symbolic links.
- Changing the format updates the visible filename extension between `.qcow2` and `.img`.

This is an independent disk copy. EFI firmware state, TPM state and snapshots are excluded; these limits appear in both the destination panel and export progress sheet.

## Guest Tools boundary and clipboard privacy

```sh
swiftc -parse-as-library -target arm64-apple-macosx14.0 -swift-version 6 \
  macos/PerpendicularDesktop/Engine.swift \
  macos/PerpendicularDesktop/GuestTools.swift \
  macos/Tests/GuestToolsCheck.swift \
  -o /tmp/perpendicular-guest-tools-check
/tmp/perpendicular-guest-tools-check
```

This harness uses an owned temporary CLI fixture and a recording clipboard. It never reads or writes the system clipboard or contacts a VM. It verifies:

- Readiness checks do not read or write clipboard contents.
- Only an explicit successful copy replaces the host clipboard, exactly once.
- Failed or oversized guest reads preserve the previous clipboard.
- Capability checks prevent unsupported clipboard and file operations.
- Clipboard size is measured in UTF-8 bytes, including multi-byte text.
- Explicit host text is passed through a private 0600 temporary file inside a 0700 directory, then removed after success or failure.
- Writes require a positive guest acknowledgement; file transfers require the reported complete byte count.
- Files larger than 1 MiB are rejected before invoking the engine.

The ordinary engine client test also requires `GuestTools.swift` in its compile inputs because `LibraryModel` owns the shared Guest Tools controller.

## Actual fullscreen transitions

`WindowPresentationCheck.swift` tests stale view detach/replacement, native window isolation, observer cleanup and focus safety. A synthetic notification without the native fullscreen style bit must never produce fullscreen UI state.

`FullscreenIntegrationCheck.swift` is an additional GUI-session check. Compile all app sources with `-D PERPENDICULAR_UI_RENDER` and this entry point, then run it inside a temporary macOS `.app` bundle. An unbundled process can be denied native fullscreen by AppKit. The harness shows its own empty library, enters and exits real native fullscreen, checks the actual style bit, and verifies that the native split view collapses and restores its sidebar. It never loads a VM or opens its console.

Set `PERPENDICULAR_WINDOW_DIAGNOSTICS=1` to log only window attachment, style, focus and fullscreen state to stderr.

## Read-only rendering

```sh
swiftc -parse-as-library -target arm64-apple-macosx14.0 -swift-version 6 \
  -D PERPENDICULAR_UI_RENDER \
  macos/PerpendicularDesktop/*.swift macos/Tests/RenderLibrary.swift \
  -o /tmp/perpendicular-render-library
/tmp/perpendicular-render-library /tmp/library.png
```

The renderer caches this application's own native view hierarchy to PNG. Accessibility and Screen Recording permission are unnecessary. `RenderLibrary` and `capture-console.sh` deliberately select the Core Graphics fallback because AppKit bitmap caching excludes Metal drawable contents; use the separate GPU checks for that renderer. The model reads the actual engine library; `PERPENDICULAR_ENGINE` and `PERPENDICULAR_DATA_DIR` can select an isolated installation. Optional views: `--create`, `--import`, `--clone`, `--system`, `--configure`, `--guest-tools`, and `--display-only`. Guest Tools rendering checks status only; it never fetches or sends clipboard contents or files.
