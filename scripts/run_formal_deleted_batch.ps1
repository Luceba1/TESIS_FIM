param(
    [int]$Count = 10,
    [string]$EnvironmentName = "Experimento Deleted",
    [string]$TestDirectory = "C:\watchdogs_experimento_deleted",
    [string]$ApiBase = "http://127.0.0.1:8000/api/v1",
    [int]$TimeoutSeconds = 30,
    [int]$Seed = 20260813,
    [double]$MinPauseSeconds = 0.5,
    [double]$MaxPauseSeconds = 9.5
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()
$inv = [System.Globalization.CultureInfo]::InvariantCulture

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

if ($Count -lt 1) { throw "Count debe ser al menos 1." }
if ($MinPauseSeconds -lt 0 -or $MaxPauseSeconds -le $MinPauseSeconds) {
    throw "Rango de pausas inválido."
}

$root = Split-Path -Parent $PSScriptRoot
$eventScript = Join-Path $PSScriptRoot "run_experiment_event.ps1"
$fullDir = [System.IO.Path]::GetFullPath($TestDirectory)
$evidenceDir = Join-Path $root "evidencias\formal\deleted"
$csvPath = Join-Path $evidenceDir "DELETED_formal.csv"
$summaryPath = Join-Path $evidenceDir "DELETED_summary.json"
$manifestPath = Join-Path $evidenceDir "DELETED_manifest.json"

if (-not (Test-Path -LiteralPath $eventScript)) {
    throw "No se encontró el script base: $eventScript"
}

Unblock-File -LiteralPath $eventScript -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

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

$baselineRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")

$expected = New-Object System.Collections.Generic.List[object]
for ($i = 1; $i -le $Count; $i++) {
    $name = "deleted_{0:D3}.txt" -f $i
    $path = [System.IO.Path]::GetFullPath((Join-Path $fullDir $name))

    $row = $baselineRows |
        Where-Object {
            try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $path }
            catch { $false }
        } |
        Select-Object -First 1

    if (-not $row) {
        throw "No existe baseline para $path."
    }
    if ($row.baseline_approved -ne $true -or $row.status -ne "ACTIVE") {
        throw "$path no está ACTIVE con baseline aprobada."
    }
    if ([string]::IsNullOrWhiteSpace([string]$row.sha256)) {
        throw "$path no posee SHA-256 de baseline."
    }
    if (-not (Test-Path -LiteralPath $path)) {
        throw "El archivo físico no existe antes de la serie: $path"
    }

    $expected.Add([PSCustomObject]@{
        trial_number = $i
        path = $path
        file_hash_id = $row.id
        baseline_sha256 = [string]$row.sha256
        baseline_md5 = [string]$row.md5
        baseline_approved_at = [string]$row.baseline_approved_at
    })
}

$rng = [System.Random]::new($Seed)
$pauses = @()
for ($i = 1; $i -le $Count; $i++) {
    $p = $MinPauseSeconds + ($rng.NextDouble() * ($MaxPauseSeconds - $MinPauseSeconds))
    $pauses += [Math]::Round($p, 3)
}

$runStarted = [DateTimeOffset]::UtcNow
$manifest = [ordered]@{
    protocol = "FORMAL_DELETED_V1"
    run_started_at_utc = $runStarted.ToString("o")
    event_type = "DELETED"
    count = $Count
    environment_name = $EnvironmentName
    environment_id = $environment.id
    test_directory = $fullDir
    deletion_strategy = "Ten independent baseline-approved files, each deleted once."
    api_base = $ApiBase
    scan_interval_seconds = $agent.interval_seconds
    timeout_seconds = $TimeoutSeconds
    random_seed = $Seed
    min_pause_seconds = $MinPauseSeconds
    max_pause_seconds = $MaxPauseSeconds
    pause_schedule_seconds = $pauses
    base_script_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $eventScript).Hash
    batch_script_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $MyInvocation.MyCommand.Path).Hash
    initial_files = $expected
}
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$rows = New-Object System.Collections.Generic.List[object]
$numericMttd = New-Object System.Collections.Generic.List[double]
$abortReason = $null

Write-Host "=============================================="
Write-Host "SERIE FORMAL DELETED"
Write-Host "Entorno: $EnvironmentName (#$($environment.id))"
Write-Host "Ruta: $fullDir"
Write-Host "Cantidad: $Count"
Write-Host "Intervalo agente: $($agent.interval_seconds) s"
Write-Host "Seed: $Seed"
Write-Host "=============================================="

