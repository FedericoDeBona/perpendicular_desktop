# Guest Agent local health log

The port-close retry correction below is source-only. The earlier health logger
has been deployed and has produced actual Windows diagnostics. This correction
does not itself change the installed agent, task, Windows device, port ACL,
PowerShell policy or VM. Deployment and actual Windows PowerShell 5.1 acceptance
of the correction remain separate.

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
lines. The four channel categories (open, completed request, reset, close error) each emit
at most once per 60 seconds per process, with omitted events counted in the
next record. Changing error codes cannot bypass that limit. Fatal exit records
bypass channel throttling; startup/final-cleanup records are emitted once per stage
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
`channel_close` records a port disposal exception, separately and without a
message; it does not prove that a new connection succeeded.
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

## Port-close reconnect correction

A later actual Windows diagnostic confirmed an owned task in Ready state with
last result 1 and no owned agent process, a healthy serial controller, and a
successful fixed-port open. That boot's health records show completed Core,
native, clipboard and mutex initialization, then `channel_open`, a nonfatal
`channel_reset` I/O error with HRESULT `8007022A`, a fatal `channel_request`
record with the same HRESULT, and `stopped`. The records have no stack trace;
they distinguish this failure after startup from a missing driver or denied
open, but do not independently identify the exact throwing native call.

The old retry loop called `FileStream.Dispose()` unguarded in its `finally`.
Disposal can itself flush buffered output and throw after a channel error,
escaping the reconnect catch. `Close-AgentPort` now catches only the scope of
that disposal call, emits the bounded `channel_close` diagnostic and allows the
existing one-second retry to proceed. The stale local stream reference is
cleared. Core/native/clipboard admission failures still reach the outer fatal
catch; final mutex release/disposal still propagates failures intentionally.
No timeout, unsafe handle release, privilege, task, driver, ACL or protocol
change is added. A blocked native read or disposal is still not bounded by
this correction.

Run the dedicated fault-injection checks in a fresh PowerShell process:

```sh
.tools/powershell-tests/7.6.7/pwsh -NoProfile -File guest-tools/windows/tests/Test-AgentReconnect.ps1
```

For a Windows package with this test under `GuestTools/tests/` and the updated
agent script in its parent directory:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "D:\GuestTools\tests\Test-AgentReconnect.ps1"
```

The 58 portable checks execute the actual parsed production retry and final
cleanup blocks with inert C# 5-compatible in-memory streams. They inject read,
open and disposal failures, require a second connection and a completed
response, check the close-error classification/redaction/rate limit, and prove
that final mutex cleanup still throws. Restoring only the old unguarded close
inside the same loop reproduces termination before its second connection.
The separate 26-check health-log suite still proves that an actual disposable
child startup failure is recorded and remains fatal; that copy fails before
platform admission or native initialization. Neither suite uses a real guest
port, changes a task, or proves successful autostart after a reboot. The Windows
task and real serial reconnection require a separate acceptance run with the
updated source.


The dedicated58-check fixture has now passed inside actual Windows PowerShell
5.1.26100.9711/.NET4.0.30319.42000. The agent-only update preserved the exact
owned task, supporting sources and driver. In the following boot, the updated
agent started automatically and again encountered `8007022A` during reset and
close. It logged `channel_close` rather than fatal stop, then completed an
actual response and subsequent file-write RPC. This one-boot acceptance is
recorded in the [native display checkpoint](../../docs/NATIVE_3D_DISPLAY_CHECKPOINT.md);
it does not establish unlimited reconnect or shutdown stability.
