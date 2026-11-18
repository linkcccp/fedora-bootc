@echo off
setlocal
if not exist "%~dp0download-iso.ps1" (
    echo Downloading download-iso.ps1...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/linkcccp/fedora-bootc/releases/latest/download/download-iso.ps1' -OutFile '%~dp0download-iso.ps1'"
    if errorlevel 1 (
        echo Failed to download download-iso.ps1
        pause
        exit /b 1
    )
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-iso.ps1" %*
if errorlevel 1 pause
endlocal
