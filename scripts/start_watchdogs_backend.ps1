# WatchDogs FIM - Backend/Agent startup script
# This script is intended to be launched by Windows Task Scheduler at user logon.
# It starts PostgreSQL with Docker Compose and then starts the FastAPI backend.
# The FIM monitor runs inside the backend in background mode.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$BackendDir = Join-Path $ProjectRoot "backend"
$LogsDir = Join-Path $ProjectRoot "logs"
$LogFile = Join-Path $LogsDir "watchdogs_backend.log"

if (!(Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir | Out-Null
}

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

Write-Log "Starting WatchDogs FIM backend startup script."

Set-Location $ProjectRoot

# Start PostgreSQL container if Docker Desktop is available.
try {
    Write-Log "Starting docker compose services..."
    docker compose up -d | Out-File -FilePath $LogFile -Append -Encoding utf8
} catch {
    Write-Log "WARNING: Could not start Docker Compose automatically. Make sure Docker Desktop is running. Error: $($_.Exception.Message)"
}

Set-Location $BackendDir

# Create .env from .env.example if it does not exist.
if (!(Test-Path ".env") -and (Test-Path ".env.example")) {
    Copy-Item ".env.example" ".env"
    Write-Log "Created backend .env from .env.example."
}

# Create virtual environment if missing.
if (!(Test-Path ".venv\Scripts\python.exe")) {
    Write-Log "Creating Python virtual environment..."
    python -m venv .venv
}

$PythonExe = Join-Path $BackendDir ".venv\Scripts\python.exe"

# Install dependencies only if FastAPI is not available.
try {
    & $PythonExe -c "import fastapi" 2>$null
    Write-Log "Python dependencies already available."
} catch {
    Write-Log "Installing Python dependencies..."
    & $PythonExe -m pip install -r requirements.txt | Out-File -FilePath $LogFile -Append -Encoding utf8
}

Write-Log "Launching uvicorn backend. The monitor starts inside FastAPI."
& $PythonExe -m uvicorn app.main:app --host 127.0.0.1 --port 8000 | Out-File -FilePath $LogFile -Append -Encoding utf8
