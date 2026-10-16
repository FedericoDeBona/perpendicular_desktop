# Guest Agent local health log

Source-only reliability checkpoint. The installed agent, task, Windows device,
port ACL, PowerShell policy and VM are not changed by this source update.
Deployment and actual Windows PowerShell 5.1 validation remain separate.

The agent writes best-effort UTF-8 JSON lines to the current user's fixed
`%LOCALAPPDATA%\Perpendicular Desktop\Guest Agent\agent-health.log` and rotates
into `agent-health.previous.log`. Each file is capped at 64 KiB: at most 128 KiB
in these two files. Oversized pre-existing diagnostic files are truncated,
never copied without a bound. Windows FileShare.Read protects each
append/rotation; contention or an unavailable/read-only log directory drops
the record without stopping the agent. Existing reparse-point log paths are
refused; this is not a privileged or race-free filesystem security mechanism.

Records contain only schema 1, UTC timestamp, process ID, a fixed stage/event,
a fixed error category, numeric Win32/HRESULT information, and a suppressed
event count. They contain no request/response bodies, clipboard data, file
names/contents, credentials, exception messages, exception Data or command
lines. The three channel categories (open, completed request, reset) each emit
at most once per 60 seconds per process, with omitted events counted in the
next record. Changing error codes cannot bypass that limit. Fatal exit records
bypass channel throttling; startup/cleanup records are emitted once per stage
invocation. File size remains bounded across process restarts.

Startup logs before loading Core/Display and records the failing stage if
dependency loading, native compilation, session admission, STA/Windows Forms
or mutex initialization fails. A malformed agent script itself, failure to
launch PowerShell, unavailable user profile/log directory, process kill or
machine failure can prevent a record. Logging is synchronous, best-effort and
has no hard disk-I/O deadline. Absence of a record is not proof of a healthy
process or a particular startup failure.

`channel_open` means only that the fixed device opened. `channel_request` means
one response was written/flushed, including a protocol-level error response;
it does not log the operation or establish success of a clipboard/file/display
action. `channel_reset` records transport/framing failure without its message.
`stopped` records lifecycle cleanup, not successful communication. The existing
one-second reconnect behavior, singleton, protocol 1 and Core agent version
0.2.0 remain unchanged. No permission, task action, installer list or dependency
is added; the logger lives entirely in the already packaged agent script.

Run the portable checks using the already available host PowerShell:

```sh
.tools/powershell-tests/7.6.7/pwsh -NoProfile -File guest-tools/windows/tests/Test-AgentHealthLog.ps1
```

They exercise real bounded files/rotation, monotonic rate limits, exception
redaction, unavailable paths and a real child startup failure before native or
device calls. The disposable startup copy changes only its log destination.
The sharing test asserts writer exclusion only on Windows; Unix FileShare
behavior differs, so the Mac run exercises that path without claiming exclusion.
These checks do not establish actual Windows task startup, VirtIO access or
Windows PowerShell 5.1 runtime behavior. The new dedicated test/document are
repository development files; the existing explicit ISO staging list does not
automatically include them.
