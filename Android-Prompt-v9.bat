@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\Start-AndroidPrompt.ps1" %*
exit /b %errorlevel%
