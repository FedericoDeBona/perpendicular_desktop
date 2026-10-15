# Perpendicular Windows Guest Agent

These independent sources add an explicit text clipboard and small file transfer channel between the host app and a logged-in Windows user. They contain no Parallels code or binaries. They use the repository's Apache-2.0 license. This is protocol 1, agent version 0.2.0.

The agent uses Windows PowerShell 5.1 in STA mode, .NET Framework, and the signed ARM64 VirtIO serial driver. It opens only the fixed character device `\\.\Global\org.perpendicular.guest_agent.0`. It opens no TCP listener, launches no requested commands and accepts no destination paths. Windows clipboard operations use `System.Windows.Forms.Clipboard` on the agent's STA thread.

## Install in the Windows desktop

The distribution should put the contents of `windows/` in `GuestTools/` on the driver disc, alongside `Drivers/NetKVM/w11/ARM64/` and `Drivers/vioserial/w11/ARM64/`. The root build owns the actual disc packaging; the source folder alone does not prove a packaged ISO contains these files.

1. In the logged-in Windows desktop, open the driver disc, then `GuestTools`, and double-click **Install-PerpendicularGuestTools.cmd**. Open it normally; do not choose Run as administrator.
2. Choose **Install drivers (administrator)**. Windows requests administrator permission for a separate helper that installs only the fixed NetKVM and vioser Windows 11 ARM64 packages. It verifies both ARM64 images and their catalogs before running Windows PnPUtil, which checks catalog membership and driver policy. An invalid/untrusted signature is an error; the installer does not import certificates, enable test signing, change machine execution policy, or weaken Windows security. It runs from the read-only mounted driver disc, with no driver path or command picker.
3. Read and close the administrator results window. Exit code 3010 is preserved as a restart requirement; the installer does not restart Windows automatically. Windows accepting a package does not prove that its device is active.
4. Choose **Install tools for my account**. This calls the existing agent installer without elevation. The GUI rejects an elevated launch and checks that its current SID matches the logged-in user of its Windows session, so credentials supplied for the driver step cannot change the agent's owner. The agent itself runs with the logged-in user's limited privileges.
5. The agent installer copies the owned agent, display module and uninstaller files into `%LOCALAPPDATA%\Perpendicular Desktop\Guest Agent`, registers a user-specific AtLogOn task and starts it immediately. The task uses `Interactive` logon, limited privileges and `powershell.exe -STA`. It does not install a Session 0 service or save a Windows password. The process-only execution-policy option does not change the machine's execution policy.
6. If requested, restart Windows after both steps. Check the Mac app's Guest Tools connection result. A successful installer message proves task registration, not communication with the VirtIO port. GUI startup and administrator consent have been exercised on Windows PowerShell 5.1; driver completion and the agent connection still require live acceptance.

There is no autorun. Driver errors appear in the administrator results window; the main window offers **View Details** for user-installation errors and the driver's actual exit result. Closing or refusing UAC does not report success. The GUI remains responsive while its separate installation process runs.

PnPUtil result **259** is ambiguous: Microsoft documents both an unmatched device and an already-selected better/newer driver as possible reasons. The installer does not accept 259 by itself or parse localized success text. It independently queries local Windows `Win32_PnPSignedDriver` and `Win32_PnPEntity`: the signed driver must name an `oemN.inf` whose bytes match the disc INF by SHA-256, identify the expected VirtIO PCI device, and associate with the same currently present device, error code zero and the expected `netkvm`/`VirtioSerial` service. `vioser.sys` belongs to the service named `VirtioSerial`; the filename is not the service name. The published INF is read only from Windows' known INF directory. SetupAPI documents that OEM INF copies retain their bytes under an assigned name. Missing APIs, unknown values, missing devices or mismatches remain errors. The complete original PnPUtil output, error output and numeric result stay in the details, along with the independent verification result. A confirmed existing NetKVM installation allows the serial driver step to continue. [Microsoft return values](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-return-values), [OEM INF copies](https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupcopyoeminfw).

