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
# All resolver calls in this fixture are injected/private lookups. The real
# NTAccount/SecurityIdentifier translation is never invoked, even on Windows.
$script:principalResolverCalls = 0
function Resolve-DiagnosticPrincipalSid {
    param([string]$PrincipalUserId)
    $script:principalResolverCalls++
    if ($PrincipalUserId -ceq 'S-1-5-21-123-456-789-1001' -or $PrincipalUserId -ceq 'PRIVATE-ACCOUNT') { return 'S-1-5-21-123-456-789-1001' }
    if ($PrincipalUserId -ceq 'OTHER-OWNER') { return 'S-1-5-21-123-456-789-1002' }
    throw [InvalidOperationException]::new('PRIVATE-RESOLVER-FAILURE')
}
$script:checks = 0
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
function Test-FixtureLegacyOwnedTask {
    param($Task, $Expected)
    try {
        return ($Task.TaskName -ceq $Expected.Name -and $Task.TaskPath -ceq '\' -and
            $Task.Description -ceq $Expected.Description -and @($Expected.Sid, $Expected.Account) -contains $Task.Principal.UserId -and
            [string]$Task.Principal.LogonType -eq 'Interactive' -and [string]$Task.Principal.RunLevel -eq 'Limited' -and
            @($Task.Actions).Count -eq 1 -and
            (Test-DiagnosticWindowsPath $Task.Actions[0].Execute $Expected.Execute) -and
            (Test-DiagnosticAgentArguments $Task.Actions[0].Arguments $Expected) -and
            (Test-DiagnosticWindowsPath $Task.Actions[0].WorkingDirectory $Expected.Directory))
    } catch { return $false }
}
Add-Type -TypeDefinition @'
public enum DiagnosticFixtureLogon { None = 0, Password = 1, S4U = 2, Interactive = 3, Group = 4, ServiceAccount = 5, InteractiveOrPassword = 6 }
public enum DiagnosticFixtureRunLevel { Limited = 0, Highest = 1 }
public sealed class DiagnosticFixtureStringWrapper { public string Value; public override string ToString() { return Value; } }
public sealed class DiagnosticFixtureCimLikeAction { public string Execute, Arguments, WorkingDirectory; public override string ToString() { return "PRIVATE-CIM-OBJECT"; } }
'@
$expected = Get-DiagnosticExpectedTask -Sid 'S-1-5-21-123-456-789-1001' -Account 'PRIVATE-ACCOUNT' -Directory 'C:/Users/PRIVATE-ACCOUNT/AppData/Local/Perpendicular Desktop/Guest Agent' -WindowsDirectory 'C:/Windows'
function New-FixtureTask {
    [pscustomobject]@{
        TaskName = $expected.Name; TaskPath = '\'; Description = $expected.Description
        Principal = [pscustomobject]@{ UserId = $expected.Sid; LogonType = 'Interactive'; RunLevel = 'Limited' }
        Actions = @([pscustomobject]@{ Execute = $expected.Execute; Arguments = $expected.Arguments; WorkingDirectory = $expected.Directory })
    }
}
Assert-True (Test-DiagnosticOwnedTask (New-FixtureTask) $expected) 'The exact owned interactive limited task should match.'
$fullReport = Get-DiagnosticTaskOwnershipChecks (New-FixtureTask) $expected
Assert-True ($fullReport.Owned -and @($fullReport.Checks.PSObject.Properties).Count -eq 10 -and @($fullReport.Codes.PSObject.Properties).Count -eq 10) 'Every original task clause must have an independent boolean and code.'
foreach ($property in $fullReport.Checks.PSObject.Properties) { Assert-True ($property.Value -is [bool] -and $property.Value) 'Task clause results must be fixed booleans.' }
$reportText = ConvertTo-DiagnosticTaskOwnershipReport $fullReport
Assert-True (-not $reportText.Contains('PRIVATE') -and -not $reportText.Contains($expected.Sid) -and -not $reportText.Contains($expected.Arguments) -and -not $reportText.Contains($expected.Directory)) 'Structured ownership report leaked a source value.'
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
    $clause = @{ 'wrong-name' = 'Name'; 'wrong-task-path' = 'Path'; 'wrong-user' = 'UserId'; 'wrong-description' = 'Description'; elevated = 'RunLevel'; service = 'LogonType'; 'wrong-executable' = 'Execute'; 'wrong-arguments' = 'Arguments'; 'wrong-directory' = 'WorkingDirectory'; 'extra-action' = 'Actions' }[$case]
    $report = Get-DiagnosticTaskOwnershipChecks $task $expected
    Assert-True (-not $report.Checks.$clause -and $report.Codes.$clause -eq 'mismatch' -and @($report.Checks.PSObject.Properties | Where-Object { -not $_.Value }).Count -eq 1) ('Task clause failure was not isolated: ' + $case)
    Assert-True ($report.Owned -eq (Test-FixtureLegacyOwnedTask $task $expected)) 'The structured predicate broadened legacy ownership acceptance.'
}
foreach ($case in @('named-enums', 'numeric-logon', 'numeric-level', 'numeric-text', 'enum-highest', 'unknown-enum', 'scalar-action', 'cim-like-action', 'nested-actions', 'string-wrapper')) {
    $task = New-FixtureTask
    switch ($case) {
        'named-enums' { $task.Principal.LogonType = [DiagnosticFixtureLogon]::Interactive; $task.Principal.RunLevel = [DiagnosticFixtureRunLevel]::Limited }
        'numeric-logon' { $task.Principal.LogonType = [uint32]3 }
        'numeric-level' { $task.Principal.RunLevel = [uint32]0 }
        'numeric-text' { $task.Principal.LogonType = '3'; $task.Principal.RunLevel = '0' }
        'enum-highest' { $task.Principal.RunLevel = [DiagnosticFixtureRunLevel]::Highest }
        'unknown-enum' { $task.Principal.LogonType = [Enum]::ToObject([DiagnosticFixtureLogon], 99) }
        'scalar-action' { $task.Actions = $task.Actions[0] }
        'cim-like-action' {
            $action = New-Object DiagnosticFixtureCimLikeAction
            $action.Execute = $expected.Execute; $action.Arguments = $expected.Arguments; $action.WorkingDirectory = $expected.Directory
            $task.Actions = $action
        }
        'nested-actions' { $task.Actions = ,@($task.Actions[0], $task.Actions[0]) }
        'string-wrapper' {
            $value = New-Object DiagnosticFixtureStringWrapper; $value.Value = 'Interactive'; $task.Principal.LogonType = $value
        }
    }
    $report = Get-DiagnosticTaskOwnershipChecks $task $expected
    Assert-True ($report.Owned -eq (Test-FixtureLegacyOwnedTask $task $expected)) ('PS enum/action representation changed ownership criteria: ' + $case)
    switch ($case) {
        'named-enums' { Assert-True ($report.Owned -and $report.Representations.LogonType -eq 'enum' -and $report.Representations.RunLevelToken -eq 'Limited') 'Named enum fixture must expose enum spelling without numeric reinterpretation.' }
        'numeric-logon' { Assert-True (-not $report.Checks.LogonType -and $report.Representations.LogonType -eq 'integer' -and $report.Representations.LogonTypeToken -eq 'numeric_3') 'Numeric logon values must be diagnosed without newly accepting them.' }
        'numeric-level' { Assert-True (-not $report.Checks.RunLevel -and $report.Representations.RunLevelToken -eq 'numeric_0') 'Numeric run level must remain a mismatch pending evidence.' }
        'numeric-text' { Assert-True ($report.Representations.LogonTypeToken -eq 'numeric_text_3') 'Numeric strings must remain distinguishable from enum/integer representations.' }
        'unknown-enum' { Assert-True (-not $report.Owned -and $report.Representations.LogonTypeToken -eq 'other') 'An unknown enum must not leak an arbitrary token or become accepted.' }
        'scalar-action' { Assert-True ($report.Owned -and $report.ActionsArrayCount -eq 1 -and $report.Representations.Actions -eq 'object') 'A scalar action must show the actual array-subexpression count behavior.' }
        'cim-like-action' { Assert-True ($report.Owned -and $report.ActionsArrayCount -eq 1 -and $report.Representations.FirstAction -eq 'object') 'A CIM-like scalar action must retain the original index/count semantics.' }
        'nested-actions' { Assert-True (-not $report.Owned -and $report.Representations.FirstAction -eq 'array') 'Nested actions cannot hide a second program through scalar count semantics.' }
    }
    Assert-True (-not (ConvertTo-DiagnosticTaskOwnershipReport $report).Contains('PRIVATE')) 'Representation reporting leaked a private task value.'
}
$task = New-FixtureTask
$task.Principal | Add-Member -MemberType ScriptProperty -Name LogonType -Value { throw 'PRIVATE-EXCEPTION-CONTENT' } -Force
$report = Get-DiagnosticTaskOwnershipChecks $task $expected
Assert-True (-not $report.Owned -and @('unavailable', 'mismatch') -contains $report.Codes.LogonType -and @('null', 'unavailable') -contains $report.Representations.LogonType -and $report.Checks.RunLevel -and $report.Checks.Execute) 'An unreadable/null clause must not hide independent remaining checks.'
Assert-True (-not (ConvertTo-DiagnosticTaskOwnershipReport $report).Contains('PRIVATE')) 'A throwing CIM-like getter leaked its exception content.'
$missingReport = Get-DiagnosticTaskOwnershipChecks ([pscustomobject]@{}) $expected
Assert-True (-not $missingReport.Owned -and $missingReport.Codes.Name -eq 'unavailable') 'Missing task metadata must fail closed with an unavailable code.'
$script:principalInput = $null
foreach ($case in @(
    @('PRIVATE-MACHINE\PRIVATE-NORMALIZED', 'qualified'),
    @('PRIVATE-NORMALIZED', 'unqualified'),
    @('PRIVATE-NORMALIZED@PRIVATE-DOMAIN', 'qualified'),
    @('S-PRIVATE-NAME', 'unqualified'),
    @($expected.Sid, 'sid')
)) {
    $identity = Get-DiagnosticPrincipalIdentity -PrincipalUserId $case[0] -ExpectedSid $expected.Sid -Resolver { param($value) $script:principalInput = $value; return 'S-1-5-21-123-456-789-1001' }
    Assert-True ($identity.PrincipalSidResolved -and $identity.PrincipalSidMatchesOwner -and $identity.PrincipalIdentityKind -eq $case[1] -and $identity.PrincipalIdentityCode -eq 'sid_match') 'Injected OS identity resolution was not compared by exact SID.'
    Assert-True ($script:principalInput -ceq $case[0]) 'Principal input was stripped, trimmed, qualified or guessed before the resolver.'
    Assert-True (-not ($identity | ConvertTo-Json -Compress).Contains('PRIVATE') -and -not ($identity | ConvertTo-Json -Compress).Contains($expected.Sid)) 'Principal identity evidence leaked an account or SID.'
}
$task = New-FixtureTask; $task.Principal.UserId = 'PRIVATE-MACHINE\PRIVATE-NORMALIZED'
$report = Get-DiagnosticTaskOwnershipChecks -Task $task -Expected $expected -PrincipalResolver { param($value) return 'S-1-5-21-123-456-789-1001' }
Assert-True ($report.PrincipalIdentity.PrincipalSidMatchesOwner -and $report.Checks.UserId -and $report.Owned -and -not (Test-FixtureLegacyOwnedTask $task $expected)) 'An OS-confirmed exact SID must accept the normalized name that the old textual comparison rejected.'
foreach ($property in $report.Checks.PSObject.Properties | Where-Object { $_.Name -ne 'UserId' }) { Assert-True $property.Value 'A normalized principal must not alter any other ownership clause.' }
$sameSpelling = New-FixtureTask
foreach ($principal in @($expected.Sid, $expected.Account)) {
    $sameSpelling.Principal.UserId = $principal
    $failedLookup = Get-DiagnosticTaskOwnershipChecks -Task $sameSpelling -Expected $expected -PrincipalResolver { param($value) throw 'PRIVATE-LOOKUP-FAILURE' }
    Assert-True (-not $failedLookup.Owned -and -not $failedLookup.Checks.UserId -and $failedLookup.Codes.UserId -eq 'unavailable' -and (Test-FixtureLegacyOwnedTask $sameSpelling $expected)) 'Lookup failure must fail closed even for the old exact account/SID spelling; there is no name fallback.'
    $wrongSid = Get-DiagnosticTaskOwnershipChecks -Task $sameSpelling -Expected $expected -PrincipalResolver { param($value) return 'S-1-5-21-123-456-789-1002' }
    Assert-True (-not $wrongSid.Owned -and -not $wrongSid.Checks.UserId -and $wrongSid.Codes.UserId -eq 'mismatch') 'A different resolved SID must reject even the previously accepted name/SID text.'
}
foreach ($case in @('qualified', 'unqualified')) {
    $task = New-FixtureTask
    $task.Principal.UserId = if ($case -eq 'qualified') { 'OTHER-DOMAIN\PRIVATE-NORMALIZED' } else { 'PRIVATE-NORMALIZED' }
    $mismatch = Get-DiagnosticTaskOwnershipChecks -Task $task -Expected $expected -PrincipalResolver { param($value) return 'S-1-5-21-123-456-789-1002' }
    Assert-True (-not $mismatch.Owned -and $mismatch.PrincipalIdentity.PrincipalSidResolved -and -not $mismatch.PrincipalIdentity.PrincipalSidMatchesOwner) 'A similar account in another identity must remain rejected by exact SID.'
}
$identity = Get-DiagnosticPrincipalIdentity -PrincipalUserId 'PRIVATE-MACHINE\PRIVATE-NORMALIZED' -ExpectedSid $expected.Sid -Resolver { param($value) return 'S-1-5-21-123-456-789-1002' }
Assert-True ($identity.PrincipalSidResolved -and -not $identity.PrincipalSidMatchesOwner -and $identity.PrincipalIdentityCode -eq 'sid_mismatch') 'A different OS-resolved SID must remain an explicit mismatch.'
foreach ($case in @('exception', 'null', 'array', 'object', 'name', 'overflow', 'noncanonical')) {
    $resolver = switch ($case) {
        'exception' { { param($value) throw 'PRIVATE-IDENTITY-EXCEPTION' } }
        'null' { { param($value) return $null } }
        'array' { { param($value) return @('S-1-5-21-123-456-789-1001', 'S-1-5-21-123-456-789-1001') } }
        'object' { { param($value) return [pscustomobject]@{ SID = 'PRIVATE-VALUE' } } }
        'name' { { param($value) return 'PRIVATE-ACCOUNT' } }
        'overflow' { { param($value) return 'S-1-5-21-1-2-3-4294967296' } }
        'noncanonical' { { param($value) return 'S-1-5-21-01-2-3-1001' } }
    }
    $identity = Get-DiagnosticPrincipalIdentity -PrincipalUserId 'PRIVATE-ACCOUNT' -ExpectedSid $expected.Sid -Resolver $resolver
    Assert-True (-not $identity.PrincipalSidResolved -and -not $identity.PrincipalSidMatchesOwner) ('An invalid resolution became identity evidence: ' + $case)
    Assert-True (-not ($identity | ConvertTo-Json -Compress).Contains('PRIVATE')) 'Resolver failure leaked private values or its exception.'
}
$script:invalidResolverCalls = 0
foreach ($bad in @($null, 123, @('a', 'b'), '', '   ', "PRIVATE`nNAME", ('x' * 1025))) {
    $identity = Get-DiagnosticPrincipalIdentity -PrincipalUserId $bad -ExpectedSid $expected.Sid -Resolver { param($value) $script:invalidResolverCalls++; return 'S-1-5-21-123-456-789-1001' }
    Assert-True (-not $identity.PrincipalSidResolved -and $identity.PrincipalIdentityKind -eq 'invalid' -and $identity.PrincipalIdentityCode -eq 'invalid_input') 'Invalid principal metadata reached identity resolution.'
}
Assert-True ($script:invalidResolverCalls -eq 0) 'Invalid metadata must not invoke a resolver.'
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
