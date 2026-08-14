param(
    [string]$EnvironmentName = "Experimento Deleted",
    [string]$TestDirectory = "C:\watchdogs_experimento_deleted",
    [int]$Count = 10,
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

if ($Count -lt 1) {
    throw "Count debe ser al menos 1."
}

$fullDir = [System.IO.Path]::GetFullPath($TestDirectory)

# Evita reutilizar accidentalmente una preparación previa.
$existingEnv = @(Get-ApiItems -Uri "$ApiBase/environments") |
    Where-Object { $_.name -eq $EnvironmentName } |
    Select-Object -First 1

if ($existingEnv) {
    throw "Ya existe un entorno llamado '$EnvironmentName' (id=$($existingEnv.id)). Para no mezclar corridas, use otro nombre o elimine/revise manualmente la preparación previa."
}

if (Test-Path -LiteralPath $fullDir) {
    $existingFiles = @(Get-ChildItem -LiteralPath $fullDir -Force -ErrorAction Stop)
    if ($existingFiles.Count -gt 0) {
        throw "La carpeta $fullDir ya existe y no está vacía. No se modifica para evitar pérdida o mezcla de evidencia."
    }
}
else {
    New-Item -ItemType Directory -Path $fullDir -Force | Out-Null
}

$agentWasRunning = $false
$setupSucceeded = $false

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

    Write-Host "Creando $Count archivos de baseline para DELETED..."
    for ($i = 1; $i -le $Count; $i++) {
        $name = "deleted_{0:D3}.txt" -f $i
        $path = Join-Path $fullDir $name
        $content = "WatchDogs FIM - baseline formal DELETED - {0:D3}" -f $i
        Set-Content -LiteralPath $path -Value $content -Encoding UTF8
    }

    $envBody = @{
        name = $EnvironmentName
        description = "Entorno aislado para la serie formal DELETED"
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
        description = "Ruta aislada para los 10 ensayos formales DELETED"
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
    $approved = @($rows | Where-Object {
        $_.baseline_approved -eq $true -and
        $_.status -eq "ACTIVE"
    })

    if ($rows.Count -ne $Count) {
        throw "Se esperaban $Count filas de file_hashes y la API devolvió $($rows.Count)."
    }
    if ($approved.Count -ne $Count) {
        throw "Se esperaban $Count baselines aprobadas/activas y se encontraron $($approved.Count)."
    }

    $setupSucceeded = $true

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "PREPARACIÓN FORMAL DELETED COMPLETA"
    Write-Host "Entorno: $EnvironmentName (#$($environment.id))"
    Write-Host "Ruta: $fullDir"
    Write-Host "Monitored path id: $($monitoredPath.id)"
    Write-Host "Archivos baseline aprobados: $($approved.Count)/$Count"
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
    throw "La preparación no finalizó correctamente. Revise el error anterior antes de iniciar la serie formal."
}
