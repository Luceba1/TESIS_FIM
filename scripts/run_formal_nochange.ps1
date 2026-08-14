param(
    [int]$DurationMinutes = 30,
    [int]$PollSeconds = 2,
    [string]$EnvironmentName = "Experimento NoChange",
    [string]$TestDirectory = "C:\watchdogs_experimento_nochange",
    [int]$FileCount = 10,
    [string]$ApiBase = "http://127.0.0.1:8000/api/v1"
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

function Get-PhysicalSnapshot {
    param([Parameter(Mandatory = $true)][object[]]$BaselineRows)

    $snapshot = @()
    foreach ($row in ($BaselineRows | Sort-Object path)) {
        if (-not (Test-Path -LiteralPath $row.path)) {
            $snapshot += [PSCustomObject]@{
                file_hash_id = $row.id
                path = $row.path
                exists = $false
                length_bytes = $null
                last_write_time_utc = $null
                sha256 = $null
            }
            continue
        }

        $file = Get-Item -LiteralPath $row.path
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $row.path).Hash.ToLowerInvariant()

        $snapshot += [PSCustomObject]@{
            file_hash_id = $row.id
            path = $row.path
            exists = $true
            length_bytes = $file.Length
            last_write_time_utc = $file.LastWriteTimeUtc.ToString("o")
            sha256 = $hash
        }
    }
    return $snapshot
}

if ($DurationMinutes -lt 1) {
    throw "DurationMinutes debe ser al menos 1."
}
if ($PollSeconds -lt 1) {
    throw "PollSeconds debe ser al menos 1."
}

$root = Split-Path -Parent $PSScriptRoot
$evidenceDir = Join-Path $root "evidencias\formal\nochange"
$csvScansPath = Join-Path $evidenceDir "NOCHANGE_scans.csv"
$eventsPath = Join-Path $evidenceDir "NOCHANGE_events.json"
$summaryPath = Join-Path $evidenceDir "NOCHANGE_summary.json"
$manifestPath = Join-Path $evidenceDir "NOCHANGE_manifest.json"
$fullDir = [System.IO.Path]::GetFullPath($TestDirectory)

New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

foreach ($p in @($csvScansPath, $eventsPath, $summaryPath, $manifestPath)) {
    if (Test-Path -LiteralPath $p) {
        throw "Ya existe evidencia formal: $p. No se inicia otra corrida para evitar mezclar resultados."
    }
}

$agentStart = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
if (-not $agentStart.running) {
    throw "El agente FIM no está activo."
}

$environment = @(Get-ApiItems -Uri "$ApiBase/environments") |
    Where-Object { $_.name -eq $EnvironmentName -and $_.enabled -eq $true } |
    Select-Object -First 1

if (-not $environment) {
    throw "No se encontró un entorno activo llamado '$EnvironmentName'."
}

$baselineStart = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
if ($baselineStart.Count -ne $FileCount) {
    throw "Se esperaban $FileCount archivos de baseline y se encontraron $($baselineStart.Count)."
}

$invalidBaseline = @($baselineStart | Where-Object {
    $_.baseline_approved -ne $true -or
    $_.status -ne "ACTIVE" -or
    [string]::IsNullOrWhiteSpace([string]$_.sha256) -or
    ([string]$_.sha256 -ne [string]$_.observed_sha256)
})

if ($invalidBaseline.Count -gt 0) {
    throw "Hay $($invalidBaseline.Count) archivos con baseline/estado inicial inválido."
}

$eventsBefore = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
if ($eventsBefore.Count -ne 0) {
    throw "El entorno ya tiene $($eventsBefore.Count) eventos. El control debe comenzar con cero eventos."
}

$snapshotBefore = @(Get-PhysicalSnapshot -BaselineRows $baselineStart)
if (@($snapshotBefore | Where-Object { -not $_.exists }).Count -gt 0) {
    throw "Falta al menos un archivo físico antes del control."
}

