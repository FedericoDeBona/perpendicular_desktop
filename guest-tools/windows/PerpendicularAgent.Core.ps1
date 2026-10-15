#Requires -Version 5.1
# Independent guest integration protocol. No command execution or host-provided paths.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AgentVersion = '0.2.0'
$script:MaximumRequestBytes = 1572864
$script:MaximumResponseBytes = 1048576
$script:MaximumClipboardBytes = 262144
$script:MaximumFileBytes = 1048576
$script:StrictUTF8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:ClipboardAvailable = $false
. (Join-Path $PSScriptRoot 'PerpendicularAgent.Display.ps1')

function New-AgentError {
    param([string]$Code, [string]$Message)
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['AgentCode'] = $Code
    return $exception
}

function Get-AgentErrorCode {
    param([System.Exception]$Exception)
    while ($null -ne $Exception) {
        if ($Exception.Data.Contains('AgentCode')) { return [string]$Exception.Data['AgentCode'] }
        $Exception = $Exception.InnerException
    }
    return 'operation_failed'
}

function Initialize-AgentNative {
    if ($null -ne ('Perpendicular.Guest.Native' -as [type])) { return }
    # The fixed device name matches QEMU's virtserialport name. SafeFileHandle
    # avoids FileStream's pathname restrictions on Windows character devices.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Perpendicular.Guest {
    public sealed class BoundedLineReader {
        private readonly Stream stream;
        private readonly int maximum;
        private readonly byte[] buffer = new byte[4096];
        private readonly MemoryStream pending = new MemoryStream();
        private int offset;
        private int available;

        public BoundedLineReader(Stream stream, int maximum) {
            this.stream = stream;
            this.maximum = maximum;
        }

        public byte[] ReadLine() {
            while (true) {
                if (offset == available) {
                    available = stream.Read(buffer, 0, buffer.Length);
                    offset = 0;
                    if (available == 0) throw new EndOfStreamException("Host channel disconnected.");
                }
                int newline = Array.IndexOf(buffer, (byte)10, offset, available - offset);
                int count = (newline < 0 ? available : newline) - offset;
                if (pending.Length + count > maximum)
                    throw new InvalidDataException("Request line exceeds its byte limit.");
                pending.Write(buffer, offset, count);
                offset += count;
                if (newline >= 0) {
                    offset++;
                    byte[] line = pending.ToArray();
                    pending.SetLength(0);
                    if (line.Length > 0 && line[line.Length - 1] == 13)
                        Array.Resize(ref line, line.Length - 1);
                    return line;
                }
            }
        }
    }

    public static class Native {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access,
            uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int SHGetKnownFolderPath(ref Guid folder, uint flags,
            IntPtr token, out IntPtr path);

        public static FileStream OpenAgentPort() {
            SafeFileHandle handle = CreateFileW(
                @"\\.\Global\org.perpendicular.guest_agent.0", 0xC0000000u,
                0, IntPtr.Zero, 3, 0x40000000u, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            try { return new FileStream(handle, FileAccess.ReadWrite, 4096, true); }
            catch { handle.Dispose(); throw; }
        }

        public static string DownloadsPath() {
            Guid folder = new Guid("374DE290-123F-4565-9164-39C4925E467B");
            IntPtr value;
            int result = SHGetKnownFolderPath(ref folder, 0, IntPtr.Zero, out value);
            if (result != 0) Marshal.ThrowExceptionForHR(result);
            try { return Marshal.PtrToStringUni(value); }
            finally { Marshal.FreeCoTaskMem(value); }
        }

        public static void ValidateJSONDepth(string text) {
            int depth = 0;
            bool inString = false, escaped = false;
            foreach (char value in text) {
                if (inString) {
                    if (escaped) escaped = false;
                    else if (value == '\\') escaped = true;
                    else if (value == '"') inString = false;
                } else if (value == '"') inString = true;
                else if (value == '{' || value == '[') {
                    if (++depth > 16) throw new InvalidDataException("JSON nesting exceeds 16 levels.");
                } else if (value == '}' || value == ']') depth--;
            }
        }
    }
}
'@
}

