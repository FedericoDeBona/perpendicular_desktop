$ErrorActionPreference = 'Stop'
try {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Memory')) {
        & (Join-Path $PSScriptRoot 'install-memory.ps1')
    }
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'NetKVM')) {
        & (Join-Path $PSScriptRoot 'install-network.ps1')
    }
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Graphics')) {
        & (Join-Path $PSScriptRoot 'install-graphics.ps1')
    }
    & (Join-Path $PSScriptRoot 'install.ps1')
    Write-Host 'Perpendicular machine setup completed.'
} catch {
    Write-Host ('Setup failed: ' + $_) -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}
