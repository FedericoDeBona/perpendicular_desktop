param([string]$MediaRoot=$PSScriptRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.IsSystem -or ![Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Install folder integration in the interactive installation administrator profile.'}
$target=Join-Path $env:ProgramFiles 'Perpendicular Shared Files'
New-Item -ItemType Directory -Force $target|Out-Null
foreach($name in @('configure-shared-folders.ps1','apply-shared-folders.ps1','connect-shared-folders.ps1','retire-shared-files.ps1','configure-smb-cache.ps1')){Copy-Item (Join-Path $MediaRoot $name) $target -Force}
$sid=$identity.User.Value;$requests=Join-Path $env:ProgramData ('Perpendicular\FolderRequests\'+$sid)
New-Item -ItemType Directory -Force $requests|Out-Null
& icacls.exe $requests /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' (('*'+$sid)+':(OI)(CI)RX')|Out-Null
if($LASTEXITCODE -ne 0){throw 'Cannot protect the folder request directory.'}
$request=Join-Path $requests 'request.json';$response=Join-Path $requests 'response.json'
foreach($path in @($request,$response)){if(!(Test-Path -LiteralPath $path)){[IO.File]::WriteAllText($path,'{}')}}
& icacls.exe $request /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' (('*'+$sid)+':RW')|Out-Null
if($LASTEXITCODE -ne 0){throw 'Cannot protect the folder request.'}
$action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $target 'apply-shared-folders.ps1')+'"')
$principal=New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName ('PerpendicularFolders-'+$sid) -Action $action -Principal $principal -Force|Out-Null
Write-Output 'Private SMB folder integration installed.'
