@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Get-PerpendicularGuestToolsDiagnostics.ps1"
echo.
pause
exit /b %errorlevel%
