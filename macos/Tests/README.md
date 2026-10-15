# Native app verification

Run `scripts/check.sh` from the repository root for the normal engine, console and native client checks. These checks do not require a Windows installation.

## Console modifier events

`run-console-tests.sh` compiles the real console with a native `NSEvent` harness and checks its exact RFB key sequence over private local sockets. Eleven modifier regressions cover flags-only Control+C, omitted modifier releases, normal and delayed `flagsChanged`, duplicate events, synthetic-to-physical handoff, all four modifier groups and their left/right sides, Command key equivalents, and focus loss. The peer rejects premature releases, duplicate key messages and wrong ordering. It never connects to a VM or sends system input.

Native device-side flags identify which physical modifier remains held. Aggregate-only events have no such information: a duplicate cannot be distinguished from releasing one side while the other is held. The console conservatively preserves tracked physical sides until side flags or a cleared group flag establish a release. Caps Lock keeps its separate toggle behavior.

For a single console fixture, compile the harness as in `run-console-tests.sh` and pass an optional fixture name as the third argument to `ConsoleMock.py`, such as `modifiers-missing-control` or `modifiers-all-sides`. All eleven new modifier scenarios were verified to fail against the original implementation before the correction and pass with it. This verifies native event handling and wire messages; actual CUA event delivery and Windows shortcut behavior still require live acceptance.

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

The renderer caches this application's own native view hierarchy to PNG. Accessibility and Screen Recording permission are unnecessary. The model reads the actual engine library; `PERPENDICULAR_ENGINE` and `PERPENDICULAR_DATA_DIR` can select an isolated installation. Optional views: `--create`, `--import`, `--clone`, `--system`, `--configure`, `--guest-tools`, and `--display-only`. Guest Tools rendering checks status only; it never fetches or sends clipboard contents or files.
