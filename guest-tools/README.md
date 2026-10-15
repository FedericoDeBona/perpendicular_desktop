# Perpendicular Windows Guest Agent

These independent sources add an explicit text clipboard and small file transfer channel between the host app and a logged-in Windows user. They contain no Parallels code or binaries. They use the repository's Apache-2.0 license. This is protocol 1, agent version 0.1.0.

The agent uses Windows PowerShell 5.1 in STA mode, .NET Framework, and the signed ARM64 VirtIO serial driver. It opens only the fixed character device `\\.\Global\org.perpendicular.guest_agent.0`. It opens no TCP listener, launches no requested commands and accepts no destination paths. Windows clipboard operations use `System.Windows.Forms.Clipboard` on the agent's STA thread.

## Install in the Windows desktop

The distribution should put the contents of `windows/` in `GuestTools/` on the driver disc, alongside `Drivers/vioser/w11/ARM64/`. The root build owns the actual disc packaging; the source folder alone does not prove a packaged ISO contains these files.

1. Install the signed `vioser` ARM64 driver from the driver disc if it is not already installed. Driver installation may need Windows administrator permission. The agent itself runs with the logged-in user's limited privileges.
2. Open Windows PowerShell in the Windows desktop as the user whose clipboard and Downloads folder should be used. Replace `D:` below with the actual driver disc letter:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\GuestTools\Install-PerpendicularAgent.ps1"
   ```

3. The installer copies three owned runtime/uninstaller files into `%LOCALAPPDATA%\Perpendicular Desktop\Guest Agent`, registers a user-specific AtLogOn task and starts it immediately. The task uses `Interactive` logon, limited privileges and `powershell.exe -STA`. It does not install a Session 0 service or save a Windows password. The process-only execution-policy option does not change the machine's execution policy.
4. Check the Mac app's Guest Tools connection result. A successful installer message proves task registration, not communication with the VirtIO port. The source has not yet been verified against Windows PowerShell 5.1 or the running Windows guest.

The task is named `Perpendicular Desktop Guest Agent (USER-SID)`. After guest reboot, it runs when this user logs in. If the port is absent or disconnected, the agent closes its current handle, discards incomplete framing and retries after one second. Only one agent can own the exclusive device handle at a time; concurrent Windows user sessions are not a verified feature.

To uninstall for the current user:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Perpendicular Desktop\Guest Agent\Uninstall-PerpendicularAgent.ps1"
```

The uninstaller checks the task's owner identity, exact description/action and package manifest. It removes only that task and known package files. It preserves the VirtIO driver, transferred files and unrelated files in the installation directory.

## Wire protocol

The host exposes an owned private Unix socket through QEMU:

```text
-device virtio-serial-pci,id=guestserial
-chardev socket,id=guestagent,path=PRIVATE_RUNTIME/agent.sock,server=on,wait=off
-device virtserialport,bus=guestserial.0,chardev=guestagent,name=org.perpendicular.guest_agent.0
```

Messages are strict UTF-8 JSON objects followed by LF. The agent also accepts CRLF. Requests are limited to **1,572,864 bytes including LF**; responses to **1,048,576 bytes including LF**. The byte limit is enforced by a buffered stream framer before UTF-8 decoding or JSON conversion. Nesting is limited to 16 levels. No message is executed until a complete line is received. Unknown operations and fields are rejected. A malformed record without a trustworthy request ID resets the device connection without an uncorrelated response.

```json
{"id":7,"op":"status","params":{}}
{"id":7,"ok":true,"result":{"protocol":1,"agent_version":"0.1.0"}}
{"id":7,"ok":false,"error":{"code":"unsupported_operation","message":"This operation is not supported."}}
```

The request `id` must be a non-negative signed 64-bit JSON integer; strings, floats, booleans and null are rejected. The Rust host currently generates IDs within the exact 53-bit integer range. Each response echoes the ID and contains either an object `result`, or an object `error` with string `code` and `message`. There are no unsolicited messages. The host may disconnect and reconnect between requests.

