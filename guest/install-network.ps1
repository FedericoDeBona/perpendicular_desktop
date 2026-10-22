$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'Perpendicular Restart'
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path (Join-Path $root 'network-install.log') -Append | Out-Null
try {
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'network-driver.json') | ConvertFrom-Json
    $drivers = Join-Path $PSScriptRoot 'NetKVM'
    foreach ($member in $manifest.members.PSObject.Properties) {
        $file = Join-Path $drivers $member.Name
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash -ine $member.Value) {
            throw ('Network driver does not match the selected package: ' + $member.Name)
        }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $drivers 'netkvm.cat')
    if ($signature.Status -ne 'Valid') { throw ('Network catalog is not trusted: ' + $signature.Status) }
    & pnputil.exe /add-driver (Join-Path $drivers 'netkvm.inf') /install
    $code = $LASTEXITCODE
    if ($code -notin @(0, 3010)) { throw ('Network driver installation failed: ' + $code) }
    @{ version = $manifest.version; signature = [string]$signature.Status
       signer = $signature.SignerCertificate.Subject; exitCode = $code
       completedAt = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $root 'network-install.json')
} finally {
    Stop-Transcript | Out-Null
}
