param(
    [Parameter(Mandatory = $true)][string]$GameDirectory,
    [Parameter(Mandatory = $true)][string]$MagpieArchive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$game = (Get-Item -LiteralPath $GameDirectory).FullName
$exe = Join-Path $game 'Snowman.exe'
$standard = Join-Path $game 'Start Snowman.cmd'
$wide = Join-Path $game 'Start Snowman Wide.cmd'
$magpieVersion = 'Magpie-v0.13.0'
$magpie = Join-Path (Split-Path $game -Parent) $magpieVersion
$profileDir = Join-Path $env:APPDATA 'A Good Snowman Is Hard To Build'
$gameSettings = Join-Path $profileDir 'config.json'
if (!(Test-Path -LiteralPath $exe -PathType Leaf) -or
    !(Test-Path -LiteralPath $standard -PathType Leaf) -or
    !(Test-Path -LiteralPath $gameSettings -PathType Leaf)) {
    throw 'Install the Snowman OpenGL workaround and run the game once before setting up the wide window.'
}
if (Get-Process Snowman,Magpie -ErrorAction SilentlyContinue) {
    throw 'Close Snowman and Magpie before setup.'
}
if ((Get-FileHash -LiteralPath $MagpieArchive).Hash -ine
    '3f1d4f8fade6da13402ac4ea739867d60f0dee50e4c4fa56aab508eab0109551') {
    throw 'Unexpected Magpie v0.13.0 ARM64 archive.'
}

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$linkPath = Join-Path $desktop 'A Good Snowman.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($linkPath)
if (!(Test-Path -LiteralPath $linkPath -PathType Leaf) -or
    @($standard, $wide) -notcontains $link.TargetPath -or
    $link.WorkingDirectory -ine $game -or $link.Arguments) {
    throw 'The Snowman desktop shortcut is missing or points elsewhere.'
}

$launcher = @(
    '@echo off'
    'setlocal'
    ('set "scaler=%~dp0..\' + $magpieVersion + '"')
    'if not exist "%scaler%\Magpie.exe" goto play'
    'tasklist /fi "imagename eq Magpie.exe" /nh | findstr /i /b "Magpie.exe" >nul'
    'if errorlevel 1 start "" /d "%scaler%" "%scaler%\Magpie.exe" -t'
    ':play'
    'call "%~dp0Start Snowman.cmd"'
) -join "`r`n"
$launcher += "`r`n"
if ((Test-Path -LiteralPath $wide) -and [IO.File]::ReadAllText($wide) -cne $launcher) {
    throw "Existing launcher preserved: $wide"
}

# Check the executable, UI runtime and effect from the pinned ARM64 release.
$payloadHashes = @{
    'Magpie.exe' = '62f584f0668ddbafdd3ead3ea28bdcd8d43ffbf833e549acd0009886011900de'
    'Microsoft.UI.Xaml.dll' = 'e7bac1376c19dc6a47922c9eb6ff514ed5ef5cd17c5d929b1ac85f8cd0a44c50'
    'resources.pri' = '2d9cedfb71512c14c93bf8e6d71556ba9131f0631c6a9a93c90b14d532410362'
    'effects\Lanczos.hlsl' = '396828b2a4aa90a5b397092651a946032042721e0c8fd96ff1825063c35fb4a8'
}
$unpack = $magpie
if (!(Test-Path -LiteralPath $magpie)) {
    $unpack = $magpie + '.staged-' + [Guid]::NewGuid().ToString('N')
    Expand-Archive -LiteralPath $MagpieArchive -DestinationPath $unpack
}
foreach ($file in $payloadHashes.Keys) {
    $path = Join-Path $unpack $file
    if ((Get-FileHash -LiteralPath $path).Hash -ine $payloadHashes[$file]) {
        throw "Unexpected Magpie component: $path"
    }
}
if ($unpack -ne $magpie) { Move-Item -LiteralPath $unpack -Destination $magpie }

$settings = Join-Path $magpie 'config\config.json'
if (Test-Path -LiteralPath $settings) {
    $existing = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
    if (@($existing.profiles).Count -ne 2 -or
        $existing.profiles[1].pathRule -ine $exe -or
        $existing.profiles[1].classNameRule -cne 'SDL_app') {
        throw "Existing Magpie configuration preserved: $settings"
    }
}
# Magpie 0.13.0 profile enums: Windowed=2, GraphicsCapture=0, Custom scale=6.
$profile = @{
    name = 'A Good Snowman'; packaged = $false; pathRule = $exe; classNameRule = 'SDL_app'
    autoScale = 2; scalingMode = 0; captureMethod = 0
    initialWindowedScaleFactor = 6; customInitialWindowedScaleFactor = 3.05
}
$magpieSettings = @{
    autoCheckForUpdates = $false; showNotifyIcon = $true
    scalingModes = @(@{name = 'Lanczos'; effects = @(@{name = 'Lanczos'; scalingType = 1})})
    profiles = @(@{}, $profile)
}
New-Item -ItemType Directory -Path (Split-Path $settings) -Force | Out-Null
[IO.File]::WriteAllText($settings, ($magpieSettings | ConvertTo-Json -Depth 8))

$config = Get-Content -LiteralPath $gameSettings -Raw | ConvertFrom-Json
if ($config.fullscreen -ne $false -or $config.windowWidth -ne 896 -or $config.windowHeight -ne 520) {
    $config.fullscreen = $false
    $config.windowWidth = 896
    $config.windowHeight = 520
    $pending = $gameSettings + '.staged-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($pending, ($config | ConvertTo-Json -Depth 8))
    [IO.File]::Replace($pending, $gameSettings, ($pending + '.bak'))
}
if (!(Test-Path -LiteralPath $wide)) {
    [IO.File]::WriteAllText($wide, $launcher, [Text.Encoding]::ASCII)
}
$link.TargetPath = $wide
$link.Description = 'Avvia A Good Snowman in finestra larga'
$link.Save()
$linkPath
