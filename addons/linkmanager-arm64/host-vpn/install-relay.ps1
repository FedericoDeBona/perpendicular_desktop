[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Source,
      [string]$Receipt,
      [string]$ExpectedMachineID)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
try {
 if($ExpectedMachineID -and (Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $ExpectedMachineID){throw 'Wrong Windows machine'}
 $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
 if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator authorization required'}
 $d='C:\ProgramData\Perpendicular\HostVPN'
 $pin='fa52dcb75bdc08e864927e260baad31a4d62668f0af40725d7a5e5aac37dfb92'
 if((Get-FileHash -LiteralPath "$Source\sing-box.exe").Hash.ToLowerInvariant() -ne $pin){throw 'Binary pin mismatch'}
 & "$Source\sing-box.exe" check -c "$Source\server.json"
 if($LASTEXITCODE -ne 0){throw 'Server configuration rejected'}
 if(Test-Path "$d\sing-box.exe") {
  if((Get-FileHash "$d\sing-box.exe").Hash.ToLowerInvariant() -ne $pin){throw 'Existing relay has a different binary'}
 }
 $oldTask=Get-ScheduledTask -TaskName 'PerpendicularHostVPN' -ErrorAction SilentlyContinue
 if($oldTask){
  if(@($oldTask.Actions).Count -ne 1 -or $oldTask.Actions[0].Execute -ne "$d\sing-box.exe"){throw 'Existing relay task has changed'}
  Stop-ScheduledTask -TaskName 'PerpendicularHostVPN'
  for($i=0;$i -lt 30 -and (Get-ScheduledTask PerpendicularHostVPN).State -eq 'Running';$i++){Start-Sleep -Milliseconds 100}
  if((Get-ScheduledTask PerpendicularHostVPN).State -eq 'Running'){throw 'Relay has not stopped'}
 }
 New-Item -ItemType Directory -Path $d -Force|Out-Null
 & icacls.exe $d /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
 if($LASTEXITCODE -ne 0){throw 'Private ACL failed'}
 if(Test-Path "$d\server.json"){Copy-Item "$d\server.json" "$d\server.before-install.json" -Force}
 if(!(Test-Path "$d\sing-box.exe")){Copy-Item "$Source\sing-box.exe" "$d\sing-box.exe"}
 Copy-Item "$Source\server.json" "$d\server.json" -Force
 foreach($proto in @('TCP','UDP')){
  # Replace only the two fixed rules owned by this integration.
  Get-NetFirewallRule -Name "PerpendicularHostVPN-$proto" -ErrorAction SilentlyContinue|Remove-NetFirewallRule
  New-NetFirewallRule -Name "PerpendicularHostVPN-$proto" -DisplayName "Perpendicular Host VPN ($proto)" -Direction Inbound -Action Allow -Program "$d\sing-box.exe" -Protocol $proto -LocalAddress '10.0.2.15' -LocalPort 10884 -RemoteAddress '10.0.2.2' -Profile Any | Out-Null
 }
 $a=New-ScheduledTaskAction -Execute "$d\sing-box.exe" -Argument "run -c $d\server.json" -WorkingDirectory $d
 $p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
 Register-ScheduledTask -TaskName 'PerpendicularHostVPN' -Action $a -Principal $p -Force|Out-Null
 Start-ScheduledTask -TaskName 'PerpendicularHostVPN'
 for($i=0;$i -lt 30;$i++){
  if((Get-NetTCPConnection -LocalPort 10884 -State Listen -ErrorAction SilentlyContinue) -and (Get-NetUDPEndpoint -LocalPort 10884 -ErrorAction SilentlyContinue)){break}
  Start-Sleep -Milliseconds 200
 }
 if(!(Get-NetTCPConnection -LocalPort 10884 -State Listen -ErrorAction SilentlyContinue) -or !(Get-NetUDPEndpoint -LocalPort 10884 -ErrorAction SilentlyContinue)){throw 'Relay listener missing'}
 if($Receipt){@{ok=$true;hash=$pin}|ConvertTo-Json|Set-Content -LiteralPath $Receipt -Encoding UTF8}
 'Perpendicular network relay installed.'
} catch {
 if($Receipt){@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json|Set-Content -LiteralPath $Receipt -Encoding UTF8}
 throw
}
