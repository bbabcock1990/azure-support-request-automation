@echo off
REM Double-click launcher for the drag-and-drop MSX ingestion UI.
REM WinForms requires single-threaded apartment (STA), so launch PowerShell with -STA.
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%HERE%Ingest-DropUI.ps1"
