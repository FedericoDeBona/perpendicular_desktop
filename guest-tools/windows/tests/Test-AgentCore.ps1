#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Clipboard)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'PerpendicularAgent.Core.ps1')
Initialize-AgentNative
$script:Checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Checks++
}

function Assert-Error {
    param([scriptblock]$Action, [string]$Code)
    try { & $Action | Out-Null }
    catch {
        if ((Get-AgentErrorCode $_.Exception) -eq $Code) { $script:Checks++; return }
        throw
    }
    throw "Expected error: $Code"
}

function Request {
    param([string]$JSON)
    return ConvertFrom-AgentRequest ($script:StrictUTF8.GetBytes($JSON))
}

$valid = Request '{"id":7,"op":"status","params":{}}'
Assert-True ($valid.id -eq 7 -and $valid.op -ceq 'status') 'Valid request did not round-trip.'
foreach ($json in @(
    '{"id":true,"op":"status","params":{}}', '{"id":"7","op":"status","params":{}}',
    '{"id":7.0,"op":"status","params":{}}', '{"id":-1,"op":"status","params":{}}',
    '{"id":7,"op":"status","params":[]}', '{"id":7,"op":"status","params":null}',
    '{"id":7,"op":"status","params":{},"command":"whoami"}'
)) { Assert-Error { Request $json } 'invalid_request' }
Assert-Error { ConvertFrom-AgentRequest ([byte[]]@(0xc3, 0x28)) } 'invalid_utf8'
Assert-Error { Request '{bad json}' } 'invalid_json'
Assert-Error { Request ('{"id":7,"op":"status","params":' + ('[' * 17) + '0' + (']' * 17) + '}') } 'invalid_request'
Assert-Error { ConvertFrom-AgentRequest (New-Object byte[] ($script:MaximumRequestBytes + 1)) } 'request_too_large'

$lineBytes = $script:StrictUTF8.GetBytes("first`r`nsecond`n")
$memory = New-Object System.IO.MemoryStream(,$lineBytes)
$reader = New-Object Perpendicular.Guest.BoundedLineReader($memory, 6)
Assert-True ($script:StrictUTF8.GetString($reader.ReadLine()) -ceq 'first') 'CRLF framing failed.'
Assert-True ($script:StrictUTF8.GetString($reader.ReadLine()) -ceq 'second') 'Buffered subsequent record was lost.'
$eof = $false
try { $reader.ReadLine() | Out-Null } catch { $eof = $_.Exception.InnerException -is [System.IO.EndOfStreamException] }
Assert-True $eof 'Truncated/closed channel was not rejected.'
$memory.Dispose()
$fragmentedText = ('a' * 4095) + [char]0x00e9
$fragmentedBytes = $script:StrictUTF8.GetBytes($fragmentedText + "`n")
$memory = New-Object System.IO.MemoryStream(,$fragmentedBytes)
$reader = New-Object Perpendicular.Guest.BoundedLineReader($memory, 5000)
Assert-True ($script:StrictUTF8.GetString($reader.ReadLine()) -ceq $fragmentedText) 'UTF-8 scalar split across stream buffers was corrupted.'
$memory.Dispose()
$memory = New-Object System.IO.MemoryStream(,([byte[]]@(1, 2, 3)))
$reader = New-Object Perpendicular.Guest.BoundedLineReader($memory, 6)
$truncated = $false
try { $reader.ReadLine() | Out-Null } catch { $truncated = $_.Exception.InnerException -is [System.IO.EndOfStreamException] }
Assert-True $truncated 'An incomplete record was accepted at EOF.'
$memory.Dispose()
$memory = New-Object System.IO.MemoryStream(,([byte[]]@(1, 2, 3, 4, 5, 6, 7)))
$reader = New-Object Perpendicular.Guest.BoundedLineReader($memory, 6)
$bounded = $false
try { $reader.ReadLine() | Out-Null } catch { $bounded = $_.Exception.InnerException -is [System.IO.InvalidDataException] }
Assert-True $bounded 'Framer accepted an oversized unterminated record.'
$memory.Dispose()

foreach ($name in @('../outside.txt', '..\outside.txt', 'C:\outside', 'file:stream', '.', '..', 'bad.', 'bad ',
                    'CON', 'NUL.txt', 'COM1.log', 'LPT9', 'CONIN$', 'CONOUT$.log', "bad`nname")) {
    Assert-Error { Assert-AgentFileName $name } 'invalid_name'
}
Assert-AgentFileName 'normal file.txt'
Assert-AgentFileName 'dati-italiani.txt'
Assert-ClipboardText ''
Assert-ClipboardText ('a' * $script:MaximumClipboardBytes)
Assert-Error { Assert-ClipboardText ('a' * ($script:MaximumClipboardBytes + 1)) } 'clipboard_too_large'
Assert-Error { Assert-ClipboardText ([string][char]0xd800) } 'invalid_text'
$hugeEscaped = ConvertTo-AgentResponseBytes @{ id = 1; ok = $true; result = @{ text = 'small' } }
Assert-True ($hugeEscaped -is [byte[]]) 'Serialized response was not a byte array.'
Assert-Error { ConvertTo-AgentResponseBytes @{ id = 1; ok = $true; result = @{ text = ([string][char]0) * $script:MaximumClipboardBytes } } } 'response_too_large'
$unsupported = Invoke-AgentRequest (Request '{"id":7,"op":"execute","params":{}}')
$unsupportedObject = ConvertFrom-Json -InputObject ($script:StrictUTF8.GetString($unsupported))
Assert-True ($unsupportedObject.id -eq 7 -and -not $unsupportedObject.ok -and
             $unsupportedObject.error.code -ceq 'unsupported_operation') 'Unknown operation was not rejected.'