for ($i = 1; $i -le $Count; $i++) {
    $trialId = "FORMAL-DELETED-{0:D3}" -f $i
    $expectedRow = $expected[$i - 1]
    $pause = [double]$pauses[$i - 1]
    $path = [string]$expectedRow.path

    Write-Host ""
    Write-Host "[$trialId] Pausa previa: $($pause.ToString('0.000', $inv)) s"
    Start-Sleep -Milliseconds ([int][Math]::Round($pause * 1000))

    # Invariantes inmediatamente antes de borrar.
    $beforeRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
    $before = $beforeRows |
        Where-Object { [int]$_.id -eq [int]$expectedRow.file_hash_id } |
        Select-Object -First 1

    if (-not $before -or
        $before.baseline_approved -ne $true -or
        $before.status -ne "ACTIVE" -or
        ([string]$before.sha256 -ne [string]$expectedRow.baseline_sha256) -or
        -not (Test-Path -LiteralPath $path)) {
        $abortReason = "Estado previo inválido en $trialId. Se aborta la serie."
        Write-Host $abortReason
        break
    }

    $outcome = "DETECTED"
    $errorText = $null
    $result = $null
    $changeRecord = $null
    $after = $null
    $baselinePreserved = $false
    $deletedStatusOk = $false
    $oldHashMatchesBaseline = $false
    $physicalDeleted = $false

    try {
        $result = & $eventScript `
            -EventType DELETED `
            -Path $path `
            -ApiBase $ApiBase `
            -TimeoutSeconds $TimeoutSeconds

        $changes = @(Get-ApiItems -Uri "$ApiBase/changes?event_type=DELETED")
        $changeRecord = $changes |
            Where-Object { [int]$_.id -eq [int]$result.change_id } |
            Select-Object -First 1

        if (-not $changeRecord) {
            throw "No se pudo recuperar change_id=$($result.change_id)."
        }

        $afterRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
        $after = $afterRows |
            Where-Object { [int]$_.id -eq [int]$expectedRow.file_hash_id } |
            Select-Object -First 1

        if (-not $after) {
            throw "El FileHash desapareció después del borrado."
        }

        $baselinePreserved =
            ($after.baseline_approved -eq $true) -and
            ([string]$after.sha256 -eq [string]$expectedRow.baseline_sha256)

        $deletedStatusOk = ([string]$after.status -eq "DELETED")
        $physicalDeleted = -not (Test-Path -LiteralPath $path)
        $oldHashMatchesBaseline = ([string]$changeRecord.old_sha256 -eq [string]$expectedRow.baseline_sha256)

        if (-not $baselinePreserved) {
            $outcome = "DETECTED_BUT_BASELINE_CHANGED"
        }
        elseif (-not $deletedStatusOk) {
            $outcome = "DETECTED_BUT_STATUS_NOT_DELETED"
        }
        elseif (-not $physicalDeleted) {
            $outcome = "DETECTED_BUT_FILE_STILL_EXISTS"
        }
        elseif (-not $oldHashMatchesBaseline) {
            $outcome = "DETECTED_BUT_OLD_HASH_MISMATCH"
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

    $evidence = [ordered]@{
        trial_id = $trialId
        trial_number = $i
        outcome = $outcome
        pause_before_seconds = $pause
        environment_id = $environment.id
        environment_name = $EnvironmentName
        scan_interval_seconds = $agent.interval_seconds
        path = $path
        file_hash_id = $expectedRow.file_hash_id
        change_id = if ($result) { $result.change_id } else { $null }
        previous_max_id = if ($result) { $result.previous_max_id } else { $null }
        event_type = "DELETED"
        action_started_at = if ($result) { $result.action_started_at } else { $null }
        occurred_at = if ($result) { $result.occurred_at } else { $null }
        detected_at = if ($result) { $result.detected_at } else { $null }
        mttd_seconds = if ($result) { $result.mttd_seconds } else { $null }
        scan_processing_seconds = if ($result) { $result.scan_processing_seconds } else { $null }
        occurred_at_source = if ($result) { $result.source } else { $null }
        baseline_sha256_initial = $expectedRow.baseline_sha256
        baseline_sha256_after = if ($after) { $after.sha256 } else { $null }
        baseline_preserved = $baselinePreserved
        status_after = if ($after) { $after.status } else { $null }
        physical_file_deleted = $physicalDeleted
        event_old_sha256 = if ($changeRecord) { $changeRecord.old_sha256 } else { $null }
        old_hash_matches_baseline = $oldHashMatchesBaseline
        baseline_match_event = if ($changeRecord) { $changeRecord.baseline_match } else { $null }
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
        path = $path
        file_hash_id = $expectedRow.file_hash_id
        change_id = if ($result) { $result.change_id } else { "" }
        previous_max_id = if ($result) { $result.previous_max_id } else { "" }
        occurred_at = if ($result) { $result.occurred_at } else { "" }
        detected_at = if ($result) { $result.detected_at } else { "" }
        mttd_seconds = if ($result -and $null -ne $result.mttd_seconds) { ([double]$result.mttd_seconds).ToString("0.000000", $inv) } else { "" }
        scan_processing_seconds = if ($result -and $null -ne $result.scan_processing_seconds) { ([double]$result.scan_processing_seconds).ToString("0.000000", $inv) } else { "" }
        occurred_at_source = if ($result) { $result.source } else { "" }
        baseline_sha256_initial = $expectedRow.baseline_sha256
        baseline_sha256_after = if ($after) { $after.sha256 } else { "" }
        baseline_preserved = $baselinePreserved
        status_after = if ($after) { $after.status } else { "" }
        physical_file_deleted = $physicalDeleted
        event_old_sha256 = if ($changeRecord) { $changeRecord.old_sha256 } else { "" }
        old_hash_matches_baseline = $oldHashMatchesBaseline
        baseline_match_event = if ($changeRecord -and $null -ne $changeRecord.baseline_match) { $changeRecord.baseline_match } else { "" }
        error = if ($errorText) { $errorText } else { "" }
    }
    $rows.Add($row)

    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ','

    if ($result) {
        Write-Host "[$trialId] $outcome - MTTD: $(([double]$result.mttd_seconds).ToString('0.000000', $inv)) s - change_id=$($result.change_id)"
    }

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
        $median = ($values[($values.Count / 2) - 1] + $values[$values.Count / 2]) / 2
    }

    if ($values.Count -gt 1) {
        $sumSq = 0.0
        foreach ($v in $values) { $sumSq += [Math]::Pow(($v - $mean), 2) }
        $stddevSample = [Math]::Sqrt($sumSq / ($values.Count - 1))
    }
}

$runFinished = [DateTimeOffset]::UtcNow
$summary = [ordered]@{
    protocol = "FORMAL_DELETED_V1"
    run_started_at_utc = $runStarted.ToString("o")
    run_finished_at_utc = $runFinished.ToString("o")
    requested_trials = $Count
    completed_trials = $rows.Count
    detected_valid_trials = $detectedRows.Count
    failed_trials = $failedRows.Count
    invalid_trials = $invalidRows.Count
    valid_trial_rate_over_requested = if ($Count -gt 0) { $detectedRows.Count / [double]$Count } else { $null }
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
Write-Host "FIN SERIE FORMAL DELETED"
Write-Host "Completados: $($rows.Count)/$Count"
Write-Host "Detectados válidos: $($detectedRows.Count)/$Count"
Write-Host "Fallidos: $($failedRows.Count)"
Write-Host "Inválidos por invariantes: $($invalidRows.Count)"
if ($numericMttd.Count -gt 0) {
    Write-Host "MTTD media:   $($mean.ToString('0.000000', $inv)) s"
    Write-Host "MTTD mediana: $($median.ToString('0.000000', $inv)) s"
    Write-Host "MTTD mínimo:  $($minimum.ToString('0.000000', $inv)) s"
    Write-Host "MTTD máximo:  $($maximum.ToString('0.000000', $inv)) s"
    if ($null -ne $stddevSample) {
        Write-Host "Desv. estándar muestral: $($stddevSample.ToString('0.000000', $inv)) s"
    }
}
if ($abortReason) { Write-Host "Abort reason: $abortReason" }
Write-Host "CSV: $csvPath"
Write-Host "Resumen: $summaryPath"
Write-Host "Manifiesto: $manifestPath"
Write-Host "=============================================="
