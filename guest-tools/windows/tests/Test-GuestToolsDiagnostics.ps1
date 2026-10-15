#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windows = Split-Path $PSScriptRoot -Parent
$path = Join-Path $windows 'Get-PerpendicularGuestToolsDiagnostics.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$script:checks = 0
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
$expected = Get-DiagnosticExpectedTask -Sid 'S-1-5-21-123-456-789-1001' -Account 'PRIVATE-ACCOUNT' -Directory 'C:/Users/PRIVATE-ACCOUNT/AppData/Local/Perpendicular Desktop/Guest Agent' -WindowsDirectory 'C:/Windows'
function New-FixtureTask {
    [pscustomobject]@{
        TaskName = $expected.Name; TaskPath = '\'; Description = $expected.Description
        Principal = [pscustomobject]@{ UserId = $expected.Sid; LogonType = 'Interactive'; RunLevel = 'Limited' }
        Actions = @([pscustomobject]@{ Execute = $expected.Execute; Arguments = $expected.Arguments; WorkingDirectory = $expected.Directory })
    }
}
Assert-True (Test-DiagnosticOwnedTask (New-FixtureTask) $expected) 'The exact owned interactive limited task should match.'
Assert-True ($expected.Directory -ceq 'C:\Users\PRIVATE-ACCOUNT\AppData\Local\Perpendicular Desktop\Guest Agent' -and
    $expected.Execute -ceq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -and
    $expected.Arguments.EndsWith('-File "C:\Users\PRIVATE-ACCOUNT\AppData\Local\Perpendicular Desktop\Guest Agent\PerpendicularAgent.ps1"')) 'Diagnostic expected paths must match the installer Windows layout independently of the fixture host.'
