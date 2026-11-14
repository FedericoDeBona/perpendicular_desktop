$ErrorActionPreference='Stop'
$target=Join-Path $env:ProgramData 'Perpendicular\Setup'
New-Item -ItemType Directory -Force $target|Out-Null
& icacls.exe $target /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'|Out-Null
if($LASTEXITCODE-ne0){throw 'Cannot protect setup directory'}
Copy-Item "$PSScriptRoot\*" $target -Recurse -Force
Start-Transcript (Join-Path $target 'system-install.log') -Append|Out-Null
try {
    foreach($name in 'install-network.ps1','install-memory.ps1','install-graphics.ps1') {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $target $name)
        if($LASTEXITCODE-ne0){throw ('Initial driver setup failed: '+$name)}
    }
    @{phase='drivers-installed';time=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $target 'status.json') -Encoding UTF8
} catch {
    @{phase='failed';message=$_.ToString()}|ConvertTo-Json|Set-Content (Join-Path $target 'status.json') -Encoding UTF8
    throw
} finally {Stop-Transcript|Out-Null}
