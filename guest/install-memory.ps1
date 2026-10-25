$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'Perpendicular Restart'
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path (Join-Path $root 'memory-install.log') -Append | Out-Null
try {
    $manifest = Get-Content -Raw (Join-Path $PSScriptRoot 'memory-drivers.json') | ConvertFrom-Json
    foreach ($member in $manifest.members.PSObject.Properties) {
        $file = Join-Path (Join-Path $PSScriptRoot 'Memory') $member.Name
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash -ine $member.Value) {
            throw ('Memory driver does not match the selected package: ' + $member.Name)
        }
    }
    foreach ($driver in @('Balloon/balloon', 'VioMem/viomem')) {
        $path = Join-Path (Join-Path $PSScriptRoot 'Memory') $driver
        $signature = Get-AuthenticodeSignature -LiteralPath ($path + '.cat')
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft*') {
            throw ('Memory driver catalog is not Microsoft trusted: ' + $driver)
        }
        & pnputil.exe /add-driver ($path + '.inf') /install
        if ($LASTEXITCODE -notin @(0, 3010)) { throw ('Memory driver installation failed: ' + $driver) }
    }
    @{ completedAt = [DateTime]::UtcNow.ToString('o'); balloonVersion = $manifest.balloonVersion
       virtioMemVersion = $manifest.virtioMemVersion } |
        ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $root 'memory-install.json')
} finally {
    Stop-Transcript | Out-Null
}