foreach ($snap in $snapshotBefore) {
    $baselineRow = $baselineStart | Where-Object { $_.id -eq $snap.file_hash_id } | Select-Object -First 1
    if ($snap.sha256 -ne ([string]$baselineRow.sha256).ToLowerInvariant()) {
        throw "El hash físico inicial no coincide con baseline: $($snap.path)"
    }
}

$runStarted = [DateTimeOffset]::UtcNow
$durationSeconds = $DurationMinutes * 60
$deadline = $runStarted.AddSeconds($durationSeconds)

$manifest = [ordered]@{
    protocol = "FORMAL_NOCHANGE_V1"
    run_started_at_utc = $runStarted.ToString("o")
    planned_duration_minutes = $DurationMinutes
    planned_integrity_changes = 0
    environment_name = $EnvironmentName
    environment_id = $environment.id
    test_directory = $fullDir
    file_count = $FileCount
    scan_interval_seconds = $agentStart.interval_seconds
    poll_seconds = $PollSeconds
    initial_agent_status = $agentStart
    initial_snapshot = $snapshotBefore
}
$manifest | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath $manifestPath -Encoding UTF8

$scanRows = New-Object System.Collections.Generic.List[object]
$seenScanIds = New-Object 'System.Collections.Generic.HashSet[int]'
$initialLastScanId = if ($null -ne $agentStart.last_scan_id) { [int]$agentStart.last_scan_id } else { 0 }
$lastProgressMinute = -1
$pollErrors = New-Object System.Collections.Generic.List[string]

Write-Host "=============================================="
Write-Host "CONTROL FORMAL SIN CAMBIOS"
Write-Host "Entorno: $EnvironmentName (#$($environment.id))"
Write-Host "Archivos estables: $FileCount"
Write-Host "Cambios planificados: 0"
Write-Host "Duración: $DurationMinutes minutos"
Write-Host "Intervalo FIM: $($agentStart.interval_seconds) s"
Write-Host "No modifique ningún archivo en: $fullDir"
Write-Host "=============================================="

