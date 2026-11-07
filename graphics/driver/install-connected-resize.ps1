# Candidate: original Microsoft-signed v0.5 on the accelerated adapter only.
# Keep the already qualified external UMD/OpenGL registrations across PnP install.
param([Parameter(Mandatory=$true)][Guid]$ExpectedMachineID,
      [string]$PayloadRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
if([Guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedMachineID){throw 'Wrong machine'}
if(![Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator consent required'}
if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State').UEFISecureBootEnabled -ne 1){throw 'Secure Boot must stay enabled'}
$manifest=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $PayloadRoot 'release.json')))
foreach($member in $manifest.members.PSObject.Properties){
 if((Get-FileHash (Join-Path $PayloadRoot ('Graphics\'+$member.Name))).Hash -ine $member.Value){throw ('Signed package differs: '+$member.Name)}
}
if((Get-FileHash (Join-Path $PayloadRoot 'install-mixed-display-driver.ps1')).Hash -ine $manifest.installer_helper_sha256){throw 'Device installer differs'}
$sig=Get-AuthenticodeSignature (Join-Path $PayloadRoot 'Graphics\viogpu3d.cat')
if($sig.Status -ne 'Valid'){throw 'Signed catalog is not trusted'}
$devices=@(Get-PnpDevice -Class Display -PresentOnly | Where-Object {
 $_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*' -and
 @((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_HardwareIds).Data -match '^PCI\\VEN_1AF4&DEV_1050&SUBSYS_11011AF4(&|$)').Count -gt 0
})
if($devices.Count -ne 1){throw 'Expected exactly one accelerated PCI adapter'}
$id=$devices[0].InstanceId
$kernelPath=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VioGpu3D').ImagePath -replace '^\\SystemRoot',$env:SystemRoot
$kernelHash=(Get-FileHash -LiteralPath $kernelPath).Hash
if($kernelHash -inotmatch '^(cfbc713754c7f0dcae4803017af3a0ebfc781d37fd57604f8ee8f2cfdad306c4|642f2d861124639059469722c165fb9a640eed0dad97d30e59e5a42b88d4b1d6)$'){throw 'Unrecognized current kernel'}
$driverKey=(Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Driver).Data
$key=Get-Item ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+$driverKey)
$entries=@()
foreach($name in 'UserModeDriverName','UserModeDriverNameWoW','VulkanDriverName','OpenGLDriverName','OpenGLDriverNameWoW'){
 if($name -notin $key.GetValueNames()){continue}
 $value=$key.GetValue($name);$files=@()
 foreach($path in @($value)){
  if($path -eq '<>'){continue}
  if($name -eq 'VulkanDriverName'){
   $glRoot=Join-Path $env:ProgramData ('Perpendicular\Graphics\OpenGL\'+$manifest.opengl_version)
   if($path -inotmatch ('^'+[regex]::Escape($glRoot)+'\\(arm64|x64)\\virtio_icd\.json$')){throw 'Unrecognized Vulkan manifest; preserved'}
   $icd=ConvertFrom-Json ([IO.File]::ReadAllText($path))
   $library=Join-Path (Split-Path $path) 'vulkan_virtio.dll'
   if($icd.ICD.library_path -ine $library -or $icd.file_format_version -ne '1.0.1'){throw 'Unexpected Vulkan manifest contents'}
   if((Get-FileHash $library).Hash -notin $manifest.preserved_dll_sha256){throw 'Unqualified Vulkan ICD'}
   $files+=@{path=$path;sha256=(Get-FileHash $path).Hash};continue
  }
  # The qualified UMD/ICDs live outside DriverStore and must survive the update.
  if(!$path.StartsWith($env:ProgramFiles+'\Perpendicular ',[StringComparison]::OrdinalIgnoreCase)){throw ('Unrecognized registration; preserved: '+$name)}
  $hash=(Get-FileHash -LiteralPath $path).Hash
  if($hash -inotmatch ('^('+(($manifest.preserved_dll_sha256) -join '|')+')$')){throw ('Unqualified registered DLL: '+$name)}
  $files+=@{path=$path;sha256=$hash}
 }
 $entries+=@{name=$name;kind=$key.GetValueKind($name).ToString();value=$value;files=$files}
}
if(@($entries | Where-Object {$_.name -eq 'UserModeDriverName'}).Count -ne 1 -or
   @($entries | Where-Object {$_.name -eq 'UserModeDriverNameWoW'}).Count -ne 1){throw 'Qualified UMD registrations required'}
$root=Join-Path $env:ProgramData 'Perpendicular Restart\ConnectedResize'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$backup=Join-Path $root 'before-v05.json'
if(!(Test-Path $backup)){@{instance=$id;key=$key.Name;entries=$entries;kernel=$kernelHash}|ConvertTo-Json -Depth 8|Set-Content $backup -Encoding UTF8}
if($kernelHash -ine $manifest.members.'viogpu3d.sys'){
 # Stage without /install: never update the app display adapters with this INF.
 & pnputil.exe /add-driver (Join-Path $PayloadRoot 'Graphics\viogpu3d.inf')
 if($LASTEXITCODE -ne 0){throw 'Could not stage signed driver'}
 # The selected DriverStore INF avoids the CD install failure observed previously.
 $staged=@(Get-WindowsDriver -Online -All | Where-Object {
  $_.ClassName -eq 'Display' -and (Split-Path $_.OriginalFileName -Leaf) -eq 'viogpu3d.inf' -and
  (Get-FileHash $_.OriginalFileName).Hash -ieq $manifest.members.'viogpu3d.inf'
 })
 if($staged.Count -ne 1){throw 'Expected one pinned staged INF'}
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PayloadRoot 'install-mixed-display-driver.ps1') -InstanceId $id -Role Accelerated -AcceleratedRelease v0.5 -InfPath $staged[0].OriginalFileName
 if($LASTEXITCODE -ne 0){throw 'Selected adapter installation failed; inspect retained backup'}
}
$newKey='HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+(Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Driver).Data
foreach($entry in $entries){
 foreach($file in $entry.files){if((Get-FileHash $file.path).Hash -ine $file.sha256){throw 'Registered DLL changed during update'}}
 New-ItemProperty -LiteralPath $newKey -Name $entry.name -PropertyType $entry.kind -Value $entry.value -Force | Out-Null
 if((@((Get-Item $newKey).GetValue($entry.name)) -join "`0") -cne (@($entry.value) -join "`0")){throw 'Registration readback differs'}
}
$currentPath=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VioGpu3D').ImagePath -replace '^\\SystemRoot',$env:SystemRoot
$after=(Get-FileHash -LiteralPath $currentPath).Hash
if($after -ine $manifest.members.'viogpu3d.sys'){throw 'Selected driver path differs'}
@{status='installed-coldboot-required';instance=$id;kernelSHA256=$after;signature=$sig.Status;preserved=$entries;completedAt=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root 'installed-v05.json') -Encoding UTF8
'Signed connected-resize driver installed. Shut down normally, then verify the loaded kernel and UMDs after coldboot.'