foreach ($case in @('wrong-name', 'wrong-task-path', 'wrong-user', 'wrong-description', 'elevated', 'service', 'wrong-executable', 'wrong-arguments', 'wrong-directory', 'extra-action')) {
    $task = New-FixtureTask
    switch ($case) {
        'wrong-name' { $task.TaskName += ' other' }
        'wrong-task-path' { $task.TaskPath = '\Other\' }
        'wrong-user' { $task.Principal.UserId = 'OTHER-OWNER' }
        'wrong-description' { $task.Description = 'OTHER-TASK' }
        'elevated' { $task.Principal.RunLevel = 'Highest' }
        'service' { $task.Principal.LogonType = 'ServiceAccount' }
        'wrong-executable' { $task.Actions[0].Execute = 'other.exe' }
        'wrong-arguments' { $task.Actions[0].Arguments += ' -Command PRIVATE-CONTENT' }
        'wrong-directory' { $task.Actions[0].WorkingDirectory = '/other' }
        'extra-action' { $task.Actions += $task.Actions[0] }
    }
    Assert-True (-not (Test-DiagnosticOwnedTask $task $expected)) ('Unowned task accepted: ' + $case)
}
$task = New-FixtureTask
$task.Principal.UserId = $expected.Account
Assert-True (Test-DiagnosticOwnedTask $task $expected) 'The installer account principal spelling must match without changing logon or run level.'
foreach ($case in @('execute', 'script', 'directory', 'all')) {
    $task = New-FixtureTask
    if ($case -eq 'execute' -or $case -eq 'all') { $task.Actions[0].Execute = $expected.Execute.Replace('\', '/').ToUpperInvariant() }
    if ($case -eq 'script' -or $case -eq 'all') { $task.Actions[0].Arguments = $expected.Arguments.Replace($expected.Agent, $expected.Agent.Replace('\', '/').ToUpperInvariant()) }
    if ($case -eq 'directory' -or $case -eq 'all') { $task.Actions[0].WorkingDirectory = $expected.Directory.Replace('\', '/').ToUpperInvariant() }
    Assert-True (Test-DiagnosticOwnedTask $task $expected) ('Equivalent Windows separator/case spelling was rejected: ' + $case)
}
$task = New-FixtureTask
$task.Actions[0].Execute = 'c:/WINDOWS\System32/WindowsPowerShell\v1.0/powershell.exe'
Assert-True (Test-DiagnosticOwnedTask $task $expected) 'Mixed ordinary Windows separators should compare as the same absolute path.'
$ambiguousPaths = @(
    'C:Windows\file.ps1', '\Windows\file.ps1', '\\server\share\file.ps1', '\\?\C:\Windows\file.ps1', '\\.\C:\Windows\file.ps1',
    'C:\Windows\\file.ps1', 'C:/Windows//file.ps1', 'C:\Windows\.\file.ps1', 'C:\Windows\..\file.ps1',
    'C:\Windows.\file.ps1', 'C:\Windows \file.ps1', 'C:\Windows\file.ps1.', 'C:\Windows\file.ps1 ',
    'C:\Windows\file.ps1:stream', 'C:\Windows\*.ps1', 'C:\Windows\file?.ps1', 'C:\Windows\"file.ps1',
    '%SystemRoot%\file.ps1', 'C:\NUL\file.ps1', 'C:\Windows\con.txt', 'C:\Windows\COM1.ps1',
    'C:\Windows\CONOUT$', "C:\Windows\file`n.ps1", "C:\Windows\file`t.ps1", 'C:\Windows\'
)
foreach ($bad in $ambiguousPaths) {
    Assert-True ($null -eq (ConvertTo-DiagnosticWindowsPath $bad)) 'An ambiguous or nonordinary Windows path was normalized.'
    Assert-True (-not (Test-DiagnosticWindowsPath $bad $bad)) 'Identical ambiguous paths must not establish ownership.'
    $task = New-FixtureTask; $task.Actions[0].Execute = $bad
    Assert-True (-not (Test-DiagnosticOwnedTask $task $expected)) 'An ambiguous task program was accepted.'
    $task = New-FixtureTask; $task.Actions[0].WorkingDirectory = $bad
    Assert-True (-not (Test-DiagnosticOwnedTask $task $expected)) 'An ambiguous working directory was accepted.'
    $task = New-FixtureTask; $task.Actions[0].Arguments = $expected.Arguments.Replace($expected.Agent, $bad)
    Assert-True (-not (Test-DiagnosticOwnedTask $task $expected)) 'An ambiguous script argument was accepted.'
}
foreach ($bad in @($null, 123, @($expected.Execute, $expected.Execute))) {
    Assert-True ($null -eq (ConvertTo-DiagnosticWindowsPath $bad)) 'Only a single string may identify a Windows path.'
}
$argumentVariants = @(
    ($expected.Arguments + ' -Command PRIVATE-CONTENT'),
    ($expected.Arguments + ' '),
    ($expected.Arguments.Replace(' -File ', ' /File ')),
    ($expected.Arguments.Replace(' -STA ', ' -STA -EncodedCommand PRIVATE-CONTENT ')),
    ($expected.Arguments.Replace('"' + $expected.Agent + '"', $expected.Agent)),
    ($expected.Arguments.Replace($expected.Agent, $expected.Agent + '.other')),
    ($expected.Arguments.Replace($expected.Agent, $expected.Agent + '" "other.ps1')),
    ($expected.Arguments.Replace($expected.Agent, $expected.Agent + '"; PRIVATE-CONTENT #')),
    ($expected.Arguments.Replace($expected.Agent, $expected.Agent + '`')),
    ("`n" + $expected.Arguments)
)
Assert-True ($argumentVariants.Count -eq 10) 'Each altered argument fixture must be tested independently.'
foreach ($bad in $argumentVariants) {
    $task = New-FixtureTask; $task.Actions[0].Arguments = $bad
    Assert-True (-not (Test-DiagnosticOwnedTask $task $expected)) 'An altered command or extra argument was accepted.'
    $process = [pscustomobject]@{ ExecutablePath = $expected.Execute; CommandLine = 'powershell.exe ' + $bad }
    Assert-True (-not (Test-DiagnosticOwnedProcess $process $expected)) 'An altered process command or extra argument was accepted.'
}
foreach ($prefix in @(('"' + $expected.Execute + '"'), $expected.Execute, 'powershell.exe')) {
    $process = [pscustomobject]@{ ExecutablePath = $expected.Execute; CommandLine = $prefix + ' ' + $expected.Arguments }
    Assert-True (Test-DiagnosticOwnedProcess $process $expected) 'The exact owned process command should match without being returned.'
}
$process = [pscustomobject]@{ ExecutablePath = $expected.Execute.Replace('\', '/').ToUpperInvariant(); CommandLine = '"' + $expected.Execute.Replace('\', '/').ToLowerInvariant() + '" ' + $expected.Arguments.Replace($expected.Agent, $expected.Agent.Replace('\', '/').ToUpperInvariant()) }
Assert-True (Test-DiagnosticOwnedProcess $process $expected) 'The actual executable and quoted script paths must tolerate Windows separator and case spelling.'
foreach ($case in @('wrong-image', 'wrong-quoted-program', 'wrong-unquoted-program', 'quoted-basename', 'extra-space', 'extra-arguments', 'path-prefix', 'dot-program', 'duplicate-program-separator', 'unterminated-quote', 'trailing-program-text')) {
    $process = [pscustomobject]@{ ExecutablePath = $expected.Execute; CommandLine = 'powershell.exe ' + $expected.Arguments }
    switch ($case) {
        'wrong-image' { $process.ExecutablePath = 'C:\Other\powershell.exe' }
        'wrong-quoted-program' { $process.CommandLine = '"C:\Other\powershell.exe" ' + $expected.Arguments }
        'wrong-unquoted-program' { $process.CommandLine = 'C:\Other\powershell.exe ' + $expected.Arguments }
        'quoted-basename' { $process.CommandLine = '"powershell.exe" ' + $expected.Arguments }
        'extra-space' { $process.CommandLine = 'powershell.exe  ' + $expected.Arguments }
        'extra-arguments' { $process.CommandLine += ' -Command PRIVATE-CONTENT' }
        'path-prefix' { $process.CommandLine = $expected.Execute + '.other ' + $expected.Arguments }
        'dot-program' { $process.CommandLine = $expected.Execute.Replace('\System32\', '\.\System32\') + ' ' + $expected.Arguments }
        'duplicate-program-separator' { $process.CommandLine = $expected.Execute.Replace('\System32\', '\\System32\') + ' ' + $expected.Arguments }
        'unterminated-quote' { $process.CommandLine = '"' + $expected.Execute + ' ' + $expected.Arguments }
        'trailing-program-text' { $process.CommandLine = '"' + $expected.Execute + '"other ' + $expected.Arguments }
    }
    Assert-True (-not (Test-DiagnosticOwnedProcess $process $expected)) ('An unrelated or ambiguous process command was accepted: ' + $case)
}
$process = [pscustomobject]@{ ExecutablePath = $expected.Execute; CommandLine = 'powershell.exe -Command PRIVATE-CONTENT' }
Assert-True (-not (Test-DiagnosticOwnedProcess $process $expected)) 'Unrelated PowerShell commands must not be reported as the agent.'
$failure = Get-DiagnosticErrorSummary ([InvalidOperationException]::new('PRIVATE-CONTENT C:\Users\PRIVATE-ACCOUNT'))
$encoded = $failure | ConvertTo-Json -Compress
Assert-True (-not $encoded.Contains('PRIVATE')) 'Diagnostic error metadata leaked the exception message.'
Assert-True (@($failure.PSObject.Properties).Count -eq 3) 'Only approved exception type and numeric code metadata should be returned.'
$win32 = Get-DiagnosticErrorSummary ([ComponentModel.Win32Exception]::new(5, 'PRIVATE-CONTENT'))
Assert-True ($win32.Win32Error -eq 5) 'The actual Win32 open error must be retained.'
$printed = Write-DiagnosticFailure -Section 'FixedSection' -Exception ([IO.IOException]::new('PRIVATE-CONTENT'))
Assert-True (-not ($printed | Out-String).Contains('PRIVATE')) 'Printed diagnostics leaked a private error message.'
$source = Get-DiagnosticNativeSource -CorePath (Join-Path $windows 'PerpendicularAgent.Core.ps1')
Assert-True ($source.Contains('OpenAgentPort()') -and $source.Contains('org.perpendicular.guest_agent.0')) 'The exact production native port declaration must be extracted.'
Assert-True (-not $source.Contains('System.Windows.Forms.Clipboard')) 'Native initialization extraction must not include clipboard code.'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('perpendicular-diagnostic-source-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    $coreText = [IO.File]::ReadAllText((Join-Path $windows 'PerpendicularAgent.Core.ps1'))
    [IO.File]::WriteAllText($temporary, $coreText.Replace('org.perpendicular.guest_agent.0', 'other.port.not.allowed'))
    $rejected = $false
    try { [void](Get-DiagnosticNativeSource -CorePath $temporary) } catch { $rejected = $true }
    Assert-True $rejected 'The diagnostic must refuse a changed native port target before compiling or opening it.'
} finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
Add-Type -TypeDefinition $source -ErrorAction Stop
$memory = New-Object IO.MemoryStream(,[byte[]]@(123, 125, 10))
try {
    $reader = New-Object Perpendicular.Guest.BoundedLineReader($memory, 16)
    $line = $reader.ReadLine()
    Assert-True ($line.Length -eq 2 -and $line[0] -eq 123 -and $line[1] -eq 125) 'The production native initializer and bounded reader should work without a port.'
} finally { $memory.Dispose() }
Write-Output ('PASS: ' + $script:checks + ' diagnostic checks; exact task/process ownership, private command comparison, sanitized errors, real native-source compilation and memory-only bounded reader. No Windows APIs, guest port, task, driver or clipboard was accessed.')
