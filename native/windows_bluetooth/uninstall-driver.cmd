@echo off
setlocal

set "UNINSTALLER=%~dp0uninstall-driver.ps1"
if not exist "%UNINSTALLER%" (
    echo The Windows Bluetooth uninstaller is missing: "%UNINSTALLER%"
    exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UNINSTALLER%" %*
exit /b %ERRORLEVEL%
