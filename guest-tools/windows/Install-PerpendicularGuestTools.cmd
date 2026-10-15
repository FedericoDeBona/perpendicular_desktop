@echo off
setlocal DisableDelayedExpansion
if not exist "%~dp0Install-PerpendicularGuestTools.ps1" (
  echo The Perpendicular Guest Tools disc is incomplete.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Install-PerpendicularGuestTools.ps1"
exit /b %errorlevel%
