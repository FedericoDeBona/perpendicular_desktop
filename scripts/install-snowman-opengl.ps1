param(
    [Parameter(Mandatory = $true)][string]$GameDirectory,
    [Parameter(Mandatory = $true)][string]$MesaX86Directory
)

$ErrorActionPreference = 'Stop'
$game = Get-Item -LiteralPath $GameDirectory
$exe = Join-Path $game.FullName 'Snowman.exe'
if (!$game.PSIsContainer -or !(Test-Path -LiteralPath $exe -PathType Leaf) -or
    !(Test-Path -LiteralPath (Join-Path $game.FullName 'lime.ndll') -PathType Leaf)) {
    throw 'Select the local game directory containing Snowman.exe and lime.ndll.'
}

# x86 files from pal1000/mesa-dist-win 25.2.8, release-msvc.
$hashes = [ordered]@{
    'opengl32.dll' = 'ea911706ef8788373e0a5cbbddc3868a1af674510ff0b6f199ad8b7d675eeacd'
    'libgallium_wgl.dll' = 'e288d9fb04c1b04c2a29d1ac744b7932a81a196003863a0e7d829ba82fcc116a'
}
foreach ($name in $hashes.Keys) {
    $source = Join-Path $MesaX86Directory $name
    if ((Get-FileHash -LiteralPath $source).Hash -ine $hashes[$name]) {
        throw "Unexpected Mesa x86 library: $source"
    }
    $destination = Join-Path $game.FullName $name
    if ((Test-Path -LiteralPath $destination) -and
        (Get-FileHash -LiteralPath $destination).Hash -ine $hashes[$name]) {
        throw "Existing library preserved: $destination"
    }
}

$launcherPath = Join-Path $game.FullName 'Start Snowman.cmd'
$launcher = @(
    '@echo off'
    'setlocal'
    'set "GALLIUM_DRIVER=llvmpipe"'
    'set "LIBGL_ALWAYS_SOFTWARE=true"'
    'cd /d "%~dp0" || exit /b 1'
    'start "" "%~dp0Snowman.exe"'
) -join "`r`n"
$launcher += "`r`n"
if ((Test-Path -LiteralPath $launcherPath) -and
    [IO.File]::ReadAllText($launcherPath) -cne $launcher) {
    throw "Existing launcher preserved: $launcherPath"
}

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$shortcutPath = Join-Path $desktop 'A Good Snowman.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcutExists = Test-Path -LiteralPath $shortcutPath
if ($shortcutExists -and ($shortcut.TargetPath -ine $launcherPath -or
    $shortcut.WorkingDirectory -ine $game.FullName -or $shortcut.Arguments)) {
    throw "Existing shortcut preserved: $shortcutPath"
}

foreach ($name in $hashes.Keys) {
    $destination = Join-Path $game.FullName $name
    if (!(Test-Path -LiteralPath $destination)) {
        Copy-Item -LiteralPath (Join-Path $MesaX86Directory $name) -Destination $destination
    }
    if ((Get-FileHash -LiteralPath $destination).Hash -ine $hashes[$name]) {
        throw "Installed library failed verification: $destination"
    }
}
if (!(Test-Path -LiteralPath $launcherPath)) {
    [IO.File]::WriteAllText($launcherPath, $launcher, [Text.Encoding]::ASCII)
}
if (!$shortcutExists) {
    $shortcut.TargetPath = $launcherPath
    $shortcut.WorkingDirectory = $game.FullName
    $shortcut.IconLocation = "$exe,0"
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Avvia A Good Snowman con OpenGL software'
    $shortcut.Save()
}
$shortcutPath
