param(
    [Parameter(Mandatory=$true)][Guid]$ExpectedMachineID,
    [string]$PayloadRoot=$PSScriptRoot,
    [string]$ApplicationExecutable,
    [switch]$Restore
)
$ErrorActionPreference='Stop'
if ([Guid](Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedMachineID) { throw 'Wrong Windows machine' }
$root=Join-Path $env:ProgramData 'Perpendicular\Graphics\OpenGL'
$statePath=Join-Path $root 'install-state.json'
function FileHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Restore-State($State) {
    foreach ($entry in $State.Registry) {
        $now=(Get-Item -LiteralPath $entry.Key).GetValue('VulkanDriverName')
        $before=$entry.Value
        if (($now -join "`n") -eq (@($State.Manifests) -join "`n")) {
            New-ItemProperty -LiteralPath $entry.Key -Name VulkanDriverName -PropertyType $entry.Kind -Value $(if($entry.Kind -eq 'String'){[string]$before}else{[string[]]$before}) -Force|Out-Null
        } elseif (($now -join "`n") -ne ($before -join "`n")) {
            throw ('Vulkan registration changed outside this installation: '+$entry.Key)
        }
    }
    foreach ($entry in $State.AppFiles) {
        if (Test-Path -LiteralPath $entry.Path) {
            if ((FileHash $entry.Path) -eq $entry.InstalledHash) {
                if ($entry.Existed) { Copy-Item -LiteralPath $entry.Backup -Destination $entry.Path -Force }
                else { Remove-Item -LiteralPath $entry.Path -Force }
            } elseif (!$entry.Existed -or (FileHash $entry.Path) -ne $entry.OriginalHash) {
                throw ('OpenGL application library changed outside this installation: '+$entry.Path)
            }
        } elseif ($entry.Existed) { Copy-Item -LiteralPath $entry.Backup -Destination $entry.Path }
    }
}
if ($Restore) {
    $state=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $statePath -Raw)
    if ([Guid]$state.MachineID -ne $ExpectedMachineID) { throw 'Backup belongs to another machine' }
    if (Get-Process|Where-Object {$_.Path -eq $state.ApplicationExecutable}) { throw 'Close the application before restoring OpenGL' }
    Restore-State $state
    Move-Item -LiteralPath $statePath -Destination (Join-Path $root ('restored-'+(Get-Date -Format yyyyMMddTHHmmss)+'.json'))
    'Original Vulkan registrations and application libraries restored'
    return
}
if (Test-Path -LiteralPath $statePath) { throw 'An OpenGL installation state already exists; restore or qualify an update first' }
if (!(Test-Path -LiteralPath $ApplicationExecutable -PathType Leaf)) { throw 'Application executable is missing' }
if (Get-Process|Where-Object {$_.Path -eq $ApplicationExecutable}) { throw 'Close the application before installing OpenGL' }
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State').UEFISecureBootEnabled -ne 1) { throw 'Secure Boot must remain enabled' }
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class OpenGLIntegrity {
 [StructLayout(LayoutKind.Sequential)]struct Info{public uint Length,Options;}
 [DllImport("ntdll.dll")]static extern int NtQuerySystemInformation(int c,ref Info i,uint n,out uint r);
 public static bool Protected(){var i=new Info{Length=8};uint n;return NtQuerySystemInformation(103,ref i,8,out n)==0&&(i.Options&1)!=0&&(i.Options&2)==0;}
}
'@
if (![OpenGLIntegrity]::Protected()) { throw 'Code Integrity must be enabled with test signing disabled' }
$release=ConvertFrom-Json -InputObject (Get-Content (Join-Path $PayloadRoot 'release.json') -Raw)
if ($release.schema -ne 1 -or $release.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid OpenGL release manifest' }
foreach ($entry in $release.files.PSObject.Properties) {
    if ($entry.Name -notmatch '^(arm64|x64)/(opengl32|libgallium_wgl|vulkan_virtio)\.dll$') { throw 'Unexpected library path' }
    if ((FileHash (Join-Path $PayloadRoot $entry.Name)) -ne $entry.Value) { throw ('OpenGL payload hash mismatch: '+$entry.Name) }
}
if (@($release.files.PSObject.Properties).Count -ne 6) { throw 'Incomplete OpenGL payload' }
$bytes=[IO.File]::ReadAllBytes($ApplicationExecutable)
$machine=[BitConverter]::ToUInt16($bytes,[BitConverter]::ToInt32($bytes,0x3c)+4)
$arch=switch($machine){0xaa64{'arm64'};0x8664{'x64'};default{throw 'Only ARM64 and x64 applications are qualified'}}
$class='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$registrations=@()
foreach ($subkey in (Get-Item -LiteralPath $class).GetSubKeyNames()) {
    if ($subkey -notmatch '^\d{4}$') { continue }
    $key=Get-Item -LiteralPath ($class+'\'+$subkey)
    $value=$key.GetValue('VulkanDriverName',$null)
    if ($null -eq $value) { continue }
    $values=@($value)
    if ($values.Count -ne 1 -or [IO.Path]::GetFileName($values[0]) -ne 'virtio_icd.json') { continue }
    $driver=Split-Path $values[0]
    if ($driver -notlike ($env:WINDIR+'\System32\DriverStore\FileRepository\viogpu3d.inf_arm64_*')) { continue }
    if ((FileHash (Join-Path $driver 'viogpu3d.sys')) -ne 'cfbc713754c7f0dcae4803017af3a0ebfc781d37fd57604f8ee8f2cfdad306c4' -or
        (FileHash (Join-Path $driver 'vulkan_virtio.dll')) -ne 'd4a5f7d6b28b6f1d3faaf70ccbc5cda42bc3340d9d8bd0f89f4e7202e824fd13') { throw 'The installed signed graphics package differs from the qualified driver' }
    $registrations += [PSCustomObject]@{Key=$key.PSPath;Kind=$key.GetValueKind('VulkanDriverName').ToString();Value=[string]$values[0]}
}
if (!$registrations.Count) { throw 'Qualified VirtIO Vulkan registration not found' }
New-Item -ItemType Directory -Path $root -Force|Out-Null
# Elevated loaders read these manifests. Keep their files writable only by the
# administrators and SYSTEM, while ordinary applications retain read access.
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
$acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
foreach($sid in 'S-1-5-18','S-1-5-32-544','S-1-5-32-545') {
    $rights=if($sid -eq 'S-1-5-32-545'){'ReadAndExecute'}else{'FullControl'}
    $rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),$rights,'ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $root -AclObject $acl
$version=Join-Path $root $release.version
if(Test-Path $version) {
    foreach($entry in $release.files.PSObject.Properties) {
        if((FileHash (Join-Path $version $entry.Name)) -ne $entry.Value){throw 'Existing release directory differs from the pinned payload'}
    }
} else { New-Item -ItemType Directory -Path $version|Out-Null }
$manifests=@()
foreach($cpu in 'arm64','x64') {
    $target=Join-Path $version $cpu
    New-Item -ItemType Directory -Path $target -Force|Out-Null
    foreach($name in 'opengl32.dll','libgallium_wgl.dll','vulkan_virtio.dll') {
        $file=Join-Path $target $name
        if(!(Test-Path -LiteralPath $file)){Copy-Item -LiteralPath (Join-Path $PayloadRoot ($cpu+'/'+$name)) -Destination $target}
    }
    $manifest=Join-Path $target 'virtio_icd.json'
    @{file_format_version='1.0.1';ICD=@{library_path=(Join-Path $target 'vulkan_virtio.dll');api_version='1.4.340';library_arch='64'}}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $manifest -Encoding ASCII
    $manifests += $manifest
}
$backup=Join-Path $root ('backup-'+(Get-Date -Format yyyyMMddTHHmmss))
New-Item -ItemType Directory -Path $backup|Out-Null
$appFiles=@();$appDir=Split-Path $ApplicationExecutable
foreach($name in 'opengl32.dll','libgallium_wgl.dll') {
    $path=Join-Path $appDir $name;$exists=Test-Path -LiteralPath $path;$original=$null
    if($exists){$original=FileHash $path;Copy-Item -LiteralPath $path -Destination (Join-Path $backup $name)}
    $appFiles += [PSCustomObject]@{Path=$path;Existed=$exists;OriginalHash=$original;Backup=(Join-Path $backup $name);InstalledHash=$release.files.PSObject.Properties[($arch+'/'+$name)].Value}
}
$state=[PSCustomObject]@{Schema=1;Version=$release.version;MachineID=$ExpectedMachineID.ToString();Registry=$registrations;Manifests=$manifests;ApplicationExecutable=$ApplicationExecutable;Architecture=$arch;AppFiles=$appFiles;Complete=$false}
$state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $statePath -Encoding UTF8
try {
    foreach($entry in $appFiles) {
        Copy-Item -LiteralPath (Join-Path $version ($arch+'/'+[IO.Path]::GetFileName($entry.Path))) -Destination $entry.Path -Force
        (Get-Item -LiteralPath $entry.Path).IsReadOnly=$false
        if((FileHash $entry.Path) -ne $entry.InstalledHash){throw 'Application library copy mismatch'}
    }
    foreach($entry in $registrations) {New-ItemProperty -LiteralPath $entry.Key -Name VulkanDriverName -PropertyType MultiString -Value ([string[]]$manifests) -Force|Out-Null}
    $state.Complete=$true;$state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $statePath -Encoding UTF8
} catch {
    Restore-State $state
    throw
}
'OpenGL '+$release.version+' installed for '+$arch+' application; dual-architecture Vulkan registrations='+$registrations.Count
'Secure Boot and Code Integrity preserved; kernel and DriverStore unchanged'
