# Bounded collection of LinkManager's existing local debug page and app events.
# Does not log in, connect a device, change debug levels, or restart components.
[CmdletBinding()]
param([ValidateRange(0,300)][int]$DurationSeconds=0)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root='C:\ProgramData\Perpendicular\LinkManagerArm64-20261028\Diagnostics'
if(!(Test-Path -LiteralPath $root)){New-Item -ItemType Directory -Path $root|Out-Null}
$run=Join-Path $root ('capture-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $run|Out-Null
$encoding=[Text.UTF8Encoding]::new($false)
$since=(Get-Date).AddHours(-2)
$deadline=(Get-Date).AddSeconds($DurationSeconds)
$previous='';$written=0;$failures=0
try {
 do {
  try {
   $r=Invoke-WebRequest -Uri 'http://127.0.0.1:11445/log?log=debug' -UseBasicParsing -TimeoutSec 2
   if($r.RawContentLength -gt 1048576){throw 'Debug response exceeds private capture limit'}
   $hash=[Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($r.Content)))
   if($hash -ne $previous){
    $file=Join-Path $run ('debug-{0:D2}.html' -f ($written % 20))
    [IO.File]::WriteAllText($file,$r.Content,$encoding);$previous=$hash;$written++
   }
  }catch{$failures++}
  if((Get-Date) -lt $deadline){Start-Sleep -Seconds 2}
 }while((Get-Date) -lt $deadline)
}finally {
 $events=@(Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$since;Id=1000,1001} -ErrorAction SilentlyContinue |
  Where-Object {$_.Message -match 'LinkManager|tap0901|lmtap'}|Select-Object TimeCreated,ProviderName,Id,Message)
 $state=[ordered]@{CapturedAtUTC=[DateTime]::UtcNow.ToString('o');DebugSnapshots=$written;EndpointFailures=$failures;
  Client=@(Get-Process LinkManagerTray -ErrorAction SilentlyContinue|Select-Object Id,StartTime,MainWindowTitle);
  Service=@(Get-Service LinkManagerSvc,tap0901 -ErrorAction SilentlyContinue|Select-Object Name,Status);
  ApplicationEvents=$events}
 [IO.File]::WriteAllText((Join-Path $run 'state.json'),($state|ConvertTo-Json -Depth 6),$encoding)
 [pscustomobject]@{OutputDirectory=$run;Snapshots=$written;EndpointFailures=$failures}|ConvertTo-Json -Compress
}
