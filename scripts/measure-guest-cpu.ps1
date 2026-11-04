param([ValidateRange(5,30)][int]$Seconds=8)
# Read-only, bounded diagnostics for Windows with English performance counters.
# Uses full counter instance paths: InstanceName alone loses #n disambiguation.
# Percentages are of ONE core, including the observer. No privilege changes.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$cores=[Environment]::ProcessorCount
if($cores -gt 64){throw 'This diagnostic does not cover multiple processor groups'}
$paths=@('\Process(*)\% Processor Time','\Process(*)\% Privileged Time',
 '\Process(*)\ID Process','\Process(*)\Elapsed Time',
 '\Processor(_Total)\% Processor Time','\Processor(_Total)\% Privileged Time',
 '\Processor(_Total)\% User Time','\Processor(_Total)\% DPC Time',
 '\Processor(_Total)\% Interrupt Time')
$counterErrors=@()
# A process can exit during collection. Keep valid instances, report provider
# errors and reject missing/invalid required aggregate counters below.
$samples=@(Get-Counter -Counter $paths -SampleInterval $Seconds -MaxSamples 2 -ErrorAction SilentlyContinue -ErrorVariable counterErrors)
if($samples.Count -ne 2){throw 'Incomplete CPU observation'}
$elapsed=($samples[1].Timestamp-$samples[0].Timestamp).TotalSeconds
if($elapsed -le 0){throw 'Invalid CPU accounting interval'}
function Group-Counters($sample) {
 $groups=@{}
 foreach($counter in $sample.CounterSamples){
  $split=$counter.Path.LastIndexOf('\')
  if($split -lt 0){throw 'Unexpected counter path'}
  $key=$counter.Path.Substring(0,$split)
  if(-not $groups.ContainsKey($key)){$groups[$key]=@{}}
  $groups[$key][$counter.Path.Substring($split+1)]=$counter
 }
 return $groups
}
function Value($group,$name) {
 $counter=$group[$name]
 if($null -eq $counter -or $counter.Status -ne 0 -or
    [double]::IsNaN($counter.CookedValue) -or [double]::IsInfinity($counter.CookedValue) -or
    $counter.CookedValue -lt 0){throw "Unavailable CPU counter: $name"}
 return [double]$counter.CookedValue
}
$before=Group-Counters $samples[0];$after=Group-Counters $samples[1]
$rows=@();$excluded=0;$aggregate=$null
foreach($key in $after.Keys){
 $group=$after[$key]
 if($key.EndsWith('\processor(_total)')){$aggregate=$group;continue}
 if(-not $key.Contains('\process(') -or $key.EndsWith('(idle)') -or $key.EndsWith('(_total)')){continue}
 if(-not $before.ContainsKey($key)){$excluded++;continue}
 try {
  $processID=[int](Value $group 'id process')
  # Refuse reordered instances and processes born within the interval.
  if($processID -ne [int](Value $before[$key] 'id process') -or
     (Value $group 'elapsed time') -lt $elapsed){$excluded++;continue}
  $rows+=[pscustomobject]@{pid=$processID;instance=$key.Substring($key.LastIndexOf('\')+1)
   cpuPercentOneCore=(Value $group '% processor time');kernelPercentOneCore=(Value $group '% privileged time')
   observer=($processID -eq $PID)}
 } catch {$excluded++}
}
if($null -eq $aggregate){throw 'Missing processor aggregate'}
[pscustomobject]@{
 version=2;seconds=$elapsed;started=$samples[0].Timestamp.ToUniversalTime().ToString('o')
 finished=$samples[1].Timestamp.ToUniversalTime().ToString('o');cores=$cores
 busyPercentOneCore=$cores*(Value $aggregate '% processor time')
 kernelBusyPercentOneCore=$cores*(Value $aggregate '% privileged time')
 userPercentOneCore=$cores*(Value $aggregate '% user time')
 dpcPercentOneCore=$cores*(Value $aggregate '% dpc time')
 interruptPercentOneCore=$cores*(Value $aggregate '% interrupt time')
 matchedProcesses=$rows.Count;excludedInstances=$excluded;observerIncluded=$true
 providerErrors=$counterErrors.Count
 scope='English counters; instance identity checked at both endpoints; no function stacks'
 processes=@($rows|Sort-Object cpuPercentOneCore -Descending|Select-Object -First 15)
}|ConvertTo-Json -Depth 5 -Compress