function Initialize-AgentClipboard {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw (New-AgentError 'sta_required' 'The guest agent requires PowerShell -STA.')
    }
    Add-Type -AssemblyName System.Windows.Forms
    $script:ClipboardAvailable = $true
}

function Assert-JSONDepth {
    param([string]$Text)
    Initialize-AgentNative
    try { [Perpendicular.Guest.Native]::ValidateJSONDepth($Text) }
    catch { throw (New-AgentError 'invalid_request' 'JSON nesting exceeds 16 levels.') }
}

function Assert-ObjectFields {
    param($Object, [string[]]$Required, [string[]]$Allowed)
    if ($null -eq $Object -or $Object -isnot [System.Management.Automation.PSCustomObject]) {
        throw (New-AgentError 'invalid_request' 'Expected a JSON object.')
    }
    $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($field in $Required) {
        if ($names -cnotcontains $field) { throw (New-AgentError 'invalid_request' "Missing field: $field") }
    }
    foreach ($field in $names) {
        if ($Allowed -cnotcontains $field) { throw (New-AgentError 'invalid_request' 'Unexpected request or parameter field.') }
    }
}

function ConvertFrom-AgentRequest {
    param([byte[]]$Bytes)
    if ($Bytes.Length + 1 -gt $script:MaximumRequestBytes) {
        throw (New-AgentError 'request_too_large' 'Request line exceeds 1.5 MiB.')
    }
    try { $text = $script:StrictUTF8.GetString($Bytes) }
    catch { throw (New-AgentError 'invalid_utf8' 'Request is not valid UTF-8.') }
    Assert-JSONDepth $text
    try { $request = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch { throw (New-AgentError 'invalid_json' 'Request is not valid JSON.') }
    Assert-ObjectFields $request @('id', 'op', 'params') @('id', 'op', 'params')
    if (($request.id -isnot [int] -and $request.id -isnot [long]) -or $request.id -lt 0) {
        throw (New-AgentError 'invalid_request' 'id must be a non-negative signed 64-bit JSON integer.')
    }
    if ($request.op -isnot [string] -or $request.op.Length -gt 64) {
        throw (New-AgentError 'invalid_request' 'op must be a string of at most 64 characters.')
    }
    if ($null -eq $request.params -or $request.params -isnot [System.Management.Automation.PSCustomObject]) {
        throw (New-AgentError 'invalid_request' 'params must be a JSON object.')
    }
    return $request
}

function ConvertTo-AgentResponseBytes {
    param($Response)
    $json = ConvertTo-Json -InputObject $Response -Depth 10 -Compress
    try { $bytes = $script:StrictUTF8.GetBytes($json) }
    catch { throw (New-AgentError 'invalid_text' 'Response contains invalid Unicode.') }
    if ($bytes.Length + 1 -gt $script:MaximumResponseBytes) {
        throw (New-AgentError 'response_too_large' 'Serialized response exceeds 1 MiB.')
    }
    # Unary comma preserves the byte array when returned through the PS pipeline.
    return ,$bytes
}

function Assert-ClipboardText {
    param($Text)
    if ($Text -isnot [string]) { throw (New-AgentError 'invalid_parameters' 'text must be a string.') }
    try { $length = $script:StrictUTF8.GetByteCount($Text) }
    catch { throw (New-AgentError 'invalid_text' 'Clipboard text contains invalid Unicode.') }
    if ($length -gt $script:MaximumClipboardBytes) {
        throw (New-AgentError 'clipboard_too_large' 'Clipboard text exceeds 256 KiB of UTF-8.')
    }
}

function Get-AgentClipboard {
    if (-not $script:ClipboardAvailable) {
        throw (New-AgentError 'clipboard_unavailable' 'Interactive STA clipboard access is unavailable.')
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $text = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText)
            Assert-ClipboardText $text
            return @{ text = $text }
        } catch [System.Runtime.InteropServices.ExternalException] {
            if ($attempt -eq 2) { throw (New-AgentError 'clipboard_busy' 'The guest clipboard is busy.') }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Set-AgentClipboard {
    param([string]$Text)
    Assert-ClipboardText $Text
    if (-not $script:ClipboardAvailable) {
        throw (New-AgentError 'clipboard_unavailable' 'Interactive STA clipboard access is unavailable.')
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            if ($Text.Length -eq 0) { [System.Windows.Forms.Clipboard]::Clear() }
            else { [System.Windows.Forms.Clipboard]::SetText($Text, [System.Windows.Forms.TextDataFormat]::UnicodeText) }
            return @{ written = $true }
        } catch [System.Runtime.InteropServices.ExternalException] {
            if ($attempt -eq 2) { throw (New-AgentError 'clipboard_busy' 'The guest clipboard is busy.') }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Assert-AgentFileName {
    param($Name)
    if ($Name -isnot [string] -or $Name.Length -eq 0 -or $Name.Length -gt 255) {
        throw (New-AgentError 'invalid_name' 'name must be a single nonempty Windows filename.')
    }
    try { $encodedLength = $script:StrictUTF8.GetByteCount($Name) }
    catch { throw (New-AgentError 'invalid_name' 'name contains invalid Unicode.') }
    $scalarCount = 0
    for ($index = 0; $index -lt $Name.Length; $index++) {
        if ([char]::IsHighSurrogate($Name[$index])) { $index++ }
        elseif ([char]::IsControl($Name[$index])) { throw (New-AgentError 'invalid_name' 'Control characters are not allowed in name.') }
        $scalarCount++
    }
    if ($scalarCount -gt 128 -or $encodedLength -gt 512 -or
        $Name -match '[<>:"/\\|?*]' -or $Name -match '[. ]$' -or $Name -eq '.' -or $Name -eq '..') {
        throw (New-AgentError 'invalid_name' 'name must be a single basename of at most 128 Unicode characters.')
    }
    $stem = ($Name -split '\.', 2)[0].TrimEnd(' ')
    if ($stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3]|CONIN\$|CONOUT\$)$') {
        throw (New-AgentError 'invalid_name' 'Reserved Windows device names are not allowed.')
    }
}

function Get-AgentDownloads {
    Initialize-AgentNative
    $root = [System.IO.Path]::GetFullPath([Perpendicular.Guest.Native]::DownloadsPath())
    if (-not [System.IO.Directory]::Exists($root)) { [void][System.IO.Directory]::CreateDirectory($root) }
    if (([System.IO.File]::GetAttributes($root) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-AgentError 'downloads_unavailable' 'The Downloads directory is a reparse point.')
    }
    return $root
}

function Write-AgentFile {
    param($Name, $ContentBase64, [string]$DownloadsRoot)
    Assert-AgentFileName $Name
    if ($ContentBase64 -isnot [string] -or $ContentBase64.Length -gt 1398104 -or
        $ContentBase64.Length % 4 -ne 0 -or $ContentBase64 -cnotmatch '^[A-Za-z0-9+/]*={0,2}$') {
        throw (New-AgentError 'invalid_content' 'content_base64 must contain at most 1 MiB of standard base64 data.')
    }
    try { $content = [System.Convert]::FromBase64String($ContentBase64) }
    catch { throw (New-AgentError 'invalid_content' 'content_base64 is invalid.') }
    if ($content.Length -gt $script:MaximumFileBytes) {
        throw (New-AgentError 'file_too_large' 'Decoded file exceeds 1 MiB.')
    }
    $root = [System.IO.Path]::GetFullPath($DownloadsRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if (-not [System.IO.Directory]::Exists($root) -or
        ([System.IO.File]::GetAttributes($root) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-AgentError 'downloads_unavailable' 'Downloads must be an existing directory without a reparse point.')
    }
    $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $Name))
    if (-not [string]::Equals([System.IO.Path]::GetDirectoryName($target), $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-AgentError 'invalid_name' 'The destination must be directly inside Downloads.')
    }
    if ([System.IO.File]::Exists($target) -or [System.IO.Directory]::Exists($target)) {
        throw (New-AgentError 'file_exists' 'A file or directory with this name already exists in Downloads.')
    }
    $temporary = [System.IO.Path]::Combine($root, '.perpendicular-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($temporary, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($content, 0, $content.Length)
        $stream.Flush()
        $stream.Dispose()
        $stream = $null
        # .NET Framework File.Move fails if the destination appeared meanwhile.
        [System.IO.File]::Move($temporary, $target)
        return @{ name = $Name; bytes_written = $content.Length; path = $target }
    } catch [System.IO.IOException] {
        if ([System.IO.File]::Exists($target) -or [System.IO.Directory]::Exists($target)) {
            throw (New-AgentError 'file_exists' 'A file or directory with this name already exists in Downloads.')
        }
        throw (New-AgentError 'file_write_failed' 'The file could not be saved in Downloads.')
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Get-AgentStatus {
    $build = [System.Environment]::OSVersion.Version.ToString()
    try {
        $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $build = [string]$version.CurrentBuildNumber
        if ($null -ne $version.PSObject.Properties['UBR']) { $build += '.' + [string]$version.UBR }
    } catch { }
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrEmpty($architecture)) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture) {
        'ARM64' { $architecture = 'arm64' }
        'AMD64' { $architecture = 'x86_64' }
        'x86' { $architecture = 'x86' }
        default { $architecture = 'unknown' }
    }
    $secureBoot = 'unknown'
    try { $secureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } catch { }
    $tpm = @{ present = 'unknown'; ready = 'unknown' }
    try {
        $state = Get-Tpm -ErrorAction Stop
        $tpm = @{ present = [bool]$state.TpmPresent; ready = [bool]$state.TpmReady }
    } catch { }
    return @{
        protocol = 1; agent_version = $script:AgentVersion; os_build = $build
        architecture = $architecture; username = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        session_id = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        secure_boot = $secureBoot; tpm = $tpm
        capabilities = @{
            clipboard = $script:ClipboardAvailable; file_write = $true
            display_channel = $true
            max_request_bytes = $script:MaximumRequestBytes; max_response_bytes = $script:MaximumResponseBytes
            max_line_bytes = $script:MaximumRequestBytes; max_response_line_bytes = $script:MaximumResponseBytes
            max_clipboard_bytes = $script:MaximumClipboardBytes; max_file_bytes = $script:MaximumFileBytes
        }
    }
}

function Invoke-AgentRequest {
    param($Request)
    try {
        switch -CaseSensitive ($Request.op) {
            'status' {
                Assert-ObjectFields $Request.params @() @()
                $result = Get-AgentStatus
            }
            'clipboard.read' {
                Assert-ObjectFields $Request.params @() @()
                $result = Get-AgentClipboard
            }
            'display.status' {
                Assert-ObjectFields $Request.params @() @()
                $result = Get-AgentDisplayStatus
            }
            'display.resize' {
                Assert-ObjectFields $Request.params @('width', 'height', 'host_dpi') @('width', 'height', 'host_dpi')
                $result = Set-AgentDisplay $Request.params.width $Request.params.height $Request.params.host_dpi
            }
            'clipboard.write' {
                Assert-ObjectFields $Request.params @('text') @('text')
                Assert-ClipboardText $Request.params.text
                $result = Set-AgentClipboard $Request.params.text
            }
            'file.write' {
                Assert-ObjectFields $Request.params @('name', 'content_base64') @('name', 'content_base64')
                $result = Write-AgentFile $Request.params.name $Request.params.content_base64 (Get-AgentDownloads)
            }
            default { throw (New-AgentError 'unsupported_operation' 'This operation is not supported.') }
        }
        $response = @{ id = $Request.id; ok = $true; result = $result }
        try { return ,(ConvertTo-AgentResponseBytes $response) }
        catch {
            if ($Request.op -eq 'clipboard.read' -and (Get-AgentErrorCode $_.Exception) -eq 'response_too_large') {
                throw (New-AgentError 'clipboard_too_large' 'Escaped clipboard JSON exceeds the 1 MiB response limit.')
            }
            throw
        }
    } catch {
        $code = Get-AgentErrorCode $_.Exception
        $message = if ($code -eq 'operation_failed') { 'The guest operation failed.' } else { $_.Exception.Message }
        return ,(ConvertTo-AgentResponseBytes @{
            id = $Request.id; ok = $false; error = @{ code = $code; message = $message }
        })
    }
}

