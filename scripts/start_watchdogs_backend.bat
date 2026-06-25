@echo off
REM WatchDogs FIM - manual startup helper for Windows.
REM This runs the same PowerShell script used by the scheduled task.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_watchdogs_backend.ps1"
