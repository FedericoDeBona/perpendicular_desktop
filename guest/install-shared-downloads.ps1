param([string]$MediaRoot=$PSScriptRoot,[switch]$InstallOnly,[ValidatePattern('^[0-9]+:[0-9]+$')][string]$MacOwner='501:20')
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
    Copy-Item (Join-Path $MediaRoot 'apply-shared-folders.ps1') $target -Force
    # Only this user can submit a bounded folder selection. Parent directory,
    # task action and response are protected from replacement by the caller.
    if (!$identity.IsSystem) {
        $sid=$identity.User.Value
        $requests=Join-Path $env:ProgramData ('Perpendicular\FolderRequests\'+$sid)
        New-Item -ItemType Directory -Force $requests | Out-Null
        & icacls.exe $requests /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' (('*'+$sid)+':(OI)(CI)RX') | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Cannot protect folder request directory.'}
        $request=Join-Path $requests 'request.json';$response=Join-Path $requests 'response.json'
        foreach($path in @($request,$response)){if(!(Test-Path -LiteralPath $path)){[IO.File]::WriteAllText($path,'{}')}}
        & icacls.exe $request /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' (('*'+$sid)+':RW') | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Cannot protect folder request file.'}
        $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $target 'apply-shared-folders.ps1')+'" -Owner '+$MacOwner)
        $taskPrincipal=New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName ('PerpendicularFolders-'+$sid) -Action $action -Principal $taskPrincipal -Force | Out-Null
    }
    if ($InstallOnly) {
        # SYSTEM installs components only. The interactive user's normal
        # Downloads path is configured separately; never allocate a drive letter.
        if ($prior) {Set-Service VirtioFsSvc -StartupType Manual}
        @{componentsInstalled=$true;userFolderConfigurationRequired=$true} | ConvertTo-Json | Set-Content (Join-Path $state 'components.json') -Encoding UTF8
        return
    }
    & (Join-Path $MediaRoot 'configure-shared-folders.ps1') -Folder downloads
} finally {Stop-Transcript}
