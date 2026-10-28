param([switch]$Restore)
# Metadata created/renamed by Mac applications must not remain hidden in the
# Windows redirector's timed caches. Preserve the VM's original settings.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$file=Join-Path $PSScriptRoot 'previous-smb-cache.json';$keys=@('DirectoryCacheLifetime','FileInfoCacheLifetime','FileNotFoundCacheLifetime');$current=Get-SmbClientConfiguration
if($Restore){
 if([IO.File]::Exists($file)){
  $previous=Get-Content $file -Raw|ConvertFrom-Json;$values=@{}
  foreach($key in $keys){if($current.$key -eq 0){$values[$key]=[uint32]$previous.$key}}
  if($values.Count){Set-SmbClientConfiguration @values -Confirm:$false}
  Remove-Item -LiteralPath $file
 }
}else{
 if(![IO.File]::Exists($file)){
  $previous=@{};foreach($key in $keys){$previous[$key]=$current.$key}
  [IO.File]::WriteAllText($file,($previous|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
 }
 if(@($keys|Where-Object {$current.$_ -ne 0}).Count){Set-SmbClientConfiguration -DirectoryCacheLifetime 0 -FileInfoCacheLifetime 0 -FileNotFoundCacheLifetime 0 -Confirm:$false}
}
