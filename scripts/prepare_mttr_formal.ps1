param(
    [string]$EnvironmentName = "Experimento MTTR Formal",
    [string]$TestDirectory = "C:\watchdogs_experimento_mttr_formal",
    [int]$FileCount = 20,
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

    # Windows PowerShell 5.1 puede enviar strings JSON con una codificacion
    # incompatible con FastAPI cuando el cuerpo contiene caracteres no ASCII.
    # Los payloads de este protocolo usan solo ASCII.
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress

    return Invoke-RestMethod `
        -Method Post `
        -Uri $Uri `
        -ContentType "application/json" `
        -Body $json
}

if ($FileCount -ne 20) {
    throw "Este protocolo formal esta diseñado para exactamente 20 archivos."
}

$fullDir = [System.IO.Path]::GetFullPath($TestDirectory)
$expectedEnvDescription = "Entorno aislado para comparacion formal de revision por consola vs dashboard"
$expectedPathDescription = "Ruta formal MTTR"

if (-not (Test-Path -LiteralPath $fullDir)) {
    New-Item -ItemType Directory -Path $fullDir -Force | Out-Null
}

# Recuperacion segura del intento fallido anterior.
$expectedNames = @()
for ($i = 1; $i -le $FileCount; $i++) {
    $expectedNames += ("mttr_{0:D3}.txt" -f $i)
}

$existingItems = @(Get-ChildItem -LiteralPath $fullDir -Force)
$unexpected = @(
    $existingItems | Where-Object {
        $_.PSIsContainer -or ($expectedNames -notcontains $_.Name)
    }
)

if ($unexpected.Count -gt 0) {
    $names = ($unexpected | ForEach-Object { $_.FullName }) -join "; "
    throw "La carpeta $fullDir contiene elementos inesperados. No se modifica. Elementos: $names"
}

if ($existingItems.Count -gt 0) {
    Write-Host "Se encontraron archivos residuales del intento fallido anterior. Se reutilizaran de forma segura."
}

$agent = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
$agentWasRunning = [bool]$agent.running
$success = $false

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

    Write-Host "Preparando 20 archivos independientes..."
    for ($i = 1; $i -le $FileCount; $i++) {
        $path = Join-Path $fullDir ("mttr_{0:D3}.txt" -f $i)

        Set-Content `
            -LiteralPath $path `
            -Value ("WatchDogs FIM - baseline MTTR formal - {0:D3}" -f $i) `
            -Encoding UTF8
    }

    # Si la ejecucion anterior alcanzo a crear el entorno, solo se reutiliza
    # si coincide exactamente con esta preparacion formal.
    $environment = @(Get-ApiItems -Uri "$ApiBase/environments") |
        Where-Object { $_.name -eq $EnvironmentName } |
        Select-Object -First 1

    if (-not $environment) {
        Write-Host "Creando entorno formal..."

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
        Write-Host "Se encontro un entorno parcial existente (#$($environment.id)). Verificando..."

        if (
            $environment.description -ne $expectedEnvDescription -or
            $environment.criticality -ne "HIGH"
        ) {
            throw "Existe '$EnvironmentName', pero no coincide con esta preparacion formal. No se reutiliza."
        }
    }

    $paths = @(Get-ApiItems -Uri "$ApiBase/paths?environment_id=$($environment.id)")

    $monitoredPath = $paths |
        Where-Object {
            try {
                [System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullDir
            }
            catch { $false }
        } |
        Select-Object -First 1

    $otherPaths = @(
        $paths | Where-Object {
            try {
                [System.IO.Path]::GetFullPath([string]$_.path) -ine $fullDir
            }
            catch { $true }
        }
    )

    if ($otherPaths.Count -gt 0) {
        throw "El entorno formal contiene rutas inesperadas. No se modifica."
    }

    if (-not $monitoredPath) {
        Write-Host "Registrando ruta formal..."

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

    $baselineRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")

    $validExisting = @(
        $baselineRows | Where-Object {
            $_.baseline_approved -eq $true -and
            $_.status -eq "ACTIVE" -and
            -not [string]::IsNullOrWhiteSpace([string]$_.sha256) -and
            ([string]$_.sha256 -eq [string]$_.observed_sha256)
        }
    )

    if ($baselineRows.Count -ne $FileCount -or $validExisting.Count -ne $FileCount) {
        Write-Host "Generando baseline aprobada..."

        Invoke-RestMethod `
            -Method Post `
            -Uri "$ApiBase/baseline/generate?environment_id=$($environment.id)" | Out-Null
    }
    else {
        Write-Host "La baseline formal ya era valida; no se regenera."
    }

    $baselineRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")

    $valid = @(
        $baselineRows | Where-Object {
            $_.baseline_approved -eq $true -and
            $_.status -eq "ACTIVE" -and
            -not [string]::IsNullOrWhiteSpace([string]$_.sha256) -and
            ([string]$_.sha256 -eq [string]$_.observed_sha256)
        }
    )

    if ($baselineRows.Count -ne $FileCount -or $valid.Count -ne $FileCount) {
        throw "Baseline invalida: total=$($baselineRows.Count), validos=$($valid.Count), esperados=$FileCount."
    }

    # Verifica que cada nombre esperado tenga exactamente una fila.
    for ($i = 1; $i -le $FileCount; $i++) {
        $expectedPath = [System.IO.Path]::GetFullPath(
            (Join-Path $fullDir ("mttr_{0:D3}.txt" -f $i))
        )

        $matches = @(
            $baselineRows | Where-Object {
                try {
                    [System.IO.Path]::GetFullPath([string]$_.path) -ieq $expectedPath
                }
                catch { $false }
            }
        )

        if ($matches.Count -ne 1) {
            throw "La baseline no contiene exactamente una fila para $expectedPath."
        }
    }

    $changes = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")

    if ($changes.Count -ne 0) {
        throw "El entorno formal contiene $($changes.Count) evento(s) antes de empezar. No se inicia la serie."
    }

    $success = $true

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "PREPARACIÓN MTTR FORMAL COMPLETA"
    Write-Host "Entorno: $EnvironmentName (#$($environment.id))"
    Write-Host "Ruta: $fullDir"
    Write-Host "Archivos baseline válidos: $($valid.Count)/$FileCount"
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
            Write-Warning "No se pudo reiniciar automaticamente el agente: $($_.Exception.Message)"
        }
    }
}

if (-not $success) {
    throw "La preparacion MTTR formal no finalizo correctamente. Revise el error anterior."
}