$badParameters = Invoke-AgentRequest (Request '{"id":8,"op":"clipboard.write","params":{"text":8}}')
$badParametersObject = ConvertFrom-Json -InputObject ($script:StrictUTF8.GetString($badParameters))
Assert-True (-not $badParametersObject.ok -and $badParametersObject.error.code -ceq 'invalid_parameters') 'Non-string clipboard value was coerced.'
$originalClipboardFunction = (Get-Item Function:Get-AgentClipboard).ScriptBlock
try {
    Set-Item Function:Get-AgentClipboard { return @{ text = ([string][char]0) * $script:MaximumClipboardBytes } }
    $escapedClipboard = Invoke-AgentRequest (Request '{"id":9,"op":"clipboard.read","params":{}}')
    $escapedClipboardObject = ConvertFrom-Json -InputObject ($script:StrictUTF8.GetString($escapedClipboard))
    Assert-True (-not $escapedClipboardObject.ok -and $escapedClipboardObject.error.code -ceq 'clipboard_too_large') 'JSON-escaped clipboard overflow was not converted to clipboard_too_large.'
} finally { Set-Item Function:Get-AgentClipboard $originalClipboardFunction }

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('perpendicular-agent-test-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($temporary)
try {
    $payload = [byte[]]@(0, 1, 2, 3, 254, 255)
    $result = Write-AgentFile 'payload.bin' ([Convert]::ToBase64String($payload)) $temporary
    Assert-True ($result.name -ceq 'payload.bin' -and $result.bytes_written -eq 6) 'File receipt fields are wrong.'
    Assert-True ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($result.path)) -ceq [Convert]::ToBase64String($payload)) 'File bytes changed.'
    Assert-Error { Write-AgentFile 'payload.bin' 'AA==' $temporary } 'file_exists'
    Assert-True ([System.IO.File]::ReadAllBytes($result.path).Length -eq 6) 'Collision overwrote the file.'
    Assert-Error { Write-AgentFile '..\escape.bin' 'AA==' $temporary } 'invalid_name'
    Assert-Error { Write-AgentFile 'bad.bin' 'not-base64' $temporary } 'invalid_content'
    $emptyFile = Write-AgentFile 'empty.bin' '' $temporary
    Assert-True ($emptyFile.bytes_written -eq 0 -and [System.IO.File]::ReadAllBytes($emptyFile.path).Length -eq 0) 'An empty file was not written correctly.'
    $large = New-Object byte[] $script:MaximumFileBytes
    $largeBase64 = [Convert]::ToBase64String($large)
    $largeJSON = ConvertTo-Json -Compress -Depth 4 -InputObject @{ id = 10; op = 'file.write'; params = @{ name = 'maximum.bin'; content_base64 = $largeBase64 } }
    $largeRequest = Request $largeJSON
    Assert-True ($largeRequest.params.content_base64.Length -eq $largeBase64.Length) 'Full 1 MiB base64 request did not fit the framed protocol.'
    $maximumFile = Write-AgentFile 'maximum.bin' $largeRequest.params.content_base64 $temporary
    Assert-True ($maximumFile.bytes_written -eq $script:MaximumFileBytes) 'A full 1 MiB file was not accepted.'
    $tooLarge = New-Object byte[] ($script:MaximumFileBytes + 1)
    Assert-Error { Write-AgentFile 'too-large.bin' ([Convert]::ToBase64String($tooLarge)) $temporary } 'file_too_large'
    Assert-True (@(Get-ChildItem -LiteralPath $temporary -Filter '.perpendicular-*' -Force).Count -eq 0) 'Temporary transfer files leaked.'
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }

if ($Clipboard) {
    Initialize-AgentClipboard
    $original = Get-AgentClipboard
    try {
        Set-AgentClipboard 'Perpendicular clipboard test' | Out-Null
        Assert-True ((Get-AgentClipboard).text -ceq 'Perpendicular clipboard test') 'Real Windows STA clipboard round-trip failed.'
        Set-AgentClipboard '' | Out-Null
        Assert-True ((Get-AgentClipboard).text -ceq '') 'Clearing the clipboard failed.'
    } finally { Set-AgentClipboard $original.text | Out-Null }
}
Write-Output ("Guest agent core checks passed: $script:Checks. Windows device/task/clipboard runtime checks require Windows; clipboard checks run only with -Clipboard.")
