#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windows = Split-Path $PSScriptRoot -Parent
$diagnostic = Join-Path $windows 'Get-PerpendicularGuestToolsDiagnostics.ps1'
$script:checks = 0
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
function Assert-Rejected { param([scriptblock]$Action, [string]$Message) $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $true }; Assert-True $rejected $Message }
function Read-FixtureAst {
    param([string]$Path)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Fixture source did not parse.' }
    return $ast
}
$sid = 'S-1-5-21-123-456-789-1001'
$account = 'FIXTURE-MACHINE\FIXTURE-USER'
$description = 'PerpendicularDesktopGuestAgent/v1;sid=' + $sid
$executable = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\FIXTURE\AppData\Local\Perpendicular Desktop\Guest Agent\PerpendicularAgent.ps1"'
function New-FixtureTask {
    return [pscustomobject]@{ Description = $description; Principal = [pscustomobject]@{ UserId = $sid }
        Actions = @([pscustomobject]@{ Execute = $executable; Arguments = $arguments }) }
}
function Test-OldFixtureOwnership {
    param($Task)
    return ($Task.Description -ceq $description -and @($sid, $account) -contains $Task.Principal.UserId -and
        @($Task.Actions).Count -eq 1 -and [string]::Equals($Task.Actions[0].Execute, $executable, [StringComparison]::OrdinalIgnoreCase) -and
        $Task.Actions[0].Arguments -ceq $arguments)
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('perpendicular-ownership-fixtures-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $diagnosticAst = Read-FixtureAst $diagnostic
    $identityDefinitions = @($diagnosticAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -cin @('Resolve-DiagnosticPrincipalSid', 'Test-DiagnosticCanonicalSid', 'Get-DiagnosticPrincipalIdentity') }, $false))
    Assert-True ($identityDefinitions.Count -eq 3) 'The reviewed identity source must contain exactly three shared declarations.'
    $sourceFixture = Join-Path $testRoot 'ownership-source.ps1'
    $sourceText = ($identityDefinitions | ForEach-Object { $_.Extent.Text }) -join "`n"
    # If the importer dot-sources the script rather than reading declarations,
    # this sentinel fails without touching any Windows API or external process.
    [IO.File]::WriteAllText($sourceFixture, ($sourceText + "`nthrow 'ENTRY_POINT_MUST_NOT_RUN'`nfunction Invoke-FixtureUnwanted { throw 'NOT_IMPORTED' }"))
    $previousBodies = $null
    foreach ($scriptName in @('Install-PerpendicularAgent.ps1', 'Uninstall-PerpendicularAgent.ps1')) {
        $ast = Read-FixtureAst (Join-Path $windows $scriptName)
        Assert-True ($ast.ParamBlock.Parameters.Count -eq 0) 'The production CLI must not expose a resolver, SID or source override.'
        $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
        $bodies = @($functions | ForEach-Object { $_.Extent.Text }) -join "`n"
        if ($null -ne $previousBodies) { Assert-True ($bodies -ceq $previousBodies) 'Installer and uninstaller must use the same reviewed import and pure ownership functions.' }
        $previousBodies = $bodies
        foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
        Initialize-AgentTaskOwnership -SourcePath $sourceFixture
        Assert-True ($null -eq (Get-Command Invoke-FixtureUnwanted -ErrorAction SilentlyContinue)) 'The import allowlist must ignore every other declaration.'
        # Never call the default Windows resolver, even for literal SID input.
        function Resolve-DiagnosticPrincipalSid { throw 'DEFAULT_OS_RESOLVER_MUST_NOT_RUN' }
        $base = @{ OwnerSid = $sid; Description = $description; Executable = $executable; Arguments = $arguments }
        $same = { param($value) $sid }
        $task = New-FixtureTask
        Assert-True (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver $same) 'The exact canonical owner SID must be accepted.'
        Assert-True (-not (Test-AgentTaskOwnership -Task $task @base)) 'OS lookup failure must fail closed, even when SID text matches the old guard.'
        $task.Principal.UserId = 'PRIVATE-NORMALIZED'
        Assert-True (-not (Test-OldFixtureOwnership $task)) 'The historical textual predicate must reproduce the actual unqualified-name rejection.'
        $script:resolverInput = $null
        $forwarding = { param($value) $script:resolverInput = $value; $sid }
        Assert-True (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver $forwarding) 'Only the proven exact OS SID resolution may fix the historical name rejection.'
        Assert-True ($script:resolverInput -ceq 'PRIVATE-NORMALIZED') 'Forward the actual principal untouched; do not strip or guess a domain.'
        foreach ($principal in @($sid, $account, 'PRIVATE-NORMALIZED', 'OTHER-DOMAIN\PRIVATE-NORMALIZED', 'PRIVATE-NORMALIZED@example.invalid')) {
            $task.Principal.UserId = $principal
            Assert-True (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver $same) 'Qualified, unqualified and SID spellings require the same exact resolved SID.'
            Assert-True (-not (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver { 'S-1-5-21-123-456-789-1002' })) 'A different resolved SID must reject every principal spelling.'
            Assert-True (-not (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver { throw 'PRIVATE_LOOKUP_FAILURE' })) 'A lookup exception must reject every principal spelling.'
        }
        foreach ($principal in @($sid, $account)) {
            $task.Principal.UserId = $principal
            Assert-True (Test-OldFixtureOwnership $task) 'The historical guard must demonstrate that matching name/SID text previously passed.'
            Assert-True (-not (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver { 'S-1-5-21-1-2-3-1001' })) 'Matching old text must not substitute for exact canonical OS identity.'
        }
        foreach ($invalid in @($null, '', "PRIVATE`nNAME", @('PRIVATE', 'OTHER'), ([pscustomobject]@{ Value = $sid }))) {
            $task.Principal.UserId = $invalid
            Assert-True (-not (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver $same)) 'Non-string, empty or control-bearing principals must fail closed.'
        }
        $task = New-FixtureTask
        foreach ($resolver in @({ @($sid, $sid) }, { [pscustomobject]@{ Value = $sid } }, { 'S-1-5-21-1-2-3-4294967296' }, { '' }, { $null })) {
            Assert-True (-not (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver $resolver)) 'Invalid, multiple or unavailable resolution results must fail closed.'
        }
        foreach ($mode in @('description', 'program', 'extra-argument', 'different-script', 'option-case', 'zero-actions', 'extra-action', 'missing-principal', 'missing-action-field')) {
            $task = New-FixtureTask
            switch ($mode) {
                'description' { $task.Description += '-OTHER' }
                'program' { $task.Actions[0].Execute = 'C:\Windows\OTHER.exe' }
                'extra-argument' { $task.Actions[0].Arguments += ' -OTHER' }
                'different-script' { $task.Actions[0].Arguments = $arguments.Replace('PerpendicularAgent.ps1', 'OTHER.ps1') }
                'option-case' { $task.Actions[0].Arguments = $arguments.Replace('-NoLogo', '-nologo') }
                'zero-actions' { $task.Actions = @() }
                'extra-action' { $task.Actions = @($task.Actions[0], $task.Actions[0]) }
                'missing-principal' { $task.PSObject.Properties.Remove('Principal') }
                'missing-action-field' { $task.Actions[0].PSObject.Properties.Remove('Arguments') }
            }
            Assert-True (-not (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver $same)) ('An existing non-identity guard changed or stopped failing closed: ' + $mode)
        }
        $task = New-FixtureTask; $task.Actions[0].Execute = $executable.ToUpperInvariant()
        Assert-True (Test-AgentTaskOwnership -Task $task @base -PrincipalResolver $same) 'The existing case-insensitive executable comparison must remain unchanged.'
        $legacyFiles = @('PerpendicularAgent.ps1', 'PerpendicularAgent.Core.ps1', 'PerpendicularAgent.Display.ps1', 'Uninstall-PerpendicularAgent.ps1')
        $manifest = [pscustomobject]@{ product = 'Perpendicular Desktop Guest Agent'; owner_sid = $sid; files = $legacyFiles }
        Assert-True (Test-AgentManifestOwnership -Manifest $manifest -OwnerSid $sid) 'An owned old manifest must upgrade without pretending it already declared the new source.'
        $runtimeFiles = @(Get-AgentRuntimeFiles)
        Assert-True ($runtimeFiles.Count -eq 5 -and @($runtimeFiles | Where-Object { $_ -ceq 'Get-PerpendicularGuestToolsDiagnostics.ps1' }).Count -eq 1) 'The shared source must be copied, required and removed exactly once in the fixed runtime file list.'
        Assert-True (@($legacyFiles | Where-Object { $runtimeFiles -cnotcontains $_ }).Count -eq 0) 'No legacy runtime file may be dropped during upgrade.'
        foreach ($mode in @('product', 'sid', 'missing-owner')) {
            $bad = $manifest | ConvertTo-Json | ConvertFrom-Json
            switch ($mode) { 'product' { $bad.product = 'OTHER' } 'sid' { $bad.owner_sid += '-OTHER' } 'missing-owner' { $bad.PSObject.Properties.Remove('owner_sid') } }
            Assert-True (-not (Test-AgentManifestOwnership -Manifest $bad -OwnerSid $sid)) 'Legacy upgrade must not weaken product or exact owner SID requirements.'
        }
        foreach ($mode in @('missing', 'syntax', 'duplicate', 'oversize', 'directory', 'incomplete')) {
            $badSource = Join-Path $testRoot ($mode + '.ps1')
            switch ($mode) {
                'syntax' { [IO.File]::WriteAllText($badSource, 'function {') }
                'duplicate' { [IO.File]::WriteAllText($badSource, ($sourceText + "`n" + $identityDefinitions[0].Extent.Text)) }
                'oversize' { [IO.File]::WriteAllText($badSource, ('#' * 1048577)) }
                'directory' { [void][IO.Directory]::CreateDirectory($badSource) }
                'incomplete' { [IO.File]::WriteAllText($badSource, $identityDefinitions[0].Extent.Text) }
            }
            Assert-Rejected { Initialize-AgentTaskOwnership -SourcePath $badSource } ('Unusable source must stop before any task mutation: ' + $mode)
        }
    }
    Write-Output ('PASS: ' + $script:checks + ' agent installer/uninstaller ownership checks. Shared declarations only; causal legacy-name regression, exact SID/mismatch/exception, preserved action guards and old-manifest upgrade. No OS identity API, task, process, driver, privilege, guest channel or VM was accessed or changed.')
} finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }
