param([ValidatePattern('^[0-9]+:[0-9]+$')][string]$Owner='501:20')
# Installed under protected Program Files. The task accepts only six folder IDs;
# callers cannot supply an executable, path or PowerShell source.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$root=Join-Path $env:ProgramData ('Perpendicular\FolderRequests\'+$sid)
$request=Join-Path $root 'request.json';$response=Join-Path $root 'response.json'
$id=$null
try {
 if((Get-Item -LiteralPath $request).Length -gt 4096){throw 'Folder request too large.'}
 $value=[IO.File]::ReadAllText($request)|ConvertFrom-Json
 $id=([Guid]::Parse($value.id)).ToString()
 $allowed=@('desktop','documents','downloads','pictures','music','videos')
 $enabled=@($value.enabled)
 if($enabled.Count -gt 6 -or @($enabled|Select-Object -Unique).Count -ne $enabled.Count){throw 'Invalid folder selection.'}
 foreach($name in $enabled){if($name -isnot [string] -or $name -cnotin $allowed){throw 'Unknown folder.'}}
 $failed=@()
 foreach($name in $allowed){
  try {
   # Separate processes avoid Add-Type class collisions between folder runs.
   $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'configure-shared-folders.ps1'),'-Folder',$name,'-Owner',$Owner)
   if($name -cnotin $enabled){$arguments+='-Disable'}
   $output=& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments 2>&1
   if($LASTEXITCODE -ne 0){throw ($output|Out-String)}
   $mode=if($name -cin $enabled){'shared'}else{'local'}
   if(($output|Out-String) -notmatch ('PERP_FOLDER_READY:'+$name+':'+$mode)){throw 'Missing mount confirmation.'}
  }catch{$failed+=($name+': '+$_.Exception.Message)}
 }
 if($failed.Count){throw ($failed -join '; ')}
 $result=@{id=$id;ok=$true;enabled=$enabled}
}catch{$result=@{id=$id;ok=$false;error=$_.Exception.Message}}
[IO.File]::WriteAllText($response,($result|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
