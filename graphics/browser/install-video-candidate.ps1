# Experimental user-mode registration only. Keep the original kernel,
# DriverStore, WoW registrations and Vulkan/OpenGL registrations intact.
# Use a qualified isolated copy and an exactly paired native runtime first.
param([Parameter(Mandatory=$true)][Guid]$ExpectedMachineID,
      [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedCandidateSHA256,
      [Parameter(Mandatory=$true)][string]$ExpectedCandidateRevision,
      [string]$PayloadRoot=$PSScriptRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if([Guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedMachineID){throw 'Wrong machine'}
if(![Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Normal administrator consent required'}
$driver=Split-Path (Get-CimInstance Win32_SystemDriver -Filter "Name='VioGpu3D'").PathName
$hashes=ConvertFrom-Json -InputObject '{"neptune_umd.dll":"cf7cd403a6b89b519bbffc43c43f42d8da5ba97259fe7b5a6e489628d8c8a05a","neptune_umd_arm64.dll":"b62f463ec4e4bea8ee75b9c6d5ca59d1c9faa9a62273d9fdf7dc75e4f593af36","neptune_umd_ec.dll":"d03a3a342ee0952f3d6315c008970a4507746de295b1891cede56efb567c46f3","neptune_umd_x86.dll":"b1581a53d4db0ce7247180e66017cd84d9a8d17a2767b3a39982012e85d3f9dc","vgpusrv.exe":"a513558b2b9b438880b3a3fc38a1fa0b1a9f471a59408b5c0f80346035bb4781","viogpu3d.cat":"a2060c06f56d06431c71c1c3e4aac06401d70d0c86be76e76ef38727e7e243b0","viogpu3d.inf":"22dca43cb82e02eb1467effa0ea8e3288da0c8a07b99c6e3bd95a79b98f92545","viogpu3d.sys":"cfbc713754c7f0dcae4803017af3a0ebfc781d37fd57604f8ee8f2cfdad306c4","viogpuap.exe":"96650501230dfa97a5320b25346685af50b7c8eb935c566987d4802046ff2adf","virtio_icd.json":"7a215445f88230a5d3d7b44f007bbffdc79f0829d54d4ae72984686faed1ce14","vulkan_virtio.dll":"d4a5f7d6b28b6f1d3faaf70ccbc5cda42bc3340d9d8bd0f89f4e7202e824fd13"}'
foreach($n in 'viogpu3d.sys','neptune_umd.dll','neptune_umd_arm64.dll','neptune_umd_ec.dll','neptune_umd_x86.dll'){if((Get-FileHash (Join-Path $driver $n)).Hash.ToLowerInvariant() -ne $hashes.$n){throw ('Original component differs: '+$n)}}
if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State').UEFISecureBootEnabled -ne 1){throw 'SecureBoot must remain enabled'}
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class VideoCandidateIntegrity {
 [StructLayout(LayoutKind.Sequential)]struct Info{public uint Length,Options;}
 [DllImport("ntdll.dll")]static extern int NtQuerySystemInformation(int c,ref Info i,uint n,out uint r);
 public static bool Protected(){var i=new Info{Length=8};uint n;return NtQuerySystemInformation(103,ref i,8,out n)==0&&(i.Options&1)!=0&&(i.Options&2)==0;}
}
'@
if(![VideoCandidateIntegrity]::Protected()){throw 'Code Integrity must remain enabled and test signing disabled'}
$payload=Join-Path $PayloadRoot 'neptune_umd_arm64.dll'
if((Get-FileHash $payload).Hash.ToLowerInvariant() -ne $ExpectedCandidateSHA256){throw 'Candidate hash differs'}
$info=(Get-Item $payload).VersionInfo
if($info.FileVersion -ne '100.6.101.58000' -or $info.PrivateBuild -ne $ExpectedCandidateRevision){throw 'Candidate ABI or marking differs'}
$dest=Join-Path $env:ProgramFiles ('Perpendicular Video QA\video-'+$ExpectedCandidateSHA256.Substring(0,12).ToLowerInvariant())
if(Test-Path $dest){throw 'Fresh target required'}
$cls='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}';$entries=@()
foreach($n in (Get-Item $cls).GetSubKeyNames()){
 if($n -notmatch '^\d{4}$'){continue};$key=Get-Item ($cls+'\'+$n);$value=$key.GetValue('UserModeDriverName',$null)
 if(!$value){continue};if(@($value|Where-Object {$_ -eq (Join-Path $driver 'neptune_umd.dll')}).Count -eq 0){continue}
 $entries+=@{Key=$key.PSPath;Kind=$key.GetValueKind('UserModeDriverName').ToString();Value=@($value)}
}
if(!$entries.Count){throw 'No original registration matched'}
New-Item -ItemType Directory -Path $dest|Out-Null
foreach($n in 'neptune_umd.dll','neptune_umd_ec.dll','neptune_umd_x86.dll'){Copy-Item (Join-Path $driver $n) (Join-Path $dest $n)}
Copy-Item $payload (Join-Path $dest 'neptune_umd_arm64.dll')
@{Registry=$entries;CandidateSHA256=$ExpectedCandidateSHA256;OriginalDriver=$driver;InstallPath=$dest}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $dest 'before-registry.json') -Encoding UTF8
foreach($entry in $entries){[string[]]$updated=@($entry.Value|ForEach-Object {if($_ -eq (Join-Path $driver 'neptune_umd.dll')){Join-Path $dest 'neptune_umd.dll'}else{$_}});New-ItemProperty -LiteralPath $entry.Key -Name UserModeDriverName -PropertyType $entry.Kind -Value $updated -Force|Out-Null}
@{status='installed';hash=$ExpectedCandidateSHA256;registrations=$entries.Count;destination=$dest;metadata=$info.PrivateBuild}|ConvertTo-Json
