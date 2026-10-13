@echo off
setlocal
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0src\Start-AndroidPrompt.ps1" %*
exit /b 0
