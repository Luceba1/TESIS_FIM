param(
    [int]$Count = 10,
    [string]$TestDir = "C:\watchdogs_experimento",
    [string]$EnvironmentName = "Experimento Tesis",
    [string]$ApiBase = "http://127.0.0.1:8000/api/v1",
    [int]$TimeoutSeconds = 30,
    [int]$Seed = 20260811,
    [double]$MinPauseSeconds = 0.5,
    [double]$MaxPauseSeconds = 9.5
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if ($Count -lt 1) {
    throw "Count debe ser al menos 1."
}
if ($MinPauseSeconds -lt 0 -or $MaxPauseSeconds -le $MinPauseSeconds) {
    throw "Rango de pausas inválido."
}

$root = Split-Path -Parent $PSScriptRoot
$eventScript = Join-Path $PSScriptRoot "run_experiment_event.ps1"
$evidenceDir = Join-Path $root "evidencias\formal\created"
$csvPath = Join-Path $evidenceDir "CREATED_formal.csv"
$summaryPath = Join-Path $evidenceDir "CREATED_summary.json"
$manifestPath = Join-Path $evidenceDir "CREATED_manifest.json"

if (-not (Test-Path -LiteralPath $eventScript)) {
    throw "No se encontró el script base: $eventScript"
}
if (-not (Test-Path -LiteralPath $TestDir)) {
    throw "No existe la carpeta experimental: $TestDir"
}

Unblock-File -LiteralPath $eventScript -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$agent = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
if (-not $agent.running) {
    throw "El agente FIM no está activo."
}

$environment = @(Invoke-RestMethod -Method Get -Uri "$ApiBase/environments") |
    Where-Object { $_.name -eq $EnvironmentName -and $_.enabled -eq $true } |
    Select-Object -First 1

if (-not $environment) {
    throw "No se encontró un entorno activo llamado '$EnvironmentName'."
}

# Evita pisar una corrida formal anterior.
for ($i = 1; $i -le $Count; $i++) {
    $path = Join-Path $TestDir ("formal_created_{0:D3}.txt" -f $i)
    if (Test-Path -LiteralPath $path) {
        throw "Ya existe $path. No se inicia la serie para evitar mezclar corridas."
    }
}

# Secuencia pseudoaleatoria reproducible. Los valores se guardan en el manifiesto.
$rng = [System.Random]::new($Seed)
$pauses = @()
for ($i = 1; $i -le $Count; $i++) {
    $p = $MinPauseSeconds + ($rng.NextDouble() * ($MaxPauseSeconds - $MinPauseSeconds))
    $pauses += [Math]::Round($p, 3)
}

$scriptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $eventScript).Hash
$runStarted = [DateTimeOffset]::UtcNow

