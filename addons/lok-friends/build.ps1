param(
    [Parameter(Mandatory)][string]$OriginalGame,
    [Parameter(Mandatory)][string]$Cecil,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ChallengeGame,
    [string]$PreviousBuild,
    [string]$SourceDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$originalHash = '9E16B269BEBAFD4AE80BD14054312AC129C288CAF6DFFA9586B81C011F284FDF'
$calendarHash = 'F1328D1F71CC6AEA3183D2D42DD5421355FC6A040F2C0F78EFDCB07999A5F031'
$cecilHash = 'C41BDB9FFD3C5F6E17D2382C1012D73703E035E3F1100245FDD4E08C8DC6EB5B'
$unityHash = 'AD4136D53190FCEB2CDA1D05FCA805A6A3BF2CECD918FF76C7CC8268E1C004F4'
$coreModuleHash = '99E8545D91291EB7444B0D8F8D3567DF2C0A2CBC6CD77271E22A5319CCEB71DC'
$original = Join-Path $OriginalGame 'LOK_Data\Managed'
$originalDll = Join-Path $original 'Assembly-CSharp.dll'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

function Confirm-Hash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw "Unexpected SHA-256 for $Path"
    }
}

Confirm-Hash $originalDll $originalHash
Confirm-Hash (Join-Path $OriginalGame 'UnityPlayer.dll') $unityHash
Confirm-Hash (Join-Path $original 'UnityEngine.CoreModule.dll') $coreModuleHash
Confirm-Hash $Cecil $cecilHash
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Output directory already exists: $OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
Copy-Item -LiteralPath $Cecil -Destination (Join-Path $OutputDirectory 'Mono.Cecil.dll')
$patcher = Join-Path $OutputDirectory 'PatchGame.exe'
$plugin = Join-Path $OutputDirectory 'LokFriends.dll'
$patched = Join-Path $OutputDirectory 'Assembly-CSharp.dll'
$sourceFiles = 'Challenge.cs', 'GlassPuzzle.cs', 'PatchGame.cs'
foreach ($sourceFile in $sourceFiles) {
    Copy-Item -LiteralPath (Join-Path $SourceDirectory $sourceFile) -Destination $OutputDirectory
}

$libraries = 'mscorlib', 'netstandard', 'Assembly-CSharp', 'UnityEngine.CoreModule', 'UnityEngine.IMGUIModule',
    'UnityEngine.UIModule', 'UnityEngine.UI', 'UnityEngine.TextRenderingModule', 'Unity.TextMeshPro'
$references = $libraries | ForEach-Object { '/reference:' + (Join-Path $original "$_.dll") }
& $compiler /nologo /target:library /optimize+ /nostdlib+ "/out:$plugin" @references (Join-Path $OutputDirectory 'Challenge.cs') (Join-Path $OutputDirectory 'GlassPuzzle.cs')
if ($LASTEXITCODE -ne 0) { throw 'Challenge compilation failed' }
& $compiler /nologo /target:exe /optimize+ "/out:$patcher" "/reference:$OutputDirectory\Mono.Cecil.dll" (Join-Path $OutputDirectory 'PatchGame.cs')
if ($LASTEXITCODE -ne 0) { throw 'Patcher compilation failed' }
& $patcher $originalDll $plugin $patched
if ($LASTEXITCODE -ne 0) { throw 'Game patch failed' }

Get-FileHash -LiteralPath $patched, $plugin -Algorithm SHA256
if (!$ChallengeGame) { return }

$managed = Join-Path $ChallengeGame 'LOK_Data\Managed'
Confirm-Hash (Join-Path $ChallengeGame 'UnityPlayer.dll') $unityHash
Confirm-Hash (Join-Path $managed 'UnityEngine.CoreModule.dll') $coreModuleHash
Confirm-Hash (Join-Path $ChallengeGame 'LOK_Data\app.info') '258188B2570F7A8E8AE040468DC83F57B3B3BA479EA824D3B590336E3CBBC81E'
Confirm-Hash (Join-Path $ChallengeGame 'LOK_Data\globalgamemanagers') '56730BB2CC845D813FD69A1ACEE72EF5E89D6834BD919C16A0C3460073885B2E'
$targetDll = Join-Path $managed 'Assembly-CSharp.dll'
$targetPlugin = Join-Path $managed 'LokFriends.dll'
$previousHash = (Get-FileHash -LiteralPath $targetDll).Hash
if ($PreviousBuild) {
    Confirm-Hash $targetDll (Get-FileHash -LiteralPath (Join-Path $PreviousBuild 'Assembly-CSharp.dll')).Hash
    Confirm-Hash $targetPlugin (Get-FileHash -LiteralPath (Join-Path $PreviousBuild 'LokFriends.dll')).Hash
} else {
    if ($previousHash -notin $originalHash, $calendarHash) { throw 'Unexpected starting assembly' }
    if (Test-Path -LiteralPath $targetPlugin) { throw 'Challenge plugin already installed' }
}
$targetExe = Join-Path (Resolve-Path -LiteralPath $ChallengeGame) 'LOK.exe'
if (Get-Process LOK -ErrorAction SilentlyContinue | Where-Object Path -EQ $targetExe) {
    throw 'Close the separate LOK copy before installing.'
}

$stagedDll = Join-Path $managed 'Assembly-CSharp.lokfriends.new'
$stagedPlugin = Join-Path $managed 'LokFriends.new'
$backup = Join-Path $OutputDirectory 'Assembly-CSharp.before-lok-friends.dll'
$backupPlugin = Join-Path $OutputDirectory 'LokFriends.previous.dll'
Copy-Item -LiteralPath $patched -Destination $stagedDll
Copy-Item -LiteralPath $plugin -Destination $stagedPlugin
$pluginInstalled = $false
try {
    if ($PreviousBuild) {
        [IO.File]::Replace($stagedPlugin, $targetPlugin, $backupPlugin)
    } else {
        [IO.File]::Move($stagedPlugin, $targetPlugin)
    }
    $pluginInstalled = $true
    [IO.File]::Replace($stagedDll, $targetDll, $backup)
} catch {
    if ($pluginInstalled) {
        if ($PreviousBuild) {
            Copy-Item -LiteralPath $backupPlugin -Destination $targetPlugin -Force
        } else {
            Remove-Item -LiteralPath $targetPlugin -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $stagedDll, $stagedPlugin -ErrorAction SilentlyContinue
    throw
}
Confirm-Hash $targetDll (Get-FileHash -LiteralPath $patched).Hash
Confirm-Hash $targetPlugin (Get-FileHash -LiteralPath $plugin).Hash
Confirm-Hash $backup $previousHash
Write-Output "Installed in $ChallengeGame. The previous build is backed up in $OutputDirectory."
