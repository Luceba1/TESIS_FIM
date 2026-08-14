param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("CREATED", "MODIFIED", "DELETED")]
    [string]$EventType,

    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$ApiBase = "http://127.0.0.1:8000/api/v1",
    [int]$TimeoutSeconds = 30,
    [string]$Content = "WatchDogs FIM - evento experimental"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-ApiItems {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $response = Invoke-RestMethod -Method Get -Uri $Uri

    if ($null -eq $response) {
        return @()
    }

    # Windows PowerShell 5.1 puede conservar un array JSON como un único
    # objeto de pipeline cuando Invoke-RestMethod se usa directamente dentro
    # de @(...). Normalizamos explícitamente la respuesta antes de filtrar.
    $items = New-Object System.Collections.Generic.List[object]

    if ($response -is [System.Array]) {
        foreach ($item in $response) {
            $items.Add($item)
        }
    }
    elseif (
        ($response.PSObject.Properties.Name -contains "value") -and
        ($response.value -is [System.Array])
    ) {
        foreach ($item in $response.value) {
            $items.Add($item)
        }
    }
    else {
        $items.Add($response)
    }

    return $items.ToArray()
}


$fullPath = [System.IO.Path]::GetFullPath($Path)

# Toma una "frontera" de IDs ANTES de ejecutar la acción. Esto evita que,
# al repetir MODIFIED sobre la misma ruta, el polling seleccione por error
# un evento anterior detectado pocos segundos antes.
$previousMaxId = 0
try {
    $existingChanges = @(Get-ApiItems -Uri "$ApiBase/changes?event_type=$EventType")
    foreach ($item in $existingChanges) {
        try {
            $candidatePath = [System.IO.Path]::GetFullPath([string]$item.path)
            $candidateId = [int]$item.id
            if (($candidatePath -ieq $fullPath) -and ($candidateId -gt $previousMaxId)) {
                $previousMaxId = $candidateId
            }
        }
        catch {
            # Ignora filas malformadas; no deben impedir el experimento.
        }
    }
}
catch {
    throw "No se pudo consultar el estado previo de eventos: $($_.Exception.Message)"
}

$actionStartedAt = [DateTimeOffset]::UtcNow

switch ($EventType) {
    "CREATED" {
        if (Test-Path -LiteralPath $fullPath) {
            throw "CREATED requiere que el archivo no exista: $fullPath"
        }
        $parent = Split-Path -Parent $fullPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Set-Content -LiteralPath $fullPath -Value $Content -Encoding UTF8
    }
    "MODIFIED" {
        if (-not (Test-Path -LiteralPath $fullPath)) {
            throw "MODIFIED requiere un archivo existente: $fullPath"
        }
        Add-Content -LiteralPath $fullPath -Value "`n$Content - $($actionStartedAt.ToString('o'))" -Encoding UTF8
    }
    "DELETED" {
        if (-not (Test-Path -LiteralPath $fullPath)) {
            throw "DELETED requiere un archivo existente: $fullPath"
        }
        Remove-Item -LiteralPath $fullPath -Force
    }
}

# Instante de ocurrencia experimental: fin de la operación controlada.
$occurredAt = [DateTimeOffset]::UtcNow
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$candidate = $null

Write-Host "Evento ejecutado: $EventType"
Write-Host "Ruta: $fullPath"
Write-Host "Inicio UTC: $($actionStartedAt.ToString('o'))"
Write-Host "Fin/ocurrencia UTC: $($occurredAt.ToString('o'))"
Write-Host "ID máximo previo para esta ruta/tipo: $previousMaxId"
Write-Host "Esperando detección del agente..."

while ((Get-Date) -lt $deadline) {
    $changes = @(Get-ApiItems -Uri "$ApiBase/changes?event_type=$EventType")
    $candidate = $changes |
        Where-Object {
            try {
                $candidatePath = [System.IO.Path]::GetFullPath([string]$_.path)
                $candidateId = [int]$_.id
                $detectedAt = [DateTimeOffset]::Parse([string]$_.detected_at).ToUniversalTime()

                ($candidatePath -ieq $fullPath) -and
                ($candidateId -gt $previousMaxId) -and
                ($detectedAt -ge $actionStartedAt.AddSeconds(-2))
            }
            catch {
                $false
            }
        } |
        Sort-Object { [int]$_.id } -Descending |
        Select-Object -First 1

    if ($candidate) {
        break
    }

    Start-Sleep -Milliseconds 250
}

if (-not $candidate) {
    throw "El agente no registró un evento NUEVO dentro de $TimeoutSeconds segundos. Verifique que el monitor esté activo y que la ruta pertenezca al alcance."
}

$payload = @{
    occurred_at = $occurredAt.ToString("o")
    source = "EXPERIMENT_CONTROLLED"
} | ConvertTo-Json

$updated = Invoke-RestMethod `
    -Method Patch `
    -Uri "$ApiBase/changes/$($candidate.id)/event-time" `
    -ContentType "application/json" `
    -Body $payload

$detectedUtc = [DateTimeOffset]::Parse([string]$updated.detected_at).ToUniversalTime()
$occurredUtc = [DateTimeOffset]::Parse([string]$updated.occurred_at).ToUniversalTime()

Write-Host "Evento #$($updated.id) asociado a marca experimental."
Write-Host "Detectado UTC: $($detectedUtc.ToString('o'))"
Write-Host "MTTD (s): $($updated.detection_time_seconds)"

[PSCustomObject]@{
    change_id = $updated.id
    previous_max_id = $previousMaxId
    event_type = $updated.event_type
    path = $updated.path
    action_started_at = $actionStartedAt.ToString("o")
    occurred_at = $occurredUtc.ToString("o")
    detected_at = $detectedUtc.ToString("o")
    mttd_seconds = $updated.detection_time_seconds
    scan_processing_seconds = $updated.scan_processing_time_seconds
    source = $updated.occurred_at_source
}
