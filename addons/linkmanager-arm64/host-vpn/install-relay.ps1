[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Source)
$ErrorActionPreference='Stop'
$d='C:\ProgramData\Perpendicular\HostVPN'
if(Test-Path -LiteralPath $d){throw 'Existing HostVPN directory'}
New-Item -ItemType Directory -Path $d|Out-Null
& icacls.exe $d /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE -ne 0){throw 'Private ACL failed'}
$s=$Source
Copy-Item -LiteralPath "$s\sing-box.exe","$s\server.json" -Destination $d
if((Get-FileHash -LiteralPath "$d\sing-box.exe").Hash -ne 'fa52dcb75bdc08e864927e260baad31a4d62668f0af40725d7a5e5aac37dfb92'){throw 'Binary pin mismatch'}
& "$d\sing-box.exe" check -c "$d\server.json"
if($LASTEXITCODE -ne 0){throw 'Server configuration rejected'}
foreach($proto in @('TCP','UDP')){
 New-NetFirewallRule -Name "PerpendicularHostVPN-$proto" -DisplayName "Perpendicular Host VPN ($proto)" -Direction Inbound -Action Allow -Program "$d\sing-box.exe" -Protocol $proto -LocalAddress '10.0.2.15' -LocalPort 10884 -RemoteAddress '10.0.2.2' -Profile Any | Out-Null
}
$a=New-ScheduledTaskAction -Execute "$d\sing-box.exe" -Argument "run -c $d\server.json" -WorkingDirectory $d
$p=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'PerpendicularHostVPN' -Action $a -Principal $p|Out-Null
Start-ScheduledTask -TaskName 'PerpendicularHostVPN'
Start-Sleep -Seconds 2
Get-NetTCPConnection -LocalPort 10884 -State Listen|Select LocalAddress,LocalPort,OwningProcess|ConvertTo-Json
Get-NetUDPEndpoint -LocalPort 10884|Select LocalAddress,LocalPort,OwningProcess|ConvertTo-Json
