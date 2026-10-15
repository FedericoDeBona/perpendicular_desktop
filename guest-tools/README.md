# Perpendicular Windows Guest Agent

These independent sources add an explicit text clipboard and small file transfer channel between the host app and a logged-in Windows user. They contain no Parallels code or binaries. They use the repository's Apache-2.0 license. This is protocol 1, agent version 0.1.0.

The agent uses Windows PowerShell 5.1 in STA mode, .NET Framework, and the signed ARM64 VirtIO serial driver. It opens only the fixed character device `\\.\Global\org.perpendicular.guest_agent.0`. It opens no TCP listener, launches no requested commands and accepts no destination paths. Windows clipboard operations use `System.Windows.Forms.Clipboard` on the agent's STA thread.

## Install in the Windows desktop

The distribution should put the contents of `windows/` in `GuestTools/` on the driver disc, alongside `Drivers/NetKVM/w11/ARM64/` and `Drivers/vioserial/w11/ARM64/`. The root build owns the actual disc packaging; the source folder alone does not prove a packaged ISO contains these files.

1. In the logged-in Windows desktop, open the driver disc, then `GuestTools`, and double-click **Install-PerpendicularGuestTools.cmd**. Open it normally; do not choose Run as administrator.
2. Choose **Install drivers (administrator)**. Windows requests administrator permission for a separate helper that installs only the fixed NetKVM and vioser Windows 11 ARM64 packages. It verifies both ARM64 images and their catalogs before running Windows PnPUtil, which checks catalog membership and driver policy. An invalid/untrusted signature is an error; the installer does not import certificates, enable test signing, change machine execution policy, or weaken Windows security. It runs from the read-only mounted driver disc, with no driver path or command picker.
3. Read and close the administrator results window. Exit code 3010 is preserved as a restart requirement; the installer does not restart Windows automatically. Windows accepting a package does not prove that its device is active.
4. Choose **Install tools for my account**. This calls the existing agent installer without elevation. The GUI rejects an elevated launch and checks that its current SID matches the logged-in user of its Windows session, so credentials supplied for the driver step cannot change the agent's owner. The agent itself runs with the logged-in user's limited privileges.
5. The agent installer copies three owned runtime/uninstaller files into `%LOCALAPPDATA%\Perpendicular Desktop\Guest Agent`, registers a user-specific AtLogOn task and starts it immediately. The task uses `Interactive` logon, limited privileges and `powershell.exe -STA`. It does not install a Session 0 service or save a Windows password. The process-only execution-policy option does not change the machine's execution policy.
6. If requested, restart Windows after both steps. Check the Mac app's Guest Tools connection result. A successful installer message proves task registration, not communication with the VirtIO port. The source has not yet been verified against Windows PowerShell 5.1 or the running Windows guest.

There is no autorun. Driver errors appear in the administrator results window; the main window offers **View Details** for user-installation errors and the driver's actual exit result. Closing or refusing UAC does not report success. The GUI remains responsive while its separate installation process runs.

For an agent-only installation after manually installing the signed serial driver, open Windows PowerShell as the desktop user whose clipboard and Downloads folder should be used. Replace `D:` with the actual driver disc letter:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\GuestTools\Install-PerpendicularAgent.ps1"
```

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

`tests/Test-GuestToolsInstaller.ps1` parses the new GUI script and loads only its function definitions for portable fixture checks. It verifies the two fixed package paths, ARM64 INF/PE checks, rejected unsigned/untrusted catalogs, missing files, result codes including 3010, constrained subprocess arguments and refusal of an elevated GUI. The signature API is mocked in these checks; no real driver, scheduled task, guest port or clipboard is touched. Windows Forms rendering, UAC, actual Windows certificate validation, PnPUtil, desktop SID checks and agent installation remain Windows runtime acceptance tests.

## Primary implementation references

- [QEMU `qga/main.c`](https://github.com/qemu/qemu/blob/master/qga/main.c) defines the Windows VirtIO default alias under `\\.\Global\`; this agent uses its own port name.
- [QEMU `qga/channel-win32.c`](https://github.com/qemu/qemu/blob/master/qga/channel-win32.c) opens the named Windows channel for overlapped read/write. This agent independently wraps a Windows handle in a .NET `FileStream`.
- [VirtIO Windows QEMU agent documentation](https://virtio-win.github.io/Knowledge-Base/Qemu-ga-win.html) describes the `virtserialport`/chardev connection.
- [Microsoft scheduled-task principals](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtaskprincipal) documents interactive logon and limited privileges.
- [Microsoft Windows Forms Clipboard](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.clipboard) documents the real clipboard API and its STA requirement.
- [Microsoft PnPUtil syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax) documents adding a fixed INF and installing it on matching devices; the installer does not request automatic reboot or force a driver rank.
- [Microsoft Authenticode checks](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature?view=powershell-5.1) documents the catalog signature preflight; final Windows driver acceptance remains separate.
- [Microsoft Windows session information](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsquerysessioninformationw) documents resolving the current Windows session's account before installing its user agent.
