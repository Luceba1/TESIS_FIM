param(
    [string]$EnvironmentName = "Experimento MTTR Piloto",
    [string]$TestDirectory = "C:\watchdogs_experimento_mttr",
    [string]$FileName = "mttr_pilot.txt",
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
    elseif (
        ($response.PSObject.Properties.Name -contains "value") -and
        ($response.value -is [System.Array])
    ) {
        foreach ($item in $response.value) { $items.Add($item) }
    }
    else {
        $items.Add($response)
    }

    return $items.ToArray()
}

function Invoke-JsonPost {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Payload
    )

    # En Windows PowerShell 5.1 NO enviamos byte[] como -Body:
    # puede serializarse como una secuencia de números y FastAPI responde
    # "JSON decode error: Extra data". El payload de este experimento usa
    # sólo caracteres ASCII, por lo que una cadena JSON es segura.
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress

    return Invoke-RestMethod `
        -Method Post `
        -Uri $Uri `
        -ContentType "application/json" `
        -Body $json
}

$fullDir = [System.IO.Path]::GetFullPath($TestDirectory)
$testFile = [System.IO.Path]::GetFullPath((Join-Path $fullDir $FileName))
$expectedEnvDescription = "Entorno aislado para validar el protocolo MTTR piloto"
$expectedPathDescription = "Ruta piloto para medicion MTTR"

if (-not (Test-Path -LiteralPath $fullDir)) {
    New-Item -ItemType Directory -Path $fullDir -Force | Out-Null
}

# Recuperación segura del archivo residual del intento anterior.
$existingItems = @(Get-ChildItem -LiteralPath $fullDir -Force)
$unexpected = @($existingItems | Where-Object {
    $_.PSIsContainer -or ([System.IO.Path]::GetFullPath($_.FullName) -ine $testFile)
})

if ($unexpected.Count -gt 0) {
    $names = ($unexpected | ForEach-Object { $_.FullName }) -join "; "
    throw "La carpeta $fullDir contiene elementos inesperados. No se modifica. Elementos: $names"
}

if (Test-Path -LiteralPath $testFile) {
    Write-Host "Se encontró el archivo residual del intento anterior. Se reutilizará de forma segura."
}

$agent = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
$agentWasRunning = [bool]$agent.running
$setupSucceeded = $false

try {
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

    # Estado físico conocido y reproducible.
    Set-Content -LiteralPath $testFile `
        -Value "WatchDogs FIM - baseline piloto MTTR" `
        -Encoding UTF8

    # Reutiliza solamente un entorno parcial inequívocamente compatible.
    $environment = @(Get-ApiItems -Uri "$ApiBase/environments") |
        Where-Object { $_.name -eq $EnvironmentName } |
        Select-Object -First 1

    if (-not $environment) {
        Write-Host "Creando entorno piloto..."

        $environment = Invoke-JsonPost `
            -Uri "$ApiBase/environments" `
            -Payload @{
                name = $EnvironmentName
                description = $expectedEnvDescription
                criticality = "HIGH"
                enabled = $true
            }
    }
    else {
        Write-Host "Se encontró un entorno parcial existente (#$($environment.id)). Verificando si es reutilizable..."

        if ($environment.description -ne $expectedEnvDescription -or $environment.criticality -ne "HIGH") {
            throw "Existe '$EnvironmentName', pero no coincide con la preparación MTTR esperada. No se reutiliza."
        }
    }

    # Busca/reutiliza la ruta parcial si una ejecución anterior llegó a crearla.
    $paths = @(Get-ApiItems -Uri "$ApiBase/paths?environment_id=$($environment.id)")
    $monitoredPath = $paths |
        Where-Object {
            try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullDir }
            catch { $false }
        } |
        Select-Object -First 1

    $otherPaths = @($paths | Where-Object {
        try { [System.IO.Path]::GetFullPath([string]$_.path) -ine $fullDir }
        catch { $true }
    })

    if ($otherPaths.Count -gt 0) {
        throw "El entorno piloto contiene rutas inesperadas. No se modifica."
    }

    if (-not $monitoredPath) {
        Write-Host "Registrando ruta piloto..."

        $monitoredPath = Invoke-JsonPost `
            -Uri "$ApiBase/paths" `
            -Payload @{
                environment_id = [int]$environment.id
                path = $fullDir
                description = $expectedPathDescription
                criticality = "HIGH"
                recursive = $true
                enabled = $true
            }
    }

    # Si no hay baseline válida, la genera con el agente detenido.
    $baselineRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
    $baseline = $baselineRows |
        Where-Object {
            try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $testFile }
            catch { $false }
        } |
        Select-Object -First 1

    $needsBaseline = (
        (-not $baseline) -or
        ($baseline.baseline_approved -ne $true) -or
        [string]::IsNullOrWhiteSpace([string]$baseline.sha256) -or
        ([string]$baseline.sha256 -ne [string]$baseline.observed_sha256)
    )

    if ($needsBaseline) {
        Write-Host "Generando línea base aprobada..."

        Invoke-RestMethod `
            -Method Post `
            -Uri "$ApiBase/baseline/generate?environment_id=$($environment.id)" | Out-Null

        $baselineRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
        $baseline = $baselineRows |
            Where-Object {
                try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $testFile }
                catch { $false }
            } |
            Select-Object -First 1
    }
    else {
        Write-Host "La baseline piloto ya era válida; no se regenera."
    }

    if (-not $baseline) {
        throw "No se encontró el archivo piloto en la baseline."
    }

    if (
        $baseline.baseline_approved -ne $true -or
        [string]::IsNullOrWhiteSpace([string]$baseline.sha256) -or
        ([string]$baseline.sha256 -ne [string]$baseline.observed_sha256) -or
        $baseline.status -ne "ACTIVE"
    ) {
        throw "La baseline del archivo piloto no quedó aprobada/coherente."
    }

    # Un piloto limpio no debe arrancar con eventos previos.
    $existingChanges = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
    if ($existingChanges.Count -gt 0) {
        throw "El entorno MTTR piloto ya contiene $($existingChanges.Count) evento(s). No se inicia una medición limpia."
    }

    $setupSucceeded = $true

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "PREPARACIÓN MTTR PILOTO COMPLETA"
    Write-Host "Entorno: $EnvironmentName (#$($environment.id))"
    Write-Host "Ruta: $fullDir"
    Write-Host "Archivo: $testFile"
    Write-Host "Baseline aprobada: True"
    Write-Host "Eventos previos: 0"
    Write-Host "Monitored path id: $($monitoredPath.id)"
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
    throw "La preparación MTTR piloto no finalizó correctamente. Revise el error anterior."
}
