@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Create-AzureSupportRequests.ps1" -SettingsFile "%SCRIPT_DIR%azure-support-settings.txt" %*
