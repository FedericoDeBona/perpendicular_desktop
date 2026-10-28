$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'Perpendicular Restart'
New-Item -ItemType Directory -Force -Path $root | Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not secure the guest installation directory.' }
Start-Transcript -Path (Join-Path $root 'installation.log') -Append | Out-Null
try {
    # Ordinary updates install this bridge; the explicit one-time removal of
    # legacy agents and sharing is handled by remove-legacy.ps1.
    $shared=Join-Path $PSScriptRoot 'SharedFiles'
    if(Test-Path (Join-Path $shared 'install-shared-folders.ps1')) {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $shared 'install-shared-folders.ps1') -MediaRoot $shared
        if ($LASTEXITCODE -ne 0) { throw 'The shared-folder components could not be installed.' }
    }
    & (Join-Path $PSScriptRoot 'perpendicular-guest.exe') install (Join-Path $PSScriptRoot 'connection.json')
    if ($LASTEXITCODE -ne 0) { throw 'The new guest service could not be installed.' }
    & sc.exe failure PerpendicularRestart reset= 86400 actions= restart/2000/restart/5000/restart/10000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure guest service recovery.' }
    Write-Host 'Perpendicular guest installed.'
} finally {
    Stop-Transcript | Out-Null
}
