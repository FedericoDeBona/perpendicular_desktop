# Native app verification

Run `scripts/check.sh` from the repository root for the normal engine, console and native client checks. These checks do not require a Windows installation.

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
