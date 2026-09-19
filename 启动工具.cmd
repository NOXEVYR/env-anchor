@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0EnvAnchor.ps1"
if errorlevel 1 pause
