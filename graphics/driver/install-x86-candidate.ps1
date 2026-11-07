# Private Win32 UMD registration. No kernel/DriverStore/ARM64/OpenGL changes.
param([Parameter(Mandatory=$true)][Guid]$ExpectedMachineID,
      [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256,
      [string]$PayloadRoot=$PSScriptRoot,
      [switch]$Restore)
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
if([Guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedMachineID){throw 'Wrong machine'}
if(![Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Normal administrator consent required'}
if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State').UEFISecureBootEnabled -ne 1){throw 'Secure Boot must remain enabled'}
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class X86CandidateIntegrity {
 [StructLayout(LayoutKind.Sequential)]struct Info{public uint Length,Options;}
 [DllImport("ntdll.dll")]static extern int NtQuerySystemInformation(int c,ref Info i,uint n,out uint r);
 public static bool Protected(){var i=new Info{Length=8};uint n;return NtQuerySystemInformation(103,ref i,8,out n)==0&&(i.Options&1)!=0&&(i.Options&2)==0;}
}
'@
if(![X86CandidateIntegrity]::Protected()){throw 'Code Integrity must remain enabled and test signing disabled'}
$kernelPath=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VioGpu3D').ImagePath -replace '^\\SystemRoot',$env:SystemRoot
$kernelHash=(Get-FileHash -LiteralPath $kernelPath).Hash
if($kernelHash -inotmatch '^(cfbc713754c7f0dcae4803017af3a0ebfc781d37fd57604f8ee8f2cfdad306c4|642f2d861124639059469722c165fb9a640eed0dad97d30e59e5a42b88d4b1d6)$'){throw 'Unsupported signed graphics kernel; preserve current registration'}
$driver=Split-Path $kernelPath
if($kernelHash -ine 'cfbc713754c7f0dcae4803017af3a0ebfc781d37fd57604f8ee8f2cfdad306c4'){
 $bases=@()
 foreach($candidate in Get-ChildItem (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository') -Directory -Filter 'viogpu3d.inf_arm64_*'){
  $sys=Join-Path $candidate.FullName 'viogpu3d.sys';$umd=Join-Path $candidate.FullName 'neptune_umd_x86.dll'
  if((Test-Path $sys) -and (Test-Path $umd) -and
     (Get-FileHash $sys).Hash -ieq 'cfbc713754c7f0dcae4803017af3a0ebfc781d37fd57604f8ee8f2cfdad306c4' -and
     (Get-FileHash $umd).Hash -ieq 'b1581a53d4db0ce7247180e66017cd84d9a8d17a2767b3a39982012e85d3f9dc'){$bases+=$candidate.FullName}
 }
 if(!$bases.Count){throw 'The pinned original v0.4 DriverStore base is required'}
 $driver=@($bases|Sort-Object)[0]
}
$original=Join-Path $driver 'neptune_umd_x86.dll'
if((Get-FileHash $original).Hash -ine 'b1581a53d4db0ce7247180e66017cd84d9a8d17a2767b3a39982012e85d3f9dc'){throw 'Original Win32 UMD differs'}
$dest=Join-Path $env:ProgramFiles ('Perpendicular Graphics QA\x86-'+$ExpectedSHA256.Substring(0,12).ToLowerInvariant())
$installed=Join-Path $dest 'neptune_umd_x86.dll';$backup=Join-Path $dest 'before-registry.json'
if($Restore){
 $saved=ConvertFrom-Json ([IO.File]::ReadAllText($backup))
 if($saved.CandidateSHA256 -ine $ExpectedSHA256){throw 'Backup differs'}
 foreach($entry in $saved.Registry){
  $current=@((Get-Item -LiteralPath $entry.Key).GetValue('UserModeDriverNameWoW'))
  $expected=@($entry.Value|ForEach-Object {if($_ -ieq $original){$installed}else{$_}})
  if(($current -join "`0") -cne ($expected -join "`0")){throw 'Registration changed; preserved'}
 }
 foreach($entry in $saved.Registry){New-ItemProperty -LiteralPath $entry.Key -Name UserModeDriverNameWoW -PropertyType $entry.Kind -Value ([string[]]$entry.Value) -Force|Out-Null}
 'restored original Win32 registration';return
}
$payload=Join-Path $PayloadRoot 'neptune_umd_x86.dll'
if((Get-FileHash $payload).Hash -ine $ExpectedSHA256){throw 'Candidate differs'}
if((Get-Item $payload).VersionInfo.FileVersion -ne '100.6.101.58000'){throw 'Candidate ABI differs'}
$pe=[IO.File]::ReadAllBytes($payload);$offset=[BitConverter]::ToInt32($pe,0x3c)
if([BitConverter]::ToUInt16($pe,$offset+4) -ne 0x14c){throw 'Candidate is not Win32'}
if(Test-Path -LiteralPath $dest){
 if((Get-FileHash -LiteralPath $installed).Hash -ine $ExpectedSHA256){throw 'Existing candidate differs; preserved'}
 $saved=ConvertFrom-Json ([IO.File]::ReadAllText($backup))
 if($saved.CandidateSHA256 -ine $ExpectedSHA256 -or !$saved.Registry.Count){throw 'Existing backup differs; preserved'}
 foreach($entry in $saved.Registry){
  $expected=@($entry.Value|ForEach-Object {if($_ -ieq $original){$installed}else{$_}})
  $current=@((Get-Item -LiteralPath $entry.Key).GetValue('UserModeDriverNameWoW'))
  if(($current -join "`0") -cne ($expected -join "`0")){throw 'Registration changed; preserved'}
 }
 @{status='already-installed';sha=$ExpectedSHA256;registrations=$saved.Registry.Count;destination=$dest}|ConvertTo-Json -Compress
 return
}
$cls='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}';$entries=@()
foreach($n in (Get-Item $cls).GetSubKeyNames()){
 if($n -notmatch '^\d{4}$'){continue};$key=Get-Item ($cls+'\'+$n);$value=$key.GetValue('UserModeDriverNameWoW',$null)
 if(@($value|Where-Object {$_ -ieq $original}).Count -eq 0){continue}
 $entries+=@{Key=$key.PSPath;Kind=$key.GetValueKind('UserModeDriverNameWoW').ToString();Value=@($value)}
}
if(!$entries.Count){throw 'No original Win32 registration matched'}
New-Item -ItemType Directory -Path $dest|Out-Null
Copy-Item -LiteralPath $payload -Destination $installed
if((Get-FileHash $installed).Hash -ine $ExpectedSHA256){throw 'Installed copy differs'}
@{CandidateSHA256=$ExpectedSHA256;Registry=$entries}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $backup -Encoding UTF8
try{
 foreach($entry in $entries){
  [string[]]$updated=@($entry.Value|ForEach-Object {if($_ -ieq $original){$installed}else{$_}})
  New-ItemProperty -LiteralPath $entry.Key -Name UserModeDriverNameWoW -PropertyType $entry.Kind -Value $updated -Force|Out-Null
  if((@((Get-Item -LiteralPath $entry.Key).GetValue('UserModeDriverNameWoW')) -join "`0") -cne ($updated -join "`0")){throw 'Registration readback differs'}
 }
}catch{
 foreach($entry in $entries){New-ItemProperty -LiteralPath $entry.Key -Name UserModeDriverNameWoW -PropertyType $entry.Kind -Value ([string[]]$entry.Value) -Force|Out-Null}
 throw
}
@{status='installed';sha=$ExpectedSHA256;registrations=$entries.Count;destination=$dest}|ConvertTo-Json -Compress
