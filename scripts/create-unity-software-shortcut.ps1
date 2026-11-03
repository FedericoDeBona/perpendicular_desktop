# Temporary per-application workaround, not a replacement graphics driver.
# Unity documents -force-driver-type-warp in PlayerCommandLineArguments.
param([Parameter(Mandatory = $true)][string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$exe = Get-Item -LiteralPath $ExecutablePath
if ($exe.PSIsContainer -or $exe.Extension -ine '.exe' -or
    !(Test-Path -LiteralPath (Join-Path $exe.DirectoryName 'UnityPlayer.dll'))) {
    throw 'Select a Windows Unity player executable beside UnityPlayer.dll.'
}
$linkPath = Join-Path $exe.DirectoryName ($exe.BaseName + ' (compatibilita).lnk')
if (Test-Path -LiteralPath $linkPath) {
    throw "Existing shortcut preserved: $linkPath"
}
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($linkPath)
$link.TargetPath = $exe.FullName
$link.WorkingDirectory = $exe.DirectoryName
$link.Arguments = '-force-d3d11 -force-driver-type-warp -screen-fullscreen 0 -screen-width 1280 -screen-height 720'
$link.Description = 'Temporary Windows software rendering; performance may be lower.'
$link.Save()
# Do not launch the application, change its files, or change global graphics settings.
$linkPath
