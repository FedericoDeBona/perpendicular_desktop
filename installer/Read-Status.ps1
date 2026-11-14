param([switch]$Final)
$ErrorActionPreference='Stop'
$root=Join-Path $env:ProgramData 'Perpendicular\Setup'
$p=Join-Path $root 'status.json'
if(!(Test-Path $p)){[Console]::WriteLine('{"phase":"installing"}');exit 0}
$v=Get-Content $p -Raw|ConvertFrom-Json
if($Final -and $v.phase -eq 'installed') {
    function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
    function Same([string]$Path,[string]$Expected){if((Hash $Path)-ne$Expected.ToLowerInvariant()){throw ('Installed component differs: '+[IO.Path]::GetFileName($Path))}}
    if((Get-Service PerpendicularRestart).Status-ne'Running'){throw 'Guest service not running'}
    $exe=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\PerpendicularRestart').ImagePath -replace '^"([^"]+)".*$','$1'
    Same $exe (Hash (Join-Path $root 'Guest\perpendicular-guest.exe'))
    if((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State').UEFISecureBootEnabled-ne1){throw 'Secure Boot is not enabled'}
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;public static class FirstRunIntegrity {
 [StructLayout(LayoutKind.Sequential)]struct I{public uint L,O;}
 [DllImport("ntdll.dll")]static extern int NtQuerySystemInformation(int c,ref I i,uint n,out uint r);
 public static uint Read(){var i=new I{L=8};uint n;if(NtQuerySystemInformation(103,ref i,8,out n)!=0)throw new Exception("Code Integrity query");return i.O;}
}
'@
    $ci=[FirstRunIntegrity]::Read();if(($ci-band1)-eq0-or($ci-band2)-ne0){throw 'Code Integrity or test signing differs'}
    $devices=@(Get-PnpDevice -PresentOnly -Class Display)
    if($devices.Count-ne1-or$devices[0].Status-ne'OK'-or$devices[0].InstanceId-notmatch'SUBSYS_1101'){throw 'Primary display is not ready'}
    if((Get-Service VioGpu3D).Status-ne'Running'){throw 'Graphics kernel not running'}
    $connected=Get-Content (Join-Path $root 'Guest\ConnectedDisplay\release.json') -Raw|ConvertFrom-Json
    $kernel=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VioGpu3D').ImagePath -replace '^\\SystemRoot',$env:SystemRoot
    Same $kernel $connected.members.'viogpu3d.sys'
    $video=Get-Content (Join-Path $root 'Guest\VideoGraphics\release.json') -Raw|ConvertFrom-Json
    $videoHash=$video.files.'neptune_umd_arm64.dll'
    $vp=Join-Path $env:ProgramFiles ('Perpendicular Graphics\video-'+$videoHash.Substring(0,12))
    Same (Join-Path $vp 'neptune_umd_arm64.dll') $videoHash
    $x86=Get-Content (Join-Path $root 'Guest\X86Graphics\release.json') -Raw|ConvertFrom-Json
    $xp=Join-Path $env:ProgramFiles ('Perpendicular Graphics QA\x86-'+$x86.files.'neptune_umd_x86.dll'.Substring(0,12)+'\neptune_umd_x86.dll')
    Same $xp $x86.files.'neptune_umd_x86.dll'
    $glRelease=Get-Content (Join-Path $root 'Guest\OpenGL\release.json') -Raw|ConvertFrom-Json
    $gl=Get-Content 'C:\ProgramData\Perpendicular\Graphics\OpenGL\install-state.json' -Raw|ConvertFrom-Json
    if(!$gl.Complete-or$gl.Version-ne$glRelease.version){throw 'OpenGL installation incomplete'}
    foreach($f in $glRelease.files.PSObject.Properties){Same (Join-Path ('C:\ProgramData\Perpendicular\Graphics\OpenGL\'+$gl.Version) $f.Name) $f.Value}
    foreach($f in $gl.AppFiles){Same $f.Path $f.InstalledHash}
    foreach($r in $gl.Registry){if((@((Get-Item $r.Key).GetValue('VulkanDriverName'))-join';')-ne(@($gl.Manifests)-join';')){throw 'Vulkan registration differs'}}
    $class=(Get-PnpDeviceProperty -InstanceId $devices[0].InstanceId -KeyName DEVPKEY_Device_Driver).Data
    $key=Get-Item ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+$class)
    if(@($key.GetValue('UserModeDriverNameWoW'))-inotcontains$xp){throw 'Win32 graphics registration differs'}
    if(@($key.GetValue('UserModeDriverName'))-inotcontains(Join-Path $vp 'neptune_umd.dll')){throw 'Video graphics registration differs'}
    foreach($name in 'Balloon','VioMem'){if((Get-Service $name).Status-ne'Running'){throw ('Memory driver not running: '+$name)}}
    foreach($name in 'configure-shared-folders.ps1','apply-shared-folders.ps1','connect-shared-folders.ps1','retire-shared-files.ps1','configure-smb-cache.ps1'){
        Same (Join-Path 'C:\Program Files\Perpendicular Shared Files' $name) (Hash (Join-Path $root ('Guest\SharedFiles\'+$name)))
    }
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if(!(Get-ScheduledTask -TaskName ('PerpendicularFolders-'+$sid))){throw 'Shared-folder task not ready'}
    if(Get-ScheduledTask -TaskName 'PerpendicularFirstRunComplete' -ErrorAction SilentlyContinue){throw 'Temporary setup task remains'}
    $loaded=@();foreach($process in [Diagnostics.Process]::GetProcessesByName('explorer')){foreach($module in $process.Modules){if($module.ModuleName-ieq'neptune_umd_arm64.dll'){Same $module.FileName $videoHash;$loaded+=@{pid=$process.Id;sha=(Hash $module.FileName)}}}}
    if(!$loaded.Count){throw 'The qualified graphics library is not loaded'}
    $probe=Join-Path $env:ProgramFiles 'Perpendicular OpenGL Check\OpenGLCheck.exe'
    Same $probe (Hash (Join-Path $root 'Probes\arm64\OpenGLCheck.exe'))
    $glOutput=& $probe (Join-Path (Split-Path $probe) 'opengl32.dll') 2>&1
    if($LASTEXITCODE-ne0){throw ('OpenGL startup check failed: '+($glOutput-join' '))}
    $v|Add-Member secureBoot $true
    $v|Add-Member codeIntegrity $ci
    $v|Add-Member loadedVideo $loaded
    $v|Add-Member openGLCheck ($glOutput-join' ')
    $v|Add-Member verified $true
}
$v|ConvertTo-Json -Depth 5 -Compress
