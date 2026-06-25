# Installs WatchDogs FIM as a Windows scheduled task.
# Run this script from PowerShell.
# It creates a task that starts the backend/agent automatically when the user logs in.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartupScript = Join-Path $ScriptDir "start_watchdogs_backend.ps1"
$TaskName = "WatchDogs FIM Agent"

if (!(Test-Path $StartupScript)) {
    throw "Startup script not found: $StartupScript"
}

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartupScript`""

$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Description "Starts WatchDogs FIM backend and background monitor at Windows logon." `
    -Force | Out-Null

Write-Host "Scheduled task installed: $TaskName"
Write-Host "The backend/agent will start automatically at the next Windows logon."
Write-Host "To start it now, run: Start-ScheduledTask -TaskName '$TaskName'"
