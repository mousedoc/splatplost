@echo off
setlocal

set "INSTALLER=%~dp0install-driver.ps1"
if not exist "%INSTALLER%" (
    echo The Windows Bluetooth installer is missing: "%INSTALLER%"
    exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" %*
exit /b %ERRORLEVEL%
