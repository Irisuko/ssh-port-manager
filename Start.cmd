@echo off
if exist "%~dp0dist\SshPortManager.exe" (
  start "" "%~dp0dist\SshPortManager.exe"
  exit /b
)
if exist "%~dp0SshPortManager.exe" (
  start "" "%~dp0SshPortManager.exe"
  exit /b
)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0App.ps1"
