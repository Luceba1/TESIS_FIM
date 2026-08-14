param(
    [int]$Count = 10,
    [string]$TestFile = "C:\watchdogs_experimento\config.txt",
    [string]$EnvironmentName = "Experimento Tesis",
    [string]$ApiBase = "http://127.0.0.1:8000/api/v1",
    [int]$TimeoutSeconds = 30,
    [int]$Seed = 20260812,
    [double]$MinPauseSeconds = 0.5,
    [double]$MaxPauseSeconds = 9.5
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

$inv = [System.Globalization.CultureInfo]::InvariantCulture

if ($Count -lt 1) {
    throw "Count debe ser al menos 1."
}
if ($MinPauseSeconds -lt 0 -or $MaxPauseSeconds -le $MinPauseSeconds) {
    throw "Rango de pausas inválido."
}

$root = Split-Path -Parent $PSScriptRoot
$eventScript = Join-Path $PSScriptRoot "run_experiment_event.ps1"
$evidenceDir = Join-Path $root "evidencias\formal\modified"
$csvPath = Join-Path $evidenceDir "MODIFIED_formal.csv"
$summaryPath = Join-Path $evidenceDir "MODIFIED_summary.json"
$manifestPath = Join-Path $evidenceDir "MODIFIED_manifest.json"

if (-not (Test-Path -LiteralPath $eventScript)) {
    throw "No se encontró el script base: $eventScript"
}
if (-not (Test-Path -LiteralPath $TestFile)) {
    throw "No existe el archivo de prueba: $TestFile"
}

Unblock-File -LiteralPath $eventScript -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

# Evita mezclar una corrida formal anterior.
if (Test-Path -LiteralPath $csvPath) {
    throw "Ya existe $csvPath. No se inicia la serie para evitar mezclar corridas."
}

$agent = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
if (-not $agent.running) {
    throw "El agente FIM no está activo."
}

$environment = @(Get-ApiItems -Uri "$ApiBase/environments") |
    Where-Object { $_.name -eq $EnvironmentName -and $_.enabled -eq $true } |
    Select-Object -First 1

if (-not $environment) {
    throw "No se encontró un entorno activo llamado '$EnvironmentName'."
}

$fullTestFile = [System.IO.Path]::GetFullPath($TestFile)

$baselineRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
$baselineInitial = $baselineRows |
    Where-Object {
        try {
            [System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullTestFile
        }
        catch { $false }
    } |
    Select-Object -First 1

if (-not $baselineInitial) {
    $knownPaths = @($baselineRows | ForEach-Object { [string]$_.path }) -join "; "
    throw "El archivo $fullTestFile no está registrado en file_hashes. Rutas devueltas por la API: $knownPaths"
}
if ($baselineInitial.baseline_approved -ne $true) {
    throw "El archivo $fullTestFile NO tiene una línea base aprobada. MODIFIED formal requiere baseline aprobada."
}
if ([string]::IsNullOrWhiteSpace([string]$baselineInitial.sha256)) {
    throw "El archivo $fullTestFile no posee SHA-256 de baseline."
}

$baselineShaInitial = [string]$baselineInitial.sha256
$baselineMd5Initial = [string]$baselineInitial.md5
$baselineApprovedAtInitial = [string]$baselineInitial.baseline_approved_at

# Secuencia pseudoaleatoria reproducible.
$rng = [System.Random]::new($Seed)
$pauses = @()
for ($i = 1; $i -le $Count; $i++) {
    $p = $MinPauseSeconds + ($rng.NextDouble() * ($MaxPauseSeconds - $MinPauseSeconds))
    $pauses += [Math]::Round($p, 3)
}

$scriptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $eventScript).Hash
$batchHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $MyInvocation.MyCommand.Path).Hash
$runStarted = [DateTimeOffset]::UtcNow

