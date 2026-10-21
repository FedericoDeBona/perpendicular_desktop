$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'Perpendicular Restart'
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path (Join-Path $root 'graphics-install.log') -Append | Out-Null
try {
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'graphics-driver.json') | ConvertFrom-Json
    $drivers = Join-Path $PSScriptRoot 'Graphics'
    foreach ($member in $manifest.members.PSObject.Properties) {
        $file = Join-Path $drivers $member.Name
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash -ine $member.Value) {
            throw ('Driver file does not match the selected release: ' + $member.Name)
        }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $drivers 'viogpu3d.cat')
    if ($signature.Status -ne 'Valid') { throw ('Driver catalog signature is not trusted: ' + $signature.Status) }
    & pnputil.exe /add-driver (Join-Path $drivers 'viogpu3d.inf') /install
    $code = $LASTEXITCODE
    if ($code -notin @(0, 3010)) { throw ('Windows could not stage the graphics driver. Exit code: ' + $code) }
    @{ release = $manifest.release; signature = [string]$signature.Status
       signer = $signature.SignerCertificate.Subject; exitCode = $code
       completedAt = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $root 'graphics-install.json')
    Write-Host 'Signed Windows ARM64 graphics driver is ready. No forced restart or security-setting change was performed.'
} finally {
    Stop-Transcript | Out-Null
}
