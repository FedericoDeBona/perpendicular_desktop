# Bounded, metadata-only DWM scheduling trace. Run on the isolated QA.
# No provider settings, task, service, driver or security change persists.
param([Parameter(Mandatory=$true)][string]$TracePath,
      [ValidateRange(2,6)][int]$Seconds=4)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(Test-Path -LiteralPath $TracePath){throw 'Fresh trace file required'}
$parent=Split-Path -Parent $TracePath
if(!(Test-Path -LiteralPath $parent)){throw 'Existing private QA directory required'}
$name='PerpendicularSeamlessDwmQA-'+[Guid]::NewGuid().ToString('N')
$provider=[Guid]'9e9bba3c-2e38-40cb-99f4-9e8281425164'
$started=$false;$stopExit=$null;$startUTC=[DateTime]::UtcNow
$startOutput=@(& logman.exe create trace $name -o $TracePath -p "{$provider}" 0x8b 5 -f bincirc -max 8 -nb 4 16 -bs 64 -ft 1 -ct perf -ets 2>&1)
$startExit=$LASTEXITCODE
if($startExit -ne 0){
 @{status='not-started';exitCode=$startExit;session=$name;output=($startOutput -join "`n")}|ConvertTo-Json -Compress
 exit 1
}
$started=$true
try {
 Start-Sleep -Seconds $Seconds
 $query=@(& logman.exe query $name -ets 2>&1) -join "`n"
} finally {
 if($started){$stopOutput=@(& logman.exe stop $name -ets 2>&1);$stopExit=$LASTEXITCODE}
}
if($stopExit -ne 0){throw ('Own DWM trace did not stop: '+($stopOutput -join "`n"))}
$endUTC=[DateTime]::UtcNow
$events=@(Get-WinEvent -Path $TracePath -Oldest | Where-Object {$_.ProviderId -eq $provider})
$ids=@($events|Group-Object Id|ForEach-Object {@{id=[int]$_.Name;count=$_.Count}})
# Paired scheduling events from the manifest on this Windows build. Thread
# identity keeps independent display/render loops separate. Missing pairs are
# explicitly counted; the ETL remains available for a more specific question.
$begin=@{6='waitVBlank';8='waitWork';10='processFrame';13='render';15='present'}
$finish=@{7=6;9=8;12=10;14=13;16=15}
$pending=@{};$pairs=[Collections.Generic.List[object]]::new();$unmatched=0
foreach($event in $events){
 $id=[int]$event.Id;$thread=$event.ThreadId
 if($begin.ContainsKey($id)){
  $key="$thread`:$id"
  if($pending.ContainsKey($key)){$unmatched++}
  $pending[$key]=$event
 }elseif($finish.ContainsKey($id)){
  $key="$thread`:$($finish[$id])"
  if($pending.ContainsKey($key)){
   $a=$pending[$key];$pending.Remove($key)
   $pairs.Add(@{kind=$begin[$finish[$id]];tid=$thread;pid=$event.ProcessId;
      beginUTC=$a.TimeCreated.ToUniversalTime().ToString('o');
      endUTC=$event.TimeCreated.ToUniversalTime().ToString('o');
      ms=($event.TimeCreated-$a.TimeCreated).TotalMilliseconds})
  }else{$unmatched++}
 }
}
$summary=@($pairs|Group-Object {"$($_.kind):$($_.tid)"}|ForEach-Object {
 $values=@($_.Group.ms|Sort-Object);$n=$values.Count
 @{kind=$_.Group[0].kind;tid=$_.Group[0].tid;count=$n;
   totalMs=($values|Measure-Object -Sum).Sum;minMs=$values[0];
   medianMs=$values[[Math]::Floor(($n-1)*0.5)];p90Ms=$values[[Math]::Floor(($n-1)*0.9)];maxMs=$values[-1]}
})
$report=@{status='stopped';session=$name;provider=$provider;keywords='0x8b';
 startUTC=$startUTC.ToString('o');endUTC=$endUTC.ToString('o');requestedSeconds=$Seconds;
 path=$TracePath;bytes=(Get-Item -LiteralPath $TracePath).Length;
 sha256=(Get-FileHash -LiteralPath $TracePath -Algorithm SHA256).Hash;
 sessionQuery=$query;eventCount=$events.Count;ids=$ids;summary=$summary;
 unmatched=$unmatched;pending=$pending.Count;
 longest=@($pairs|Sort-Object { [double]$_.ms } -Descending|Select-Object -First 32)}|ConvertTo-Json -Depth 7 -Compress
$raw=[Text.Encoding]::UTF8.GetBytes($report);$buffer=[IO.MemoryStream]::new()
try {
 $zip=[IO.Compression.GZipStream]::new($buffer,[IO.Compression.CompressionMode]::Compress,$true)
 try{$zip.Write($raw,0,$raw.Length)}finally{$zip.Dispose()}
 $data=[Convert]::ToBase64String($buffer.ToArray())
}finally{$buffer.Dispose()}
if($data.Length -gt 60000){throw 'DWM report exceeds the control reply limit; ETL retained'}
$hash=[Security.Cryptography.SHA256]::Create()
try{$digest=([BitConverter]::ToString($hash.ComputeHash($raw))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
@{encoding='gzip+base64';bytes=$raw.Length;sha256=$digest;data=$data}|ConvertTo-Json -Compress
