param([string]$MediaRoot=$PSScriptRoot,[switch]$InstallOnly)
$ErrorActionPreference='Stop'
$state=Join-Path $env:ProgramData 'Perpendicular\SharedDownloads'
New-Item -ItemType Directory -Force $state | Out-Null
Start-Transcript -Path (Join-Path $state 'install.log') -Append
try {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run the shared Downloads setup as administrator.'}
    if (!(Confirm-SecureBootUEFI)) {throw 'Secure Boot must remain enabled.'}
    $manifest=Get-Content (Join-Path $MediaRoot 'virtiofs-drivers.json') -Raw | ConvertFrom-Json
    foreach ($member in $manifest.members.psobject.Properties) {
        $file=Join-Path $MediaRoot $member.Name
        if ((Get-FileHash $file -Algorithm SHA256).Hash -ine $member.Value) {throw "Package hash differs: $($member.Name)"}
    }
    foreach ($name in @('winfsp-2.1.25156.msi','viofs\viofs.cat')) {
        $signature=Get-AuthenticodeSignature (Join-Path $MediaRoot $name)
        if ($signature.Status -ne 'Valid') {throw "Invalid signature: $name ($($signature.Status))"}
        Write-Output "$name : $($signature.SignerCertificate.Subject)"
    }
    $prior=Get-Service VirtioFsSvc -ErrorAction SilentlyContinue
    $target=Join-Path $env:ProgramFiles 'Perpendicular Shared Files'
    if ($prior) {
        $existing=Get-CimInstance Win32_Service -Filter "Name='VirtioFsSvc'"
        if ($existing.PathName -notlike ('*'+$target+'*')) {throw 'An existing unrelated virtiofs service must be handled separately.'}
        Stop-Service VirtioFsSvc
    }
    if (!(Test-Path 'HKLM:\SOFTWARE\WOW6432Node\WinFsp') -and !(Test-Path 'HKLM:\SOFTWARE\WinFsp')) {
        $msi=Join-Path $MediaRoot 'winfsp-2.1.25156.msi'
        $p=Start-Process msiexec.exe -ArgumentList @('/i',('"'+$msi+'"'),'/qn','/norestart','ADDLOCAL=ALL','/l*v',('"'+(Join-Path $state 'winfsp-install.log')+'"')) -Wait -PassThru
        if ($p.ExitCode -notin @(0,3010)) {throw "WinFsp installation failed: $($p.ExitCode)"}
    }
    New-Item -ItemType Directory -Force $target | Out-Null
    Copy-Item (Join-Path $MediaRoot 'viofs\virtiofs.exe') $target -Force
    & pnputil.exe /add-driver (Join-Path $MediaRoot 'viofs\viofs.inf') /install
    if ($LASTEXITCODE -notin @(0,3010)) {throw "Virtiofs driver installation failed: $LASTEXITCODE"}
    Copy-Item (Join-Path $MediaRoot 'configure-shared-folders.ps1') $target -Force
    if ($InstallOnly) {
        # SYSTEM installs components only. The interactive user's normal
        # Downloads path is configured separately; never allocate a drive letter.
        if ($prior) {Set-Service VirtioFsSvc -StartupType Manual}
        @{componentsInstalled=$true;userFolderConfigurationRequired=$true} | ConvertTo-Json | Set-Content (Join-Path $state 'components.json') -Encoding UTF8
        return
    }
    & (Join-Path $MediaRoot 'configure-shared-folders.ps1') -Folder downloads
} finally {Stop-Transcript}
