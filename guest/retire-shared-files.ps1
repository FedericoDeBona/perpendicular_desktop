param([switch]$RemoveUnusedWinFsp)
# One-time removal only, after the ordinary profile paths have migrated safely.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$sid=$identity.User.Value
if($identity.IsSystem -or ![Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Retirement requires the installation administrator.'}
$client=Join-Path $env:ProgramFiles 'Perpendicular Shared Files\virtiofs.exe'
$definitions=@{desktop='PerpendicularFolderDesktop';documents='PerpendicularFolderDocuments';downloads='VirtioFsSvc';pictures='PerpendicularFolderPictures';music='PerpendicularFolderMusic';videos='PerpendicularFolderVideos'}
if([IO.File]::Exists($client)){
 if((Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash -ine 'c9371f1a2ed15c53c3c34a21cc1eec0fca63088135ef1e239876b354abe74a8f'){throw 'An unrelated legacy client must not be removed.'}
 if(@(Get-PnpDevice -PresentOnly|Where-Object InstanceId -like 'PCI\VEN_1AF4&DEV_105A*').Count){throw 'Restart Windows without the retired filesystem devices before removing their driver.'}
 foreach($kind in $definitions.Keys){
  $name=$definitions[$kind];$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\'+$name)
  if(!$key){continue}
  try{$image=$key.GetValue('ImagePath')}finally{$key.Close()}
  if(!$image.StartsWith(('"'+$client+'"'),[StringComparison]::OrdinalIgnoreCase)){throw 'An unrelated service must not be removed.'}
  $state=Get-Content (Join-Path $env:ProgramData ('Perpendicular\SharedFolders\'+$sid+'\'+$kind+'.json')) -Raw|ConvertFrom-Json
  if($state.backend -ne 'smb' -or $state.phase -notin @('shared','local')){throw 'Folder migration has not completed.'}
  $service=Get-Service -Name $name;if($service.Status -ne 'Stopped'){throw 'The legacy client is still active.'}
  & sc.exe delete $name|Out-Null;if($LASTEXITCODE -notin @(0,1060)){throw 'Cannot delete a retired service.'}
 }
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\VirtioFsDrv')
 if($key){
  try{$driver=$key.GetValue('ImagePath')}finally{$key.Close()}
  if($driver.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase)){$driver=$env:SystemRoot+'\'+$driver.Substring('\SystemRoot\'.Length)}
  if((Get-FileHash -LiteralPath $driver -Algorithm SHA256).Hash -ine '6c1d0225d06645acace3573385c1f00e05285a554737eaef418a9930c95c9da3'){throw 'An unrelated driver must not be removed.'}
  $inf=Join-Path ([IO.Path]::GetDirectoryName($driver)) 'viofs.inf'
  $packages=@(Get-WindowsDriver -Online|Where-Object OriginalFileName -eq $inf)
  if($packages.Count -ne 1){throw 'Cannot identify the exact retired driver package.'}
  & pnputil.exe /delete-driver $packages[0].Driver /uninstall|Out-Null
  if($LASTEXITCODE -notin @(0,3010)){throw 'Driver removal did not complete.'}
  # PnP can leave the unloaded service registration until a restart.
  & sc.exe stop VirtioFsDrv 2>&1|Out-Null
  & sc.exe delete VirtioFsDrv|Out-Null
  if($LASTEXITCODE -notin @(0,1060)){throw 'Cannot retire the driver service registration.'}
 }
 Remove-Item -LiteralPath $client -Force
 [IO.File]::WriteAllText((Join-Path $env:ProgramData 'Perpendicular\SharedDownloads\retired.json'),'{"backend":"smb","clientRemoved":true}')
}
if($RemoveUnusedWinFsp){
 $owned=Join-Path $env:ProgramData 'Perpendicular\SharedDownloads\components.json'
 if(![IO.File]::Exists($owned)){throw 'No previous component installation record; shared WinFsp was preserved.'}
 $other=@(Get-Process|ForEach-Object{try{if($_.ProcessName -notlike 'launch*' -and @($_.Modules|Where-Object ModuleName -match '^winfsp-(x64|a64|arm64|x86)\.dll$').Count){$_.Id}}catch{}})
 if($other.Count){throw 'Another active application uses WinFsp; it was preserved.'}
 $products=@(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue|Where-Object {$_.DisplayName -like 'WinFsp*' -and $_.DisplayVersion -eq '2.1.25156'})
 foreach($product in $products){
  if($product.PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$'){throw 'Unexpected WinFsp installer identity.'}
  $process=Start-Process msiexec.exe -ArgumentList @('/x',$product.PSChildName,'/qn','/norestart') -Wait -PassThru
  if($process.ExitCode -notin @(0,3010)){throw ('WinFsp removal failed: '+$process.ExitCode)}
 }
}
Write-Output 'LEGACY_FILESYSTEM_RETIRED'
