# Guest display mode selection

The independent agent 0.2.0 adds primary-display observation and mode selection over the existing private, owned VirtIO serial channel. This does not change VM hardware, firmware or the stable RAM framebuffer. RAMFB commonly exposes one fixed Windows mode; it must remain unsupported until a real display driver offers alternatives. The experimental GPU path has no assumed device ID, driver name or fixed mode list.

## Host contract

`guest-display-status ID` returns one JSON object:

```json
{"display":{"connected":true,"can_resize":false,"reason":"The driver exposes no alternative safe mode","current":{"width":800,"height":600,"dpi":null,"device_name":"\\\\.\\DISPLAY1","adapter":"Guest-reported adapter"},"modes":[{"width":800,"height":600}],"dpi_change_supported":false,"limits":{"min_width":640,"min_height":480,"max_width":3840,"max_height":2160,"max_pixels":8294400,"min_host_dpi":96,"max_host_dpi":288,"min_interval_ms":750}}}
```

`current` is null if Windows cannot measure its primary mode. An unavailable guest channel returns `connected=false`, `can_resize=false`, a real `code`/`reason`, null current and an empty mode list. Ownership mismatches remain errors and prevent any guest IPC. An old guest agent can return `unsupported_operation`; capability or connectivity must not be inferred from a process alone. `status.capabilities.display_channel` advertises the operations, while `display.can_resize` describes this driver's observed alternatives.

`guest-display-resize ID --width 1280 --height 720 --host-dpi 192` sends the guest operation `display.resize` with integer `width`, `height` and `host_dpi` parameters. The result is:

```json
{"display":{"applied":true,"changed":true,"code":"resized","reason":null,"requested":{"width":1280,"height":720,"host_dpi":192},"actual":{"width":1280,"height":720,"dpi":null,"device_name":"\\\\.\\DISPLAY1","adapter":"Guest-reported adapter"},"dpi_changed":false,"retry_after_ms":0}}
```

The engine rejects an acknowledgement claiming success when `actual` does not exactly match the requested physical-pixel dimensions. Unsupported drivers/modes, a failed Windows mode test or an unconfirmed change return `applied=false` with the actual measured mode, which can be null. A request for the already current mode returns `applied=true`, `changed=false`, `code=already_current`; it does not claim a display change. A zero CLI exit status means the request was processed, so clients must inspect `applied`. Invalid parameters, transport failures and ownership errors remain nonzero errors.

The host DPI is only a layout hint. `dpi_changed` and `dpi_change_supported` remain false. Windows DPI/scaling policy is never modified. The optional current `dpi` is system DPI reported only when the calling context is DPI aware; virtualized 96 DPI is reported as unknown instead. It is not a per-monitor scaling control.

## Bounds and coordination

Both sides enforce 640–3840 horizontal pixels, 480–2160 vertical pixels and an 8,294,400 pixel maximum; DPI hints must be integers in 96–288. The host uses 64-bit pixel multiplication before IPC. The guest accepts no adapter name, path, command, refresh-rate request or custom timing. It enumerates at most 32 adapters and 1024 mode records, deduplicating at most 128 safe sizes. Current-mode reporting allows a bounded existing mode outside the request policy without allocating a framebuffer.

The app should choose a fitting mode from the advertised sizes, debounce window resizing for at least **750 ms**, and keep at most one request in flight. The guest uses a monotonic 750 ms interval between actual change attempts. Rapid requests return `display_resize_throttled` and a bounded integer `retry_after_ms`. An already-current no-op does not reconfigure a device. Unsupported outcomes should stop repeated automatic attempts until capabilities or the backend change. Native display calls run synchronously; Win32 provides no cancellation argument for a driver-blocked mode call. The host's existing five-second IPC deadline bounds its wait, not arbitrary kernel-driver execution.

If a separate RFB size request reports that it was forwarded, that acknowledgement is pending. Neither a forwarded request nor this guest operation may be presented as applied until framebuffer/guest actual dimensions establish the change.

## Windows implementation and verification

The agent selects the attached primary display returned by [EnumDisplayDevicesW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaydevicesw). [EnumDisplaySettingsExW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaysettingsexw) supplies current settings and monitor-compatible modes in physical pixels. No raw or rotated-mode override is enabled. Only 32-bpp, non-interlaced, same-orientation modes with the supported DEVMODEW layout and no private trailing data are eligible.

The selected enumerated DEVMODE is restricted to resolution, bit depth, frequency and display flags. It excludes position/primary changes. [ChangeDisplaySettingsExW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changedisplaysettingsexw) first receives `CDS_TEST`; only a successful test proceeds with flags zero for an active dynamic change. No registry update, global change or unsafe-mode flag is used. The agent measures the current mode again, with at most 600 ms of bounded polling, before returning applied success. API error codes stay visible in the reason.

[GetProcessDpiAwareness](https://learn.microsoft.com/en-us/windows/win32/api/shellscalingapi/nf-shellscalingapi-getprocessdpiawareness) and [GetDpiForSystem](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforsystem) only read context/system DPI. They do not alter awareness or scaling. Missing/virtualized readings remain null.

`guest-tools/windows/tests/Test-AgentDisplay.ps1` compiles the actual C# declarations and checks DEVMODEW=220 bytes and DISPLAY_DEVICEW=840 bytes. It runs fixture-only fixed-mode, invalid dimension/DPI, exact-mode, throttle, mismatch and failure checks, with no Windows API, registry, guest port or display mutation. Portable Microsoft PowerShell 7.6.7 passed 31 checks; this does not prove Windows PowerShell 5.1, ARM64 driver behavior, or an end-to-end resolution change. Root must validate those separately before deploying new agent files or activating resize.

Rust tests cover input bounds, unavailable/fixed drivers, duplicate mode rejection, actual-mode acknowledgement, unsupported outcomes and QMP ownership before display IPC. No real Windows VM was modified for these tests.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "D:\GuestTools\tests\Test-AgentDisplay.ps1"
```

The normal default guest-core tests remain separate. No display mutation is part of either fixture suite.
