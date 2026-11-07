# Install the paired ARM64 video UMD without changing DriverStore, kernel,
# WoW or OpenGL registrations. Normal administrator consent is required.
param([Parameter(Mandatory=$true)][Guid]$ExpectedMachineID,
      [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256,
      [Parameter(Mandatory=$true)][string]$ExpectedRevision,
      [string]$PayloadRoot=$PSScriptRoot,
      [switch]$Restore)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if([Guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedMachineID){throw 'Wrong machine'}
if(![Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Normal administrator consent required'}
if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State').UEFISecureBootEnabled -ne 1){throw 'Secure Boot must remain enabled'}
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class VideoPayloadIntegrity {
 [StructLayout(LayoutKind.Sequential)]struct Info{public uint Length,Options;}
 [DllImport("ntdll.dll")]static extern int NtQuerySystemInformation(int c,ref Info i,uint n,out uint r);
 public static bool Protected(){var i=new Info{Length=8};uint n;return NtQuerySystemInformation(103,ref i,8,out n)==0&&(i.Options&1)!=0&&(i.Options&2)==0;}
}
'@
if(![VideoPayloadIntegrity]::Protected()){throw 'Code Integrity must remain enabled and test signing disabled'}
$kernelPath=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VioGpu3D').ImagePath -replace '^\\SystemRoot',$env:SystemRoot
$kernelHash=(Get-FileHash -LiteralPath $kernelPath).Hash
if($kernelHash -inotmatch '^(cfbc713754c7f0dcae4803017af3a0ebfc781d37fd57604f8ee8f2cfdad306c4|642f2d861124639059469722c165fb9a640eed0dad97d30e59e5a42b88d4b1d6)$'){throw 'Unsupported signed graphics kernel; preserve current registration'}
$driver=Split-Path $kernelPath
$originals=@{
 'viogpu3d.sys'='cfbc713754c7f0dcae4803017af3a0ebfc781d37fd57604f8ee8f2cfdad306c4'
 'neptune_umd.dll'='cf7cd403a6b89b519bbffc43c43f42d8da5ba97259fe7b5a6e489628d8c8a05a'
 'neptune_umd_arm64.dll'='b62f463ec4e4bea8ee75b9c6d5ca59d1c9faa9a62273d9fdf7dc75e4f593af36'
 'neptune_umd_ec.dll'='d03a3a342ee0952f3d6315c008970a4507746de295b1891cede56efb567c46f3'
 'neptune_umd_x86.dll'='b1581a53d4db0ce7247180e66017cd84d9a8d17a2767b3a39982012e85d3f9dc'
}
# v0.5 changes monitor-mode admission, not the pinned v0.4 UMD ABI.
# Keep using the exact original wrapper/companions; never copy v0.5 UMDs over
# the qualified video pair. The retained signed v0.4 store is a prerequisite.
if($kernelHash -ine $originals['viogpu3d.sys']){
 $bases=@()
 foreach($candidate in Get-ChildItem (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository') -Directory -Filter 'viogpu3d.inf_arm64_*'){
  $matches=$true
  foreach($name in $originals.Keys){
   $file=Join-Path $candidate.FullName $name
   if(!(Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file).Hash -ine $originals[$name]){$matches=$false;break}
  }
  if($matches){$bases+=$candidate.FullName}
 }
 if(!$bases.Count){throw 'The pinned original v0.4 DriverStore base is required; do not replace the qualified UMDs with v0.5'}
 $driver=@($bases|Sort-Object)[0]
}
foreach($name in $originals.Keys){if((Get-FileHash (Join-Path $driver $name)).Hash -ine $originals[$name]){throw ('Original graphics component differs: '+$name)}}
$dest=Join-Path $env:ProgramFiles ('Perpendicular Graphics\video-'+$ExpectedSHA256.Substring(0,12).ToLowerInvariant())
$wrapper=Join-Path $dest 'neptune_umd.dll';$backup=Join-Path $dest 'before-registry.json'
function UpdatedValue($entry){[string[]]@($entry.Value|ForEach-Object {if($_ -ieq $entry.MatchedWrapper){$wrapper}else{$_}})}
function CheckRegistration($entry){
 $current=@((Get-Item -LiteralPath $entry.Key).GetValue('UserModeDriverName'))
 if(($current -join "`0") -cne ((UpdatedValue $entry) -join "`0")){throw 'Graphics registration changed; preserved'}
}
function WriteRegistrations($entries){
 try {
  foreach($entry in $entries){New-ItemProperty -LiteralPath $entry.Key -Name UserModeDriverName -PropertyType $entry.Kind -Value ([string[]](UpdatedValue $entry)) -Force|Out-Null;CheckRegistration $entry}
 } catch {
  foreach($entry in $entries){New-ItemProperty -LiteralPath $entry.Key -Name UserModeDriverName -PropertyType $entry.Kind -Value ([string[]]$entry.Value) -Force|Out-Null}
  throw
 }
}
if(Test-Path $dest){
 $saved=ConvertFrom-Json ([IO.File]::ReadAllText($backup))
 if($saved.CandidateSHA256 -ine $ExpectedSHA256 -or !$saved.Registry.Count){throw 'Existing graphics backup differs; preserved'}
 foreach($name in 'neptune_umd.dll','neptune_umd_ec.dll','neptune_umd_x86.dll'){
  if((Get-FileHash (Join-Path $dest $name)).Hash -ine $originals[$name]){throw 'Existing graphics wrapper differs; preserved'}
 }
 if((Get-FileHash (Join-Path $dest 'neptune_umd_arm64.dll')).Hash -ine $ExpectedSHA256){throw 'Existing video UMD differs; preserved'}
 $allInstalled=$true;$allRestored=$true
 foreach($entry in $saved.Registry){
  $current=@((Get-Item -LiteralPath $entry.Key).GetValue('UserModeDriverName')) -join "`0"
  $allInstalled=$allInstalled -and ($current -ceq ((UpdatedValue $entry) -join "`0"))
  $allRestored=$allRestored -and ($current -ceq ($entry.Value -join "`0"))
 }
 if(!$allInstalled -and !$allRestored){throw 'Graphics registration changed; preserved'}
 if($Restore){
  foreach($entry in $saved.Registry){New-ItemProperty -LiteralPath $entry.Key -Name UserModeDriverName -PropertyType $entry.Kind -Value ([string[]]$entry.Value) -Force|Out-Null}
  'restored previous video registration';return
 }
 if($allRestored){WriteRegistrations $saved.Registry}
 @{status=$(if($allRestored){'installed'}else{'already-installed'});sha=$ExpectedSHA256;registrations=$saved.Registry.Count;destination=$dest}|ConvertTo-Json -Compress
 return
}
if($Restore){throw 'No video installation to restore'}
$payload=Join-Path $PayloadRoot 'neptune_umd_arm64.dll'
if((Get-FileHash $payload).Hash -ine $ExpectedSHA256){throw 'Video payload differs'}
$info=(Get-Item $payload).VersionInfo
if($info.FileVersion -ne '100.6.101.58000' -or $info.PrivateBuild -ne $ExpectedRevision){throw 'Video ABI or revision differs'}
$pe=[IO.File]::ReadAllBytes($payload);$offset=[BitConverter]::ToInt32($pe,0x3c)
if([BitConverter]::ToUInt16($pe,$offset+4) -ne 0xaa64){throw 'Video payload is not ARM64'}
$originalWrapper=Join-Path $driver 'neptune_umd.dll'
$qaWrapper=Join-Path $env:ProgramFiles ('Perpendicular Video QA\video-'+$ExpectedSHA256.Substring(0,12).ToLowerInvariant()+'\neptune_umd.dll')
# Previously qualified releases can retain either their QA or production path.
# Match only these exact locations and both pinned DLLs; preserve unknown values.
$previousWrappers=@{}
foreach($sha in @(
 '10247abc53060de73374a90b9aaf1fdcd9049d512e9696596335a35436f89b18',
 'b7341859d68a7852c14eceda592f72a84128258930b3372281f0837e76e55680',
 '61deaa5b22ba4e0e67ae3fcf2904eb222566e11c1b83b4a063bbedf002dc0538',
 'aa1a4973446817aeccbc4837e4b6d6e7e642b2cde053623f6626cbda02a4d37b'
)){
 foreach($folder in 'Perpendicular Video QA','Perpendicular Graphics'){
  $path=Join-Path $env:ProgramFiles ($folder+'\video-'+$sha.Substring(0,12)+'\neptune_umd.dll')
  $previousWrappers[$path]=$sha
 }
}
$cls='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}';$entries=@()
foreach($n in (Get-Item $cls).GetSubKeyNames()){
 if($n -notmatch '^\d{4}$'){continue};$key=Get-Item ($cls+'\'+$n);$value=@($key.GetValue('UserModeDriverName',$null))
 $matched=$null
 if(@($value|Where-Object {$_ -ieq $originalWrapper}).Count){$matched=$originalWrapper}
 elseif(@($value|Where-Object {$_ -ieq $qaWrapper}).Count){
  $qa=Split-Path $qaWrapper
  if((Get-FileHash $qaWrapper).Hash -ine $originals['neptune_umd.dll'] -or (Get-FileHash (Join-Path $qa 'neptune_umd_arm64.dll')).Hash -ine $ExpectedSHA256){throw 'Previous QA payload differs; preserved'}
  $matched=$qaWrapper
 }
 else {
  foreach($path in $previousWrappers.Keys){
   if(@($value|Where-Object {$_ -ieq $path}).Count){
    if((Get-FileHash $path).Hash -ine $originals['neptune_umd.dll'] -or (Get-FileHash (Join-Path (Split-Path $path) 'neptune_umd_arm64.dll')).Hash -ine $previousWrappers[$path]){throw 'Previous qualified video payload differs; preserved'}
    $matched=$path;break
   }
  }
 }
 if($matched){$entries+=@{Key=$key.PSPath;Kind=$key.GetValueKind('UserModeDriverName').ToString();Value=$value;MatchedWrapper=$matched}}
}
if(!$entries.Count){throw 'No supported video registration matched; preserved'}
New-Item -ItemType Directory -Path $dest|Out-Null
foreach($name in 'neptune_umd.dll','neptune_umd_ec.dll','neptune_umd_x86.dll'){Copy-Item (Join-Path $driver $name) (Join-Path $dest $name)}
Copy-Item $payload (Join-Path $dest 'neptune_umd_arm64.dll')
if((Get-FileHash (Join-Path $dest 'neptune_umd_arm64.dll')).Hash -ine $ExpectedSHA256){throw 'Copied video UMD differs'}
@{CandidateSHA256=$ExpectedSHA256;Registry=$entries}|ConvertTo-Json -Depth 6|Set-Content $backup -Encoding UTF8
WriteRegistrations $entries
@{status='installed';sha=$ExpectedSHA256;registrations=$entries.Count;destination=$dest}|ConvertTo-Json -Compress