## Read-only connection diagnosis

Double-click `GuestTools/Get-PerpendicularGuestToolsDiagnostics.cmd` in the Windows desktop. It runs a fresh STA PowerShell process and pauses with the report visible. It prints only runtime versions/session, the exact owned task's state/result, owned agent process IDs/sessions, VirtIO serial presence/error/service-match flags, and native initialization/port-open results. Command lines and owner identity are compared privately to establish ownership; their contents, user paths, exception messages and clipboard contents are never printed.

Task and process ownership comparisons accept case differences and `/` versus `\` only inside ordinary absolute Windows paths. The program, script, working directory, fixed PowerShell options, principal, limited interactive logon, task name and description still have to match. Relative/device/UNC paths, dot segments, repeated separators, trailing dots or spaces, alternate data streams, extra arguments and different programs are rejected. This is a lexical comparison of the installer layout; it does not expand variables or resolve filesystem aliases. `ScheduledTaskOwned=False` reports a mismatch or unavailable metadata, not proof that the task stopped or the agent crashed.

The diagnostic does not start/stop/register tasks, install drivers, restart Windows, access the clipboard, send guest requests or modify agent files. After confirming the installed package ownership, it extracts only the fixed C# declaration from its native initializer, compiles it without executing agent PowerShell, and checks the bounded reader against three constant bytes in memory. It then briefly tries the exact production exclusive overlapped port open and FileStream constructor, closing immediately without reading or writing protocol bytes. This probe can briefly change the port's open state; it is not a communication test. Win32 errors 2/3 indicate a missing path, 5 access denied, and 32 a possible existing exclusive opener.

`Start-ScheduledTask` is asynchronous, so task registration or result `0x00041301` (running) does not establish that the port opened. Native compilation and STA/Windows Forms initialization happen before the agent retry loop; port/FileStream failures happen inside the loop and retry once per second. The raw-byte reader has a size bound, not an idle timeout; waiting for an incomplete line cannot alone explain a port that was never opened. A healthy PCI controller and the named child port are separate observations. [Microsoft task startup](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/start-scheduledtask), [Microsoft FileStream asynchronous handles](https://learn.microsoft.com/en-us/dotnet/api/system.io.filestream.isasync).

The separately reviewed [per-port access proposal](../docs/GUEST_CHANNEL_ACCESS.md) adds `Set-PerpendicularGuestChannelAccess.ps1` and its C# source to the disc. It defaults to inspection and is never invoked by normal installation. It can propose only one verified desktop SID's read/write access on the uniquely identified Guest Tools PDO, with protected rollback. No Windows execution or ACL change has been performed; actual mapping/descriptor support requires an elevated read-only checkpoint before any user-approved application. There is no elevated agent, SYSTEM service or class-wide permission fallback.

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

## Display observation and optional mode selection

Agent 0.2.0 adds `display.status` and `display.resize` to the existing channel. The capability `display_channel=true` advertises these operations; it does not imply that the current display driver can resize. The stable RAM framebuffer commonly exposes one fixed mode and reports that limit. The agent selects only actual safe modes enumerated by Windows, validates 640–3840 by 480–2160 physical pixels and an 8,294,400 pixel budget, tests a mode before applying it, and checks the measured result. It never changes Windows DPI/scaling, registry display settings, primary monitor, driver policy or security settings. The host DPI is an advisory 96–288 integer hint.

The [exact display protocol and native API references](../docs/GUEST_DISPLAY.md) define status/current/modes and `applied`/`actual` outcomes. A processed request with `applied=false` is unsupported or failed; CLI exit zero alone does not prove resizing. Host UI must debounce at least 750 ms and permit one request at a time. No custom resolution is invented when the driver lacks that mode.

Run `tests/Test-AgentDisplay.ps1` for fixture-only validation and compilation of the actual C# interop. It does not call Windows display APIs or touch the registry, guest channel or live display. Portable PowerShell 7.6.7 passed 31 checks; Windows PowerShell 5.1 and real supported-driver mode changes still require root validation. The new display module is included in the explicit driver-disc, user install and uninstall file lists; these source changes do not update an already installed agent or ISO.

## Verification

Run the core checks with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "D:\GuestTools\tests\Test-AgentCore.ps1"
```

