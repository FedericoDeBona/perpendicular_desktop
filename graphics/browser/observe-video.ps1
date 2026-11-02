# Read-only Edge video diagnostics on a selected existing YouTube page.
# Subscribes to Media events and reads playback counters; never navigates,
# changes quality, starts/stops playback, changes browser flags or exports storage.
param([ValidateRange(1,40)][int]$SampleCount=30,
      [ValidateRange(1,65535)][int]$Port=9222)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName System.Net.Http
$script:droppedEvents=0;$script:sequence=0;$script:events=New-Object 'System.Collections.Generic.List[object]'
function OpenWS([string]$url){$ws=New-Object Net.WebSockets.ClientWebSocket;$ws.Options.Proxy=$null;$url=$url.Replace('localhost','127.0.0.1');$ws.ConnectAsync([Uri]$url,[Threading.CancellationToken]::None).GetAwaiter().GetResult()|Out-Null;return $ws}
function ReceiveWS($ws){$buf=New-Object byte[] 65536;$out=New-Object IO.MemoryStream;$cancel=New-Object Threading.CancellationTokenSource(10000);try{do{$part=$ws.ReceiveAsync([ArraySegment[byte]]::new($buf),$cancel.Token).GetAwaiter().GetResult();$out.Write($buf,0,$part.Count)}while(!$part.EndOfMessage);return [Text.Encoding]::UTF8.GetString($out.ToArray())}finally{$cancel.Dispose();$out.Dispose()}}
function Call($ws,[string]$method,$parameters){$script:sequence++;$id=$script:sequence;$body=@{id=$id;method=$method;params=$parameters}|ConvertTo-Json -Depth 10 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($body);$ws.SendAsync([ArraySegment[byte]]::new($bytes),[Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).GetAwaiter().GetResult()|Out-Null;while($true){$reply=ReceiveWS $ws|ConvertFrom-Json;if($reply.id -eq $id){return $reply};if($reply.method -like 'Media.*'){if($script:events.Count -lt 2000){$script:events.Add($reply)}else{$script:droppedEvents++}}}}
$v=Invoke-RestMethod ("http://127.0.0.1:$Port/json/version");$targets=Invoke-RestMethod ("http://127.0.0.1:$Port/json/list");$target=@($targets|Where-Object {$_.type -eq 'page' -and $_.url -like 'https://www.youtube.com/watch*'})[0];if(!$target){throw 'YouTube QA target missing'}
if($v.Browser -notlike 'Edg/*'){throw 'The selected local endpoint is not Edge'}
$clock=[Diagnostics.Stopwatch]::StartNew();$started=[DateTime]::UtcNow.ToString('o');
$browser=OpenWS $v.webSocketDebuggerUrl;$page=OpenWS $target.webSocketDebuggerUrl
$before=Call $browser 'SystemInfo.getInfo' @{};$media=Call $page 'Media.enable' @{};$samples=New-Object 'System.Collections.Generic.List[object]'
$expr="(()=>{const v=document.querySelector('video');if(!v)return null;const q=v.getVideoPlaybackQuality();return {time:v.currentTime,width:v.videoWidth,height:v.videoHeight,paused:v.paused,ready:v.readyState,total:q.totalVideoFrames,dropped:q.droppedVideoFrames,error:v.error?{code:v.error.code,message:v.error.message}:null}})()"
try{for($i=0;$i -lt $SampleCount;$i++){$sample=Call $page 'Runtime.evaluate' @{expression=$expr;returnByValue=$true};$samples.Add(@{elapsedSeconds=$clock.Elapsed.TotalSeconds;value=$sample.result.result.value});Start-Sleep -Milliseconds 1000};$after=Call $browser 'SystemInfo.getInfo' @{};@{startedUTC=$started;durationSeconds=$clock.Elapsed.TotalSeconds;browser=$v.Browser;before=$before.result;after=$after.result;samples=$samples;media=$script:events;droppedMediaEvents=$script:droppedEvents}|ConvertTo-Json -Depth 18 -Compress}finally{$page.Dispose();$browser.Dispose()}
