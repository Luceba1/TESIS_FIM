param(
    [string]$EnvironmentName = "Experimento NoChange",
    [string]$TestDirectory = "C:\watchdogs_experimento_nochange",
    [int]$FileCount = 10,
    [string]$ApiBase = "http://127.0.0.1:8000/api/v1"
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

if ($FileCount -lt 1) {
    throw "FileCount debe ser al menos 1."
}

$root = Split-Path -Parent $PSScriptRoot
$evidenceDir = Join-Path $root "evidencias\formal\nochange"
$setupManifestPath = Join-Path $evidenceDir "NOCHANGE_setup_manifest.json"
$fullDir = [System.IO.Path]::GetFullPath($TestDirectory)

New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

if (Test-Path -LiteralPath $setupManifestPath) {
    throw "Ya existe $setupManifestPath. No se repite la preparación para evitar mezclar evidencia."
}

$existingEnv = @(Get-ApiItems -Uri "$ApiBase/environments") |
    Where-Object { $_.name -eq $EnvironmentName } |
    Select-Object -First 1

if ($existingEnv) {
    throw "Ya existe un entorno llamado '$EnvironmentName' (id=$($existingEnv.id)). Use otro nombre o revise la preparación anterior."
}

if (Test-Path -LiteralPath $fullDir) {
    $existingFiles = @(Get-ChildItem -LiteralPath $fullDir -Force -ErrorAction Stop)
    if ($existingFiles.Count -gt 0) {
        throw "La carpeta $fullDir ya existe y no está vacía. No se modifica para evitar mezclar evidencia."
    }
}
else {
    New-Item -ItemType Directory -Path $fullDir -Force | Out-Null
}

$agentWasRunning = $false
$setupSucceeded = $false
$environment = $null
$monitoredPath = $null

try {
    $agent = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
    $agentWasRunning = [bool]$agent.running

    if ($agentWasRunning) {
        Write-Host "Deteniendo temporalmente el agente..."
        Invoke-RestMethod -Method Post -Uri "$ApiBase/agent/stop" | Out-Null

        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $status = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
        } while ($status.running -and (Get-Date) -lt $deadline)

        if ($status.running) {
            throw "El agente no se detuvo dentro del tiempo esperado."
        }
    }

    Write-Host "Creando $FileCount archivos estables..."
    for ($i = 1; $i -le $FileCount; $i++) {
        $name = "stable_{0:D3}.txt" -f $i
        $path = Join-Path $fullDir $name
        $content = "WatchDogs FIM - control sin cambios - archivo {0:D3}" -f $i
        Set-Content -LiteralPath $path -Value $content -Encoding UTF8
    }

    $envBody = @{
        name = $EnvironmentName
        description = "Entorno aislado para control formal sin cambios / eventos espurios"
        criticality = "HIGH"
        enabled = $true
    } | ConvertTo-Json

    $environment = Invoke-RestMethod `
        -Method Post `
        -Uri "$ApiBase/environments" `
        -ContentType "application/json" `
        -Body $envBody

    $pathBody = @{
        environment_id = $environment.id
        path = $fullDir
        description = "Ruta aislada para control formal sin cambios"
        criticality = "HIGH"
        recursive = $true
        enabled = $true
    } | ConvertTo-Json

    $monitoredPath = Invoke-RestMethod `
        -Method Post `
        -Uri "$ApiBase/paths" `
        -ContentType "application/json" `
        -Body $pathBody

    Write-Host "Generando línea base aprobada..."
    $baselineResult = Invoke-RestMethod `
        -Method Post `
        -Uri "$ApiBase/baseline/generate?environment_id=$($environment.id)"

    $rows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
    $validRows = @($rows | Where-Object {
        $_.baseline_approved -eq $true -and
        $_.status -eq "ACTIVE" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.sha256) -and
        ([string]$_.sha256 -eq [string]$_.observed_sha256)
    })

    if ($rows.Count -ne $FileCount) {
        throw "Se esperaban $FileCount filas de baseline y la API devolvió $($rows.Count)."
    }
    if ($validRows.Count -ne $FileCount) {
        throw "Se esperaban $FileCount baselines aprobadas, activas y coincidentes; se encontraron $($validRows.Count)."
    }

    $existingChanges = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
    if ($existingChanges.Count -ne 0) {
        throw "El entorno ya contiene $($existingChanges.Count) eventos antes del control. La preparación no es limpia."
    }

    $files = @()
    foreach ($row in ($rows | Sort-Object path)) {
        $file = Get-Item -LiteralPath $row.path
        $physicalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $row.path).Hash.ToLowerInvariant()

        if ($physicalHash -ne ([string]$row.sha256).ToLowerInvariant()) {
            throw "El hash físico no coincide con la baseline para $($row.path)."
        }

        $files += [PSCustomObject]@{
            file_hash_id = $row.id
            path = $row.path
            baseline_sha256 = $row.sha256
            baseline_md5 = $row.md5
            baseline_approved_at = $row.baseline_approved_at
            length_bytes = $file.Length
            last_write_time_utc = $file.LastWriteTimeUtc.ToString("o")
        }
    }

    $manifest = [ordered]@{
        protocol = "FORMAL_NOCHANGE_SETUP_V1"
        prepared_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
        environment_name = $EnvironmentName
        environment_id = $environment.id
        monitored_path_id = $monitoredPath.id
        test_directory = $fullDir
        file_count = $FileCount
        planned_integrity_changes = 0
        api_base = $ApiBase
        baseline_generation = $baselineResult
        files = $files
    }

    $manifest | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath $setupManifestPath -Encoding UTF8

    $setupSucceeded = $true

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "PREPARACIÓN FORMAL NO-CHANGE COMPLETA"
    Write-Host "Entorno: $EnvironmentName (#$($environment.id))"
    Write-Host "Ruta: $fullDir"
    Write-Host "Archivos baseline válidos: $($validRows.Count)/$FileCount"
    Write-Host "Eventos previos en el entorno: 0"
    Write-Host "Manifiesto: $setupManifestPath"
    Write-Host "=============================================="
}
finally {
    if ($agentWasRunning) {
        Write-Host "Reiniciando agente..."
        try {
            Invoke-RestMethod -Method Post -Uri "$ApiBase/agent/start" | Out-Null
        }
        catch {
            Write-Warning "No se pudo reiniciar automáticamente el agente: $($_.Exception.Message)"
        }
    }
}

if (-not $setupSucceeded) {
    throw "La preparación no finalizó correctamente. Revise el error anterior."
}