while ([DateTimeOffset]::UtcNow -lt $deadline) {
    try {
        $status = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"

        if (-not $status.running) {
            $pollErrors.Add("El agente dejó de estar activo a $([DateTimeOffset]::UtcNow.ToString('o')).")
        }

        if ($null -ne $status.last_scan_id) {
            $sid = [int]$status.last_scan_id
            if ($sid -gt $initialLastScanId -and $seenScanIds.Add($sid)) {
                $scanRows.Add([PSCustomObject]@{
                    observed_at_utc = [DateTimeOffset]::UtcNow.ToString("o")
                    scan_id = $sid
                    scan_at = $status.last_scan_at
                    scan_status = $status.status
                    message = $status.message
                    last_error = $status.last_error
                })

                $scanRows | Export-Csv -LiteralPath $csvScansPath -NoTypeInformation -Encoding UTF8 -Delimiter ','
            }
        }
    }
    catch {
        $pollErrors.Add("$([DateTimeOffset]::UtcNow.ToString('o')) - $($_.Exception.Message)")
    }

    $elapsedMinutes = [int][Math]::Floor(([DateTimeOffset]::UtcNow - $runStarted).TotalMinutes)
    if ($elapsedMinutes -ne $lastProgressMinute) {
        $lastProgressMinute = $elapsedMinutes
        $currentEvents = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
        Write-Host ("Minuto {0}/{1} - scans observados: {2} - eventos: {3}" -f `
            $elapsedMinutes, $DurationMinutes, $scanRows.Count, $currentEvents.Count)
    }

    Start-Sleep -Seconds $PollSeconds
}

$runFinished = [DateTimeOffset]::UtcNow
$agentEnd = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
$eventsAfter = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
$baselineEnd = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")
$snapshotAfter = @(Get-PhysicalSnapshot -BaselineRows $baselineEnd)

$eventsAfter | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath $eventsPath -Encoding UTF8

$contentChanges = New-Object System.Collections.Generic.List[object]
$metadataChanges = New-Object System.Collections.Generic.List[object]
$baselineProblems = New-Object System.Collections.Generic.List[object]
$lastSeenAdvancedCount = 0

foreach ($before in $snapshotBefore) {
    $after = $snapshotAfter |
        Where-Object { $_.file_hash_id -eq $before.file_hash_id } |
        Select-Object -First 1

    $baseStartRow = $baselineStart |
        Where-Object { $_.id -eq $before.file_hash_id } |
        Select-Object -First 1

    $baseEndRow = $baselineEnd |
        Where-Object { $_.id -eq $before.file_hash_id } |
        Select-Object -First 1

    if (-not $after -or -not $after.exists -or $after.sha256 -ne $before.sha256 -or $after.length_bytes -ne $before.length_bytes) {
        $contentChanges.Add([PSCustomObject]@{
            path = $before.path
            before = $before
            after = $after
        })
    }

    if ($after -and $after.last_write_time_utc -ne $before.last_write_time_utc) {
        $metadataChanges.Add([PSCustomObject]@{
            path = $before.path
            before_last_write_time_utc = $before.last_write_time_utc
            after_last_write_time_utc = $after.last_write_time_utc
        })
    }

    if (
        -not $baseEndRow -or
        $baseEndRow.baseline_approved -ne $true -or
        $baseEndRow.status -ne "ACTIVE" -or
        ([string]$baseEndRow.sha256 -ne [string]$baseStartRow.sha256) -or
        ([string]$baseEndRow.observed_sha256 -ne [string]$baseStartRow.observed_sha256)
    ) {
        $baselineProblems.Add([PSCustomObject]@{
            path = $before.path
            start = $baseStartRow
            end = $baseEndRow
        })
    }

    if ($baseEndRow -and $baseEndRow.last_seen_at) {
        try {
            $seen = [DateTimeOffset]::Parse([string]$baseEndRow.last_seen_at).ToUniversalTime()
            if ($seen -gt $runStarted) {
                $lastSeenAdvancedCount++
            }
        }
        catch {}
    }
}

$okScans = @($scanRows | Where-Object { $_.scan_status -eq "OK" }).Count
$partialScans = @($scanRows | Where-Object { $_.scan_status -eq "PARTIAL" }).Count
$errorScans = @($scanRows | Where-Object { $_.scan_status -eq "ERROR" }).Count

$physicalStateUnchanged =
    ($contentChanges.Count -eq 0) -and
    ($metadataChanges.Count -eq 0)

$baselineStateUnchanged = ($baselineProblems.Count -eq 0)
$zeroEvents = ($eventsAfter.Count -eq 0)
$agentStayedHealthy = ($pollErrors.Count -eq 0) -and $agentEnd.running
$allFilesSeenDuringWindow = ($lastSeenAdvancedCount -eq $FileCount)

$outcome = if (
    $zeroEvents -and
    $physicalStateUnchanged -and
    $baselineStateUnchanged -and
    $agentStayedHealthy -and
    $allFilesSeenDuringWindow
) {
    "VALID_NO_SPURIOUS_EVENTS_OBSERVED"
}
elseif (-not $physicalStateUnchanged) {
    "INVALID_ENVIRONMENTAL_CHANGE_DETECTED"
}
elseif (-not $zeroEvents) {
    "EVENTS_OBSERVED_REQUIRES_REVIEW"
}
else {
    "INVALID_CONTROL_CONDITIONS"
}

$approxFileScanOpportunities = $scanRows.Count * $FileCount
$observedSpuriousRatePerScan = if ($scanRows.Count -gt 0) {
    $eventsAfter.Count / [double]$scanRows.Count
} else { $null }
$observedSpuriousRatePerFileScanOpportunity = if ($approxFileScanOpportunities -gt 0) {
    $eventsAfter.Count / [double]$approxFileScanOpportunities
} else { $null }

$summary = [ordered]@{
    protocol = "FORMAL_NOCHANGE_V1"
    outcome = $outcome
    run_started_at_utc = $runStarted.ToString("o")
    run_finished_at_utc = $runFinished.ToString("o")
    actual_duration_seconds = ($runFinished - $runStarted).TotalSeconds
    planned_integrity_changes = 0
    observed_events = $eventsAfter.Count
    observed_spurious_events = if ($physicalStateUnchanged) { $eventsAfter.Count } else { $null }
    file_count = $FileCount
    scan_cycles_observed = $scanRows.Count
    scan_cycles_ok = $okScans
    scan_cycles_partial = $partialScans
    scan_cycles_error = $errorScans
    approximate_file_scan_opportunities = $approxFileScanOpportunities
    observed_spurious_event_rate_per_scan = $observedSpuriousRatePerScan
    observed_spurious_event_rate_per_file_scan_opportunity = $observedSpuriousRatePerFileScanOpportunity
    physical_content_changes = $contentChanges.Count
    physical_metadata_changes = $metadataChanges.Count
    physical_state_unchanged = $physicalStateUnchanged
    baseline_problems = $baselineProblems.Count
    baseline_state_unchanged = $baselineStateUnchanged
    files_with_last_seen_after_start = $lastSeenAdvancedCount
    all_files_seen_during_window = $allFilesSeenDuringWindow
    poll_or_agent_errors = $pollErrors.Count
    agent_running_at_end = $agentEnd.running
    events = $eventsAfter
    content_change_details = $contentChanges
    metadata_change_details = $metadataChanges
    baseline_problem_details = $baselineProblems
    poll_errors = $pollErrors
    scans_csv = $csvScansPath
    events_json = $eventsPath
    manifest_json = $manifestPath
}
$summary | ConvertTo-Json -Depth 14 |
    Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "=============================================="
Write-Host "FIN CONTROL FORMAL SIN CAMBIOS"
Write-Host "Resultado: $outcome"
Write-Host "Duración real: $((($runFinished - $runStarted).TotalMinutes).ToString('0.00', $inv)) min"
Write-Host "Scans observados: $($scanRows.Count)"
Write-Host "Scans OK: $okScans"
Write-Host "Scans PARTIAL: $partialScans"
Write-Host "Scans ERROR: $errorScans"
Write-Host "Archivos estables: $FileCount"
Write-Host "Oportunidades archivo-scan aprox.: $approxFileScanOpportunities"
Write-Host "Cambios físicos de contenido: $($contentChanges.Count)"
Write-Host "Cambios físicos de metadata: $($metadataChanges.Count)"
Write-Host "Problemas de baseline: $($baselineProblems.Count)"
Write-Host "Archivos observados durante la ventana: $lastSeenAdvancedCount/$FileCount"
Write-Host "Eventos generados en el entorno: $($eventsAfter.Count)"
if ($null -ne $observedSpuriousRatePerScan) {
    Write-Host "Tasa observada de eventos espurios por scan: $((100 * $observedSpuriousRatePerScan).ToString('0.000000', $inv)) %"
}
if ($null -ne $observedSpuriousRatePerFileScanOpportunity) {
    Write-Host "Tasa observada por oportunidad archivo-scan: $((100 * $observedSpuriousRatePerFileScanOpportunity).ToString('0.000000', $inv)) %"
}
Write-Host "Errores de control/agente: $($pollErrors.Count)"
Write-Host "CSV scans: $csvScansPath"
Write-Host "Eventos: $eventsPath"
Write-Host "Resumen: $summaryPath"
Write-Host "Manifiesto: $manifestPath"
Write-Host "=============================================="

if ($outcome -eq "VALID_NO_SPURIOUS_EVENTS_OBSERVED") {
    Write-Host ""
    Write-Host "Interpretación válida: no se observaron eventos espurios durante esta ventana controlada."
    Write-Host "No interprete este resultado como una demostración de que la tasa verdadera de falsos positivos sea exactamente 0%."
}
