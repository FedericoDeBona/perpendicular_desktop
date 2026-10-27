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
    if (Get-PSDrive X -ErrorAction SilentlyContinue) {
        $disk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='X:'"
        if (!$prior -or $disk.FileSystem -ne 'NTFS') {throw 'Drive X: is already occupied.'}
    }
    $key='HKLM:\SOFTWARE\VirtIO-FS'
    New-Item -Path $key -Force | Out-Null
    foreach ($entry in @{MountPoint='X:';Owner='501:20';FileSystemName='NTFS'}.GetEnumerator()) {
        New-ItemProperty $key -Name $entry.Key -Value $entry.Value -PropertyType String -Force | Out-Null
    }
    New-ItemProperty $key -Name CaseInsensitive -Value 1 -PropertyType DWord -Force | Out-Null
    $binary='"'+(Join-Path $target 'virtiofs.exe')+'" -t mac-downloads -m X: -o 501:20 -i -F NTFS'
    if ($prior) {
        $change=Invoke-CimMethod -InputObject (Get-CimInstance Win32_Service -Filter "Name='VirtioFsSvc'") -MethodName Change -Arguments @{PathName=$binary;StartMode='Automatic'}
        if ($change.ReturnValue -ne 0) {throw "Cannot configure the shared Downloads service: $($change.ReturnValue)"}
    } else {
        New-Service -Name VirtioFsSvc -DisplayName 'Perpendicular Shared Downloads' -BinaryPathName $binary -StartupType Automatic -DependsOn VirtioFsDrv | Out-Null
    }
    & sc.exe failure VirtioFsSvc reset= 60 actions= restart/3000/restart/10000/restart/30000 | Out-Null
    Start-Service VirtioFsSvc
    $deadline=(Get-Date).AddSeconds(30)
    while (!(Test-Path 'X:\') -and (Get-Date) -lt $deadline) {Start-Sleep -Milliseconds 250}
    if (!(Test-Path 'X:\')) {throw 'The Mac Downloads volume is not mounted; Downloads has not been redirected.'}
    if ($InstallOnly) {
        @{mounted=$true;service=(Get-Service VirtioFsSvc).Status.ToString()} | ConvertTo-Json | Set-Content (Join-Path $state 'mounted.json') -Encoding UTF8
        return
    }
    & (Join-Path $MediaRoot 'redirect-shared-downloads.ps1')
} finally {Stop-Transcript}
