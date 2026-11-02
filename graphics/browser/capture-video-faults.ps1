# Short, metadata-only trace for the experimental video UMD. Use in QA.
# Start before a fresh Edge GPU process; Stop emits a bounded read-only report.
param([Parameter(Mandatory=$true)][ValidateSet('Start','Stop','Read')][string]$Action,
      [Parameter(Mandatory=$true)][string]$TracePath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$name='PerpendicularVideoQA-FirstFault'
$provider='{48DCE1B6-E965-4E8A-B5FA-D9CB52657212}'
if($Action -eq 'Start'){
 if(Test-Path -LiteralPath $TracePath){throw 'Fresh trace file required'}
 & logman.exe create trace $name -o $TracePath -p $provider 0x1 2 -f bincirc -max 4 -nb 2 4 -bs 64 -ft 1 -ets | Out-Null
 if($LASTEXITCODE -ne 0){throw ('Trace start failed: '+$LASTEXITCODE)}
 @{status='started';session=$name;provider=$provider;path=$TracePath;maxMiB=4}|ConvertTo-Json -Compress
}else{
 if($Action -eq 'Stop'){
  & logman.exe stop $name -ets | Out-Null
  if($LASTEXITCODE -ne 0){throw ('Trace stop failed: '+$LASTEXITCODE)}
 }
 $events=@(Get-WinEvent -Path $TracePath -Oldest -ErrorAction Stop|Where-Object {$_.ProviderId -eq [Guid]$provider})
 $rows=@($events|Select-Object -First 120|ForEach-Object {
  $message=$_.Message
  if(!$message){
   # No installed manifest: this provider writes one UTF-16 EventWriteString.
   [xml]$xml=$_.ToXml();$node=$xml.SelectSingleNode("//*[local-name()='EventPayload']")
   if(!$node){throw 'ETW string payload missing'}
   $hex=$node.InnerText
   if($hex -notmatch '^(?:[0-9a-fA-F]{4})+$' -or $hex.Length -gt 1024){throw 'Unexpected ETW string payload'}
   $bytes=New-Object byte[] ($hex.Length/2)
   for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=[Convert]::ToByte($hex.Substring($i*2,2),16)}
   $message=[Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)
  }
  @{timeUTC=$_.TimeCreated.ToUniversalTime().ToString('o');pid=$_.ProcessId;tid=$_.ThreadId;id=$_.Id;message=$message}
 })
 @{status=$(if($Action -eq 'Stop'){'stopped'}else{'read'});session=$name;path=$TracePath;eventCount=$events.Count;omitted=[Math]::Max(0,$events.Count-120);events=$rows}|ConvertTo-Json -Depth 7 -Compress
}