$manifest = [ordered]@{
    protocol = "FORMAL_CREATED_V1"
    run_started_at_utc = $runStarted.ToString("o")
    event_type = "CREATED"
    count = $Count
    environment_name = $EnvironmentName
    environment_id = $environment.id
    test_directory = [System.IO.Path]::GetFullPath($TestDir)
    api_base = $ApiBase
    scan_interval_seconds = $agent.interval_seconds
    timeout_seconds = $TimeoutSeconds
    random_seed = $Seed
    min_pause_seconds = $MinPauseSeconds
    max_pause_seconds = $MaxPauseSeconds
    pause_schedule_seconds = $pauses
    base_script_sha256 = $scriptHash
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$rows = New-Object System.Collections.Generic.List[object]
$numericMttd = New-Object System.Collections.Generic.List[double]

Write-Host "=============================================="
Write-Host "SERIE FORMAL CREATED"
Write-Host "Entorno: $EnvironmentName (#$($environment.id))"
Write-Host "Cantidad: $Count"
Write-Host "Intervalo agente: $($agent.interval_seconds) s"
Write-Host "Seed: $Seed"
Write-Host "Evidencias: $evidenceDir"
Write-Host "=============================================="

for ($i = 1; $i -le $Count; $i++) {
    $trialId = "FORMAL-CREATED-{0:D3}" -f $i
    $fileName = "formal_created_{0:D3}.txt" -f $i
    $path = Join-Path $TestDir $fileName
    $pause = [double]$pauses[$i - 1]

    Write-Host ""
    Write-Host "[$trialId] Pausa previa: $($pause.ToString('0.000', $inv)) s"
    Start-Sleep -Milliseconds ([int][Math]::Round($pause * 1000))

    $trialStarted = [DateTimeOffset]::UtcNow
    $outcome = "DETECTED"
    $errorText = $null
    $result = $null
    $baselineApproved = $null
    $baselineApprovedAt = $null

    try {
        $result = & $eventScript `
            -EventType CREATED `
            -Path $path `
            -ApiBase $ApiBase `
            -TimeoutSeconds $TimeoutSeconds `
            -Content "WatchDogs FIM - $trialId"

        $baselineRows = @(Invoke-RestMethod -Method Get -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
        $baselineRow = $baselineRows |
            Where-Object {
                try {
                    [System.IO.Path]::GetFullPath([string]$_.path) -ieq [System.IO.Path]::GetFullPath($path)
                }
                catch { $false }
            } |
            Select-Object -First 1

        if ($baselineRow) {
            $baselineApproved = [bool]$baselineRow.baseline_approved
            $baselineApprovedAt = $baselineRow.baseline_approved_at
        }

        if ($baselineApproved -eq $true) {
            $outcome = "DETECTED_BUT_BASELINE_AUTOAPPROVED"
        }

        if ($outcome -eq "DETECTED" -and $null -ne $result.mttd_seconds) {
            $numericMttd.Add([double]$result.mttd_seconds)
        }
    }
    catch {
        $outcome = "FAILED"
        $errorText = $_.Exception.Message
        Write-Host "[$trialId] ERROR: $errorText"
    }

    $trialFinished = [DateTimeOffset]::UtcNow

    $evidence = [ordered]@{
        trial_id = $trialId
        trial_number = $i
        outcome = $outcome
        pause_before_seconds = $pause
        trial_started_at_utc = $trialStarted.ToString("o")
        trial_finished_at_utc = $trialFinished.ToString("o")
        environment_id = $environment.id
        environment_name = $EnvironmentName
        scan_interval_seconds = $agent.interval_seconds
        path = [System.IO.Path]::GetFullPath($path)
        change_id = if ($result) { $result.change_id } else { $null }
        event_type = if ($result) { $result.event_type } else { "CREATED" }
        action_started_at = if ($result) { $result.action_started_at } else { $null }
        occurred_at = if ($result) { $result.occurred_at } else { $null }
        detected_at = if ($result) { $result.detected_at } else { $null }
        mttd_seconds = if ($result) { $result.mttd_seconds } else { $null }
        scan_processing_seconds = if ($result) { $result.scan_processing_seconds } else { $null }
        occurred_at_source = if ($result) { $result.source } else { $null }
        baseline_approved = $baselineApproved
        baseline_approved_at = $baselineApprovedAt
        error = $errorText
    }

    $jsonPath = Join-Path $evidenceDir ("{0}.json" -f $trialId)
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $row = [PSCustomObject]@{
        trial_id = $trialId
        trial_number = $i
        outcome = $outcome
        pause_before_seconds = $pause.ToString("0.000", $inv)
        path = [System.IO.Path]::GetFullPath($path)
        change_id = if ($result) { $result.change_id } else { "" }
        event_type = "CREATED"
        occurred_at = if ($result) { $result.occurred_at } else { "" }
        detected_at = if ($result) { $result.detected_at } else { "" }
        mttd_seconds = if ($result -and $null -ne $result.mttd_seconds) { ([double]$result.mttd_seconds).ToString("0.000000", $inv) } else { "" }
        scan_processing_seconds = if ($result -and $null -ne $result.scan_processing_seconds) { ([double]$result.scan_processing_seconds).ToString("0.000000", $inv) } else { "" }
        occurred_at_source = if ($result) { $result.source } else { "" }
        baseline_approved = if ($null -eq $baselineApproved) { "" } else { $baselineApproved.ToString().ToUpperInvariant() }
        error = if ($errorText) { $errorText } else { "" }
    }
    $rows.Add($row)

    # Persistencia incremental: si la consola se corta, quedan todos los ensayos completados.
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ','

    if ($result) {
        Write-Host "[$trialId] OK - MTTD: $(([double]$result.mttd_seconds).ToString('0.000000', $inv)) s - change_id=$($result.change_id)"
    }
}

$detectedRows = @($rows | Where-Object { $_.outcome -eq "DETECTED" })
$failedRows = @($rows | Where-Object { $_.outcome -eq "FAILED" })
$autoApprovedRows = @($rows | Where-Object { $_.outcome -eq "DETECTED_BUT_BASELINE_AUTOAPPROVED" })
$detectedEventCount = $detectedRows.Count + $autoApprovedRows.Count

$mean = $null
$median = $null
$minimum = $null
$maximum = $null
$stddevSample = $null

if ($numericMttd.Count -gt 0) {
    $values = @($numericMttd | Sort-Object)
    $mean = ($values | Measure-Object -Average).Average
    $minimum = $values[0]
    $maximum = $values[$values.Count - 1]

    if (($values.Count % 2) -eq 1) {
        $median = $values[[int][Math]::Floor($values.Count / 2)]
    }
    else {
        $a = $values[($values.Count / 2) - 1]
        $b = $values[$values.Count / 2]
        $median = ($a + $b) / 2
    }

    if ($values.Count -gt 1) {
        $sumSq = 0.0
        foreach ($v in $values) {
            $sumSq += [Math]::Pow(($v - $mean), 2)
        }
        $stddevSample = [Math]::Sqrt($sumSq / ($values.Count - 1))
    }
}

$runFinished = [DateTimeOffset]::UtcNow
$summary = [ordered]@{
    protocol = "FORMAL_CREATED_V1"
    run_started_at_utc = $runStarted.ToString("o")
    run_finished_at_utc = $runFinished.ToString("o")
    requested_trials = $Count
    detected_trials = $detectedRows.Count
    failed_trials = $failedRows.Count
    baseline_autoapproved_trials = $autoApprovedRows.Count
    detection_rate = if ($Count -gt 0) { $detectedEventCount / [double]$Count } else { $null }
    valid_trial_rate = if ($Count -gt 0) { $detectedRows.Count / [double]$Count } else { $null }
    mttd_mean_seconds = $mean
    mttd_median_seconds = $median
    mttd_min_seconds = $minimum
    mttd_max_seconds = $maximum
    mttd_sample_stddev_seconds = $stddevSample
    csv = $csvPath
}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "=============================================="
Write-Host "FIN SERIE FORMAL CREATED"
Write-Host "Detectados correctamente: $($detectedRows.Count)/$Count"
Write-Host "Fallidos: $($failedRows.Count)"
Write-Host "Autoaprobaciones de baseline: $($autoApprovedRows.Count)"
if ($numericMttd.Count -gt 0) {
    Write-Host "MTTD media:   $($mean.ToString('0.000000', $inv)) s"
    Write-Host "MTTD mediana: $($median.ToString('0.000000', $inv)) s"
    Write-Host "MTTD mínimo:  $($minimum.ToString('0.000000', $inv)) s"
    Write-Host "MTTD máximo:  $($maximum.ToString('0.000000', $inv)) s"
    if ($null -ne $stddevSample) {
        Write-Host "Desv. estándar muestral: $($stddevSample.ToString('0.000000', $inv)) s"
    }
}
Write-Host "CSV: $csvPath"
Write-Host "Resumen: $summaryPath"
Write-Host "Manifiesto: $manifestPath"
Write-Host "=============================================="