| Operation | Parameters | Successful result |
| --- | --- | --- |
| `status` | `{}` | `protocol`, `agent_version`, `os_build`, `architecture`, `username`, `session_id`, `capabilities`, `secure_boot`, `tpm` |
| `clipboard.read` | `{}` | `{"text":"..."}` |
| `clipboard.write` | `{"text":"..."}` | `{"written":true}` |
| `file.write` | `{"name":"file.txt","content_base64":"..."}` | `{"name":"file.txt","bytes_written":123,"path":"C:\\Users\\...\\Downloads\\file.txt"}` |

`status.capabilities` contains boolean `clipboard` and `file_write`, plus the enforced `max_request_bytes`, `max_response_bytes`, `max_clipboard_bytes` and `max_file_bytes`. `max_line_bytes` and `max_response_line_bytes` are aliases for the framing limits. An architecture such as ARM64 is reported as `arm64`. Secure Boot is a boolean or `"unknown"`; `tpm.present` and `tpm.ready` are each boolean or `"unknown"`. Missing commands and access-denied queries remain unknown. An available API is not evidence that a security feature is enabled.

Clipboard text is limited to **262,144 UTF-8 bytes**. Empty text clears the Windows clipboard. Only text is synchronized; the protocol does not transfer images or clipboard formats. JSON escaping is included in the final response limit, so a clipboard value within the text limit can still return `clipboard_too_large` if its escaped response exceeds 1 MiB. Busy clipboards are retried three times with 50 ms delays.

Files are limited to **1,048,576 decoded bytes**. Standard base64 is accepted without whitespace. Names must be a single Windows basename of at most 128 Unicode scalar values, 512 UTF-8 bytes and 255 UTF-16 code units. Separators, alternate data stream punctuation, controls, trailing dot/space and Windows device names are rejected. The destination comes from the current user's Windows Downloads known-folder ID, not from host parameters. The final Downloads directory must not be a reparse point. A file is staged with `CreateNew` inside that directory and moved to the requested name without replacement. Existing names return `file_exists`; no existing file is overwritten or renamed. No transferred file is executed.

Errors include `invalid_request`, `invalid_parameters`, `unsupported_operation`, `clipboard_unavailable`, `clipboard_busy`, `clipboard_too_large`, `invalid_text`, `invalid_name`, `invalid_content`, `file_too_large`, `file_exists`, `downloads_unavailable` and `file_write_failed`. Clipboard text and file contents are never logged.

## Verification

Run the core checks with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "D:\GuestTools\tests\Test-AgentCore.ps1"
```

`-Clipboard` additionally exercises the actual STA clipboard. This optional check temporarily changes the clipboard and restores its previous text; other clipboard formats are not preserved. The default core checks use temporary files and never open the VirtIO device or register a scheduled task.

A portable PowerShell 7.6.7 build on macOS was downloaded from the official Microsoft release and its published SHA-256 was verified. Core checks and parsing were run there. This is evidence for protocol, framing, validation and file behavior; it does not verify Windows PowerShell 5.1, Windows device opening, task registration, permissions, secure firmware queries or live clipboard integration. Windows end-to-end validation remains required.

## Primary implementation references

- [QEMU `qga/main.c`](https://github.com/qemu/qemu/blob/master/qga/main.c) defines the Windows VirtIO default alias under `\\.\Global\`; this agent uses its own port name.
- [QEMU `qga/channel-win32.c`](https://github.com/qemu/qemu/blob/master/qga/channel-win32.c) opens the named Windows channel for overlapped read/write. This agent independently wraps a Windows handle in a .NET `FileStream`.
- [VirtIO Windows QEMU agent documentation](https://virtio-win.github.io/Knowledge-Base/Qemu-ga-win.html) describes the `virtserialport`/chardev connection.
- [Microsoft scheduled-task principals](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtaskprincipal) documents interactive logon and limited privileges.
- [Microsoft Windows Forms Clipboard](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.clipboard) documents the real clipboard API and its STA requirement.