`-Clipboard` additionally exercises the actual STA clipboard. This optional check temporarily changes the clipboard and restores its previous text; other clipboard formats are not preserved. The default core checks use temporary files and never open the VirtIO device or register a scheduled task.

A portable PowerShell 7.6.7 build on macOS was downloaded from the official Microsoft release and its published SHA-256 was verified. Core checks and parsing were run there. This is evidence for protocol, framing, validation and file behavior; it does not verify Windows PowerShell 5.1, Windows device opening, task registration, permissions, secure firmware queries or live clipboard integration. Windows end-to-end validation remains required.

`tests/Test-GuestToolsInstaller.ps1` parses the GUI script and loads only its function definitions for portable fixture checks. Its 54 checks include the two fixed package paths, ARM64 INF/PE checks, rejected unsigned/untrusted catalogs, missing files, result codes including 3010, constrained subprocess arguments and refusal of an elevated GUI. Result 259 is accepted only for a verified existing device fixture; 16 missing, mismatched, unsigned, unhealthy or unavailable-API fixtures remain failures. Serial fixtures require the actual `VirtioSerial` service and reject `vioser`. Integration fixtures verify continuation to serial, preservation of all original output/code on success and failure, and a later serial 3010. The already-installed-259 regression fails against the prior script. Signature, CIM and PnPUtil APIs are mocked; actual INF hash checks use temporary files. No real driver, scheduled task, guest port or clipboard is touched. The NetKVM 259 and serial 0 installer path has now completed in Windows; the corrected serial-service 259 branch still requires live acceptance. Use `-InstallerScript ABS_PATH` to run these checks against a specific source revision without executing its GUI.

`tests/Test-GuestToolsDiagnostics.ps1` checks the installer's Windows task layout, equivalent path separator/case spellings, ambiguous path and altered command rejection, private command-line matching and sanitized errors. It compiles the actual extracted native C# and exercises only the memory reader. It never executes the diagnostic's Windows entry point, opens the guest port or accesses a clipboard. Portable fixtures do not establish that a live Windows task is owned; validate that report separately in the guest.

## Primary implementation references

- [QEMU `qga/main.c`](https://github.com/qemu/qemu/blob/master/qga/main.c) defines the Windows VirtIO default alias under `\\.\Global\`; this agent uses its own port name.
- [QEMU `qga/channel-win32.c`](https://github.com/qemu/qemu/blob/master/qga/channel-win32.c) opens the named Windows channel for overlapped read/write. This agent independently wraps a Windows handle in a .NET `FileStream`.
- [VirtIO Windows QEMU agent documentation](https://virtio-win.github.io/Knowledge-Base/Qemu-ga-win.html) describes the `virtserialport`/chardev connection.
- [Microsoft scheduled-task principals](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtaskprincipal) documents interactive logon and limited privileges.
- [Microsoft Windows Forms Clipboard](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.clipboard) documents the real clipboard API and its STA requirement.
- [Microsoft PnPUtil syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax) documents adding a fixed INF and installing it on matching devices; the installer does not request automatic reboot or force a driver rank.
- [Microsoft Authenticode checks](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature?view=powershell-5.1) documents the catalog signature preflight; final Windows driver acceptance remains separate.
- [Microsoft Windows session information](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsquerysessioninformationw) documents resolving the current Windows session's account before installing its user agent.
- [Microsoft signed-driver properties](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/whqlprov/win32-pnpsigneddriver) documents the installed INF name, signing flag and device ID used by the independent 259 check.
- [Microsoft Plug and Play entity properties](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-pnpentity) documents current presence, service and configuration error code; zero means the device is working properly.
