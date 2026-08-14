param(
    [string]$EnvironmentName = "Experimento MTTR Piloto",
    [string]$TestFile = "C:\watchdogs_experimento_mttr\mttr_pilot.txt",
    [string]$ApiBase = "http://127.0.0.1:8000/api/v1",
    [int]$DetectionTimeoutSeconds = 30,
    [int]$ReviewTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-ApiItems {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $response = Invoke-RestMethod -Method Get -Uri $Uri
    if ($null -eq $response) { return @() }

    $items = New-Object System.Collections.Generic.List[object]
    if ($response -is [System.Array]) {
        foreach ($item in $response) { $items.Add($item) }
    }
    elseif (($response.PSObject.Properties.Name -contains "value") -and ($response.value -is [System.Array])) {
        foreach ($item in $response.value) { $items.Add($item) }
    }
    else {
        $items.Add($response)
    }
    return $items.ToArray()
}

$root = Split-Path -Parent $PSScriptRoot
$evidenceDir = Join-Path $root "evidencias\pilot\mttr"
$evidencePath = Join-Path $evidenceDir "MTTR-PILOT-ASSISTED.json"
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

if (Test-Path -LiteralPath $evidencePath) {
    throw "Ya existe $evidencePath. No se repite el piloto sobre la misma evidencia."
}

$agent = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
if (-not $agent.running) {
    throw "El agente FIM no está activo."
}

$environment = @(Get-ApiItems -Uri "$ApiBase/environments") |
    Where-Object { $_.name -eq $EnvironmentName -and $_.enabled -eq $true } |
    Select-Object -First 1

if (-not $environment) {
    throw "No existe un entorno activo llamado '$EnvironmentName'."
}

$fullPath = [System.IO.Path]::GetFullPath($TestFile)

if (-not (Test-Path -LiteralPath $fullPath)) {
    throw "No existe el archivo piloto: $fullPath"
}

$baselineRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
$baseline = $baselineRows |
    Where-Object {
        try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullPath }
        catch { $false }
    } |
    Select-Object -First 1

if (-not $baseline -or $baseline.baseline_approved -ne $true) {
    throw "El archivo piloto no tiene una baseline aprobada."
}

$baselineSha = [string]$baseline.sha256

$existing = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
$pendingExisting = @($existing | Where-Object { $_.review_status -eq "PENDING" })
if ($pendingExisting.Count -gt 0) {
    throw "El entorno ya tiene $($pendingExisting.Count) evento(s) PENDING. Revise esos eventos antes del piloto."
}

$previousMaxId = 0
foreach ($item in $existing) {
    try {
        $candidatePath = [System.IO.Path]::GetFullPath([string]$item.path)
        if (($candidatePath -ieq $fullPath) -and ([int]$item.id -gt $previousMaxId)) {
            $previousMaxId = [int]$item.id
        }
    }
    catch {}
}

Write-Host "Generando un MODIFIED piloto..."
$actionStartedAt = [DateTimeOffset]::UtcNow
Add-Content -LiteralPath $fullPath `
    -Value "`nWatchDogs FIM - MTTR piloto asistido - $($actionStartedAt.ToString('o'))" `
    -Encoding UTF8
$occurredAt = [DateTimeOffset]::UtcNow

$deadline = (Get-Date).AddSeconds($DetectionTimeoutSeconds)
$change = $null

while ((Get-Date) -lt $deadline) {
    $changes = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
    $change = $changes |
        Where-Object {
            try {
                ([int]$_.id -gt $previousMaxId) -and
                ([System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullPath) -and
                ($_.event_type -eq "MODIFIED")
            }
            catch { $false }
        } |
        Sort-Object { [int]$_.id } -Descending |
        Select-Object -First 1

    if ($change) { break }
    Start-Sleep -Milliseconds 250
}

if (-not $change) {
    throw "El agente no detectó el MODIFIED dentro de $DetectionTimeoutSeconds segundos."
}

$payload = @{
    occurred_at = $occurredAt.ToString("o")
    source = "EXPERIMENT_CONTROLLED_MTTR_PILOT"
} | ConvertTo-Json

$change = Invoke-RestMethod `
    -Method Patch `
    -Uri "$ApiBase/changes/$($change.id)/event-time" `
    -ContentType "application/json" `
    -Body $payload

Write-Host ""
Write-Host "=========================================================="
Write-Host "EVENTO DETECTADO. COMENZÁ AHORA LA REVISIÓN ASISTIDA."
Write-Host "1) No uses esta consola para investigar."
Write-Host "2) En el frontend seleccioná: $EnvironmentName"
Write-Host "3) Abrí el evento PENDIENTE."
Write-Host "4) Leé tipo, ruta, baseline y hashes."
Write-Host "5) Cuando confirmes el cambio, hacé clic en 'Revisado'."
Write-Host "El script está midiendo y se detendrá solo al registrar la revisión."
Write-Host "=========================================================="

$reviewDeadline = (Get-Date).AddSeconds($ReviewTimeoutSeconds)
$reviewed = $null

while ((Get-Date) -lt $reviewDeadline) {
    $changes = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
    $reviewed = $changes |
        Where-Object { [int]$_.id -eq [int]$change.id } |
        Select-Object -First 1

    if ($reviewed -and $reviewed.review_status -ne "PENDING") {
        break
    }

    Start-Sleep -Milliseconds 250
}

if (-not $reviewed -or $reviewed.review_status -eq "PENDING") {
    throw "No se registró la revisión dentro de $ReviewTimeoutSeconds segundos."
}

$baselineAfterRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
$baselineAfter = $baselineAfterRows |
    Where-Object {
        try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullPath }
        catch { $false }
    } |
    Select-Object -First 1

$evidence = [ordered]@{
    protocol = "MTTR_PILOT_ASSISTED_V1"
    condition = "ASSISTED_FRONTEND"
    environment_id = $environment.id
    environment_name = $EnvironmentName
    change_id = $reviewed.id
    event_type = $reviewed.event_type
    path = $reviewed.path
    occurred_at = $reviewed.occurred_at
    detected_at = $reviewed.detected_at
    reviewed_at = $reviewed.reviewed_at
    mttd_seconds = $reviewed.detection_time_seconds
    mttr_seconds = $reviewed.response_time_seconds
    review_status = $reviewed.review_status
    baseline_match = $reviewed.baseline_match
    baseline_sha256_initial = $baselineSha
    baseline_sha256_after = if ($baselineAfter) { $baselineAfter.sha256 } else { $null }
    baseline_preserved = if ($baselineAfter) { ([string]$baselineAfter.sha256 -eq $baselineSha) } else { $false }
    completed_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
}

$evidence | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath $evidencePath -Encoding UTF8

Write-Host ""
Write-Host "=============================================="
Write-Host "FIN PILOTO MTTR ASISTIDO"
Write-Host "Evento: #$($reviewed.id) $($reviewed.event_type)"
Write-Host "Estado: $($reviewed.review_status)"
Write-Host "Detectado: $($reviewed.detected_at)"
Write-Host "Revisado: $($reviewed.reviewed_at)"
Write-Host "MTTR: $($reviewed.response_time_seconds) s"
Write-Host "Baseline preservada: $(([string]$baselineAfter.sha256 -eq $baselineSha))"
Write-Host "Evidencia: $evidencePath"
Write-Host "=============================================="