$manifest = [ordered]@{
    protocol = "FORMAL_MODIFIED_V1"
    run_started_at_utc = $runStarted.ToString("o")
    event_type = "MODIFIED"
    count = $Count
    environment_name = $EnvironmentName
    environment_id = $environment.id
    test_file = $fullTestFile
    modification_strategy = "Cumulative append. The approved baseline hash remains fixed; observed state advances after each detected modification."
    baseline_sha256_at_start = $baselineShaInitial
    baseline_md5_at_start = $baselineMd5Initial
    baseline_approved_at_start = $baselineApprovedAtInitial
    api_base = $ApiBase
    scan_interval_seconds = $agent.interval_seconds
    timeout_seconds = $TimeoutSeconds
    random_seed = $Seed
    min_pause_seconds = $MinPauseSeconds
    max_pause_seconds = $MaxPauseSeconds
    pause_schedule_seconds = $pauses
    base_script_sha256 = $scriptHash
    batch_script_sha256 = $batchHash
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$rows = New-Object System.Collections.Generic.List[object]
$numericMttd = New-Object System.Collections.Generic.List[double]
$abortReason = $null

Write-Host "=============================================="
Write-Host "SERIE FORMAL MODIFIED"
Write-Host "Entorno: $EnvironmentName (#$($environment.id))"
Write-Host "Archivo: $fullTestFile"
Write-Host "Baseline SHA256: $baselineShaInitial"
Write-Host "Cantidad: $Count"
Write-Host "Intervalo agente: $($agent.interval_seconds) s"
Write-Host "Seed: $Seed"
Write-Host "Evidencias: $evidenceDir"
Write-Host "=============================================="

for ($i = 1; $i -le $Count; $i++) {
    $trialId = "FORMAL-MODIFIED-{0:D3}" -f $i
    $pause = [double]$pauses[$i - 1]

    Write-Host ""
    Write-Host "[$trialId] Pausa previa: $($pause.ToString('0.000', $inv)) s"
    Start-Sleep -Milliseconds ([int][Math]::Round($pause * 1000))

    # Verifica antes de cada ensayo que la baseline aprobada siga intacta.
    $baselineBeforeRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
    $baselineBefore = $baselineBeforeRows |
        Where-Object {
            try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullTestFile }
            catch { $false }
        } |
        Select-Object -First 1

    if (-not $baselineBefore -or
        $baselineBefore.baseline_approved -ne $true -or
        ([string]$baselineBefore.sha256 -ne $baselineShaInitial)) {
        $abortReason = "La baseline cambió ANTES de $trialId. Se aborta la serie para no producir datos inválidos."
        Write-Host $abortReason
        break
    }

    $trialStarted = [DateTimeOffset]::UtcNow
    $outcome = "DETECTED"
    $errorText = $null
    $result = $null
    $changeRecord = $null
    $baselineAfter = $null
    $baselineChanged = $false
    $observedMatchesEvent = $null

    try {
        $result = & $eventScript `
            -EventType MODIFIED `
            -Path $fullTestFile `
            -ApiBase $ApiBase `
            -TimeoutSeconds $TimeoutSeconds `
            -Content "WatchDogs FIM - $trialId"

        $changes = @(Get-ApiItems -Uri "$ApiBase/changes?event_type=MODIFIED")
        $changeRecord = $changes |
            Where-Object { [int]$_.id -eq [int]$result.change_id } |
            Select-Object -First 1

        if (-not $changeRecord) {
            throw "No se pudo recuperar desde la API el change_id=$($result.change_id)."
        }

        $baselineAfterRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
        $baselineAfter = $baselineAfterRows |
            Where-Object {
                try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullTestFile }
                catch { $false }
            } |
            Select-Object -First 1

        if (-not $baselineAfter) {
            throw "El archivo desapareció de file_hashes después del ensayo."
        }

        $baselineChanged =
            ($baselineAfter.baseline_approved -ne $true) -or
            ([string]$baselineAfter.sha256 -ne $baselineShaInitial)

        if ($baselineChanged) {
            $outcome = "DETECTED_BUT_BASELINE_CHANGED"
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$changeRecord.new_sha256)) {
            $observedMatchesEvent = ([string]$baselineAfter.observed_sha256 -eq [string]$changeRecord.new_sha256)
            if (($observedMatchesEvent -eq $false) -and ($outcome -eq "DETECTED")) {
                $outcome = "DETECTED_BUT_OBSERVED_MISMATCH"
            }
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
        path = $fullTestFile
        change_id = if ($result) { $result.change_id } else { $null }
        previous_max_id = if ($result) { $result.previous_max_id } else { $null }
        event_type = "MODIFIED"
        action_started_at = if ($result) { $result.action_started_at } else { $null }
        occurred_at = if ($result) { $result.occurred_at } else { $null }
        detected_at = if ($result) { $result.detected_at } else { $null }
        mttd_seconds = if ($result) { $result.mttd_seconds } else { $null }
        scan_processing_seconds = if ($result) { $result.scan_processing_seconds } else { $null }
        occurred_at_source = if ($result) { $result.source } else { $null }
        baseline_sha256_initial = $baselineShaInitial
        baseline_sha256_after = if ($baselineAfter) { $baselineAfter.sha256 } else { $null }
        baseline_approved_after = if ($baselineAfter) { $baselineAfter.baseline_approved } else { $null }
        baseline_approved_at_after = if ($baselineAfter) { $baselineAfter.baseline_approved_at } else { $null }
        observed_sha256_after = if ($baselineAfter) { $baselineAfter.observed_sha256 } else { $null }
        observed_matches_event_new_sha256 = $observedMatchesEvent
        baseline_changed = $baselineChanged
        change_record = $changeRecord
        error = $errorText
    }

    $jsonPath = Join-Path $evidenceDir ("{0}.json" -f $trialId)
    $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $row = [PSCustomObject]@{
        trial_id = $trialId
        trial_number = $i
        outcome = $outcome
        pause_before_seconds = $pause.ToString("0.000", $inv)
        path = $fullTestFile
        change_id = if ($result) { $result.change_id } else { "" }
        previous_max_id = if ($result) { $result.previous_max_id } else { "" }
        event_type = "MODIFIED"
        occurred_at = if ($result) { $result.occurred_at } else { "" }
        detected_at = if ($result) { $result.detected_at } else { "" }
        mttd_seconds = if ($result -and $null -ne $result.mttd_seconds) { ([double]$result.mttd_seconds).ToString("0.000000", $inv) } else { "" }
        scan_processing_seconds = if ($result -and $null -ne $result.scan_processing_seconds) { ([double]$result.scan_processing_seconds).ToString("0.000000", $inv) } else { "" }
        occurred_at_source = if ($result) { $result.source } else { "" }
        old_sha256 = if ($changeRecord) { $changeRecord.old_sha256 } else { "" }
        new_sha256 = if ($changeRecord) { $changeRecord.new_sha256 } else { "" }
        baseline_sha256_event = if ($changeRecord) { $changeRecord.baseline_sha256 } else { "" }
        baseline_match = if ($changeRecord -and $null -ne $changeRecord.baseline_match) { $changeRecord.baseline_match } else { "" }
        baseline_sha256_after = if ($baselineAfter) { $baselineAfter.sha256 } else { "" }
        observed_sha256_after = if ($baselineAfter) { $baselineAfter.observed_sha256 } else { "" }
        baseline_changed = $baselineChanged
        observed_matches_event_new_sha256 = if ($null -eq $observedMatchesEvent) { "" } else { $observedMatchesEvent }
        error = if ($errorText) { $errorText } else { "" }
    }
    $rows.Add($row)

    # Persistencia incremental.
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ','

    if ($result) {
        Write-Host "[$trialId] $outcome - MTTD: $(([double]$result.mttd_seconds).ToString('0.000000', $inv)) s - change_id=$($result.change_id)"
    }

    # Si una prueba rompe la baseline, el estado observado o no se detecta,
    # no seguimos: las siguientes mediciones dejarían de ser comparables.
    if ($outcome -ne "DETECTED") {
        $abortReason = "Serie detenida después de $trialId por outcome=$outcome."
        Write-Host $abortReason
        break
    }
}

$detectedRows = @($rows | Where-Object { $_.outcome -eq "DETECTED" })
$failedRows = @($rows | Where-Object { $_.outcome -eq "FAILED" })
$invalidRows = @($rows | Where-Object { $_.outcome -ne "DETECTED" -and $_.outcome -ne "FAILED" })

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

# Verificación final de la baseline.
$baselineFinalRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
$baselineFinal = $baselineFinalRows |
    Where-Object {
        try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $fullTestFile }
        catch { $false }
    } |
    Select-Object -First 1

$baselinePreserved =
    ($baselineFinal) -and
    ($baselineFinal.baseline_approved -eq $true) -and
    ([string]$baselineFinal.sha256 -eq $baselineShaInitial)

$runFinished = [DateTimeOffset]::UtcNow
$summary = [ordered]@{
    protocol = "FORMAL_MODIFIED_V1"
    run_started_at_utc = $runStarted.ToString("o")
    run_finished_at_utc = $runFinished.ToString("o")
    requested_trials = $Count
    completed_trials = $rows.Count
    detected_valid_trials = $detectedRows.Count
    failed_trials = $failedRows.Count
    invalid_trials = $invalidRows.Count
    valid_trial_rate_over_requested = if ($Count -gt 0) { $detectedRows.Count / [double]$Count } else { $null }
    baseline_sha256_at_start = $baselineShaInitial
    baseline_sha256_at_end = if ($baselineFinal) { $baselineFinal.sha256 } else { $null }
    baseline_preserved = $baselinePreserved
    abort_reason = $abortReason
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
Write-Host "FIN SERIE FORMAL MODIFIED"
Write-Host "Completados: $($rows.Count)/$Count"
Write-Host "Detectados válidos: $($detectedRows.Count)/$Count"
Write-Host "Fallidos: $($failedRows.Count)"
Write-Host "Inválidos por invariantes: $($invalidRows.Count)"
Write-Host "Baseline preservada: $baselinePreserved"
if ($numericMttd.Count -gt 0) {
    Write-Host "MTTD media:   $($mean.ToString('0.000000', $inv)) s"
    Write-Host "MTTD mediana: $($median.ToString('0.000000', $inv)) s"
    Write-Host "MTTD mínimo:  $($minimum.ToString('0.000000', $inv)) s"
    Write-Host "MTTD máximo:  $($maximum.ToString('0.000000', $inv)) s"
    if ($null -ne $stddevSample) {
        Write-Host "Desv. estándar muestral: $($stddevSample.ToString('0.000000', $inv)) s"
    }
}
if ($abortReason) {
    Write-Host "Abort reason: $abortReason"
}
Write-Host "CSV: $csvPath"
Write-Host "Resumen: $summaryPath"
Write-Host "Manifiesto: $manifestPath"
Write-Host "=============================================="
