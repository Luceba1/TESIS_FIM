param(
    [string]$EnvironmentName = "Experimento MTTR Formal",
    [string]$TestDirectory = "C:\watchdogs_experimento_mttr_formal",
    [string]$ApiBase = "http://127.0.0.1:8000/api/v1",
    [int]$DetectionTimeoutSeconds = 30,
    [int]$ReviewTimeoutSeconds = 300,
    [int]$Seed = 20260814
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

$root = Split-Path -Parent $PSScriptRoot
$evidenceDir = Join-Path $root "evidencias\formal\mttr"
$csvPath = Join-Path $evidenceDir "MTTR_formal.csv"
$summaryPath = Join-Path $evidenceDir "MTTR_summary.json"
$manifestPath = Join-Path $evidenceDir "MTTR_manifest.json"

New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

foreach ($p in @($csvPath, $summaryPath, $manifestPath)) {
    if (Test-Path -LiteralPath $p) {
        throw "Ya existe evidencia formal MTTR: $p"
    }
}

$agent = Invoke-RestMethod -Method Get -Uri "$ApiBase/agent/status"
if (-not $agent.running) {
    throw "El agente FIM no está activo."
}

$environment = @(Get-ApiItems -Uri "$ApiBase/environments") |
    Where-Object { $_.name -eq $EnvironmentName -and $_.enabled -eq $true } |
    Select-Object -First 1

if (-not $environment) {
    throw "No se encontró '$EnvironmentName'."
}

$fullDir = [System.IO.Path]::GetFullPath($TestDirectory)
$baselineRows = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)")

if ($baselineRows.Count -ne 20) {
    throw "Se esperaban 20 archivos en baseline y se encontraron $($baselineRows.Count)."
}

$pending = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)") |
    Where-Object { $_.review_status -eq "PENDING" }

if ($pending.Count -gt 0) {
    throw "Hay eventos PENDING previos. El experimento formal debe empezar limpio."
}

# 10 MANUAL + 10 ASSISTED, aleatorizados con semilla fija.
$conditions = New-Object System.Collections.Generic.List[string]
1..10 | ForEach-Object { $conditions.Add("MANUAL") }
1..10 | ForEach-Object { $conditions.Add("ASSISTED") }

$rng = [System.Random]::new($Seed)
for ($i = $conditions.Count - 1; $i -gt 0; $i--) {
    $j = $rng.Next(0, $i + 1)
    $tmp = $conditions[$i]
    $conditions[$i] = $conditions[$j]
    $conditions[$j] = $tmp
}

$schedule = @()
for ($i = 1; $i -le 20; $i++) {
    $schedule += [PSCustomObject]@{
        trial_number = $i
        trial_id = "FORMAL-MTTR-{0:D3}" -f $i
        condition = $conditions[$i - 1]
        path = [System.IO.Path]::GetFullPath((Join-Path $fullDir ("mttr_{0:D3}.txt" -f $i)))
    }
}

$manifest = [ordered]@{
    protocol = "FORMAL_MTTR_CONSOLE_VS_DASHBOARD_V1"
    operator_count = 1
    operator = "single human operator"
    event_type = "MODIFIED"
    total_trials = 20
    manual_trials = 10
    assisted_trials = 10
    random_seed = $Seed
    environment_name = $EnvironmentName
    environment_id = $environment.id
    scan_interval_seconds = $agent.interval_seconds
    test_directory = $fullDir
    schedule = $schedule
    mttr_definition = "reviewed_at - detected_at"
}
$manifest | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath $manifestPath -Encoding UTF8

$rows = New-Object System.Collections.Generic.List[object]

Write-Host "=============================================="
Write-Host "SERIE FORMAL MTTR"
Write-Host "20 ensayos: 10 MANUAL + 10 ASSISTED"
Write-Host "Orden aleatorizado reproducible. Seed: $Seed"
Write-Host "MTTR = reviewed_at - detected_at"
Write-Host ""
Write-Host "IMPORTANTE:"
Write-Host "- MANUAL: no mirar el frontend."
Write-Host "- ASSISTED: no investigar por PowerShell."
Write-Host "- No intentar hacer las pruebas como carrera."
Write-Host "=============================================="

foreach ($trial in $schedule) {
    $path = [string]$trial.path
    $trialId = [string]$trial.trial_id
    $condition = [string]$trial.condition

    if (-not (Test-Path -LiteralPath $path)) {
        throw "${trialId}: falta el archivo físico $path."
    }

    $currentBaseline = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)") |
        Where-Object {
            try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $path }
            catch { $false }
        } |
        Select-Object -First 1

    if (-not $currentBaseline -or
        $currentBaseline.baseline_approved -ne $true -or
        $currentBaseline.status -ne "ACTIVE") {
        throw "${trialId}: baseline inicial inválida."
    }

    $baselineSha = [string]$currentBaseline.sha256

    Write-Host ""
    Write-Host "----------------------------------------------------------"
    Write-Host "$trialId"
    Write-Host "CONDICIÓN: $condition"
    Write-Host ""
    if ($condition -eq "MANUAL") {
        Write-Host "Prepará la ventana PowerShell de revisión manual."
        Write-Host "Minimizá/no mires el frontend."
    }
    else {
        Write-Host "Prepará el frontend en '$EnvironmentName'."
        Write-Host "No uses PowerShell para investigar el evento."
    }
    Read-Host "Cuando estés listo, presioná ENTER para generar el evento"

    $existing = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
    $previousMaxId = 0
    foreach ($e in $existing) {
        try {
            if ([int]$e.id -gt $previousMaxId) { $previousMaxId = [int]$e.id }
        }
        catch {}
    }

    $actionStarted = [DateTimeOffset]::UtcNow
    Add-Content -LiteralPath $path `
        -Value "`nWatchDogs FIM - $trialId - $condition - $($actionStarted.ToString('o'))" `
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
                    ([System.IO.Path]::GetFullPath([string]$_.path) -ieq $path) -and
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
        throw "${trialId}: no se detectó el MODIFIED dentro de $DetectionTimeoutSeconds s."
    }

    $payload = @{
        occurred_at = $occurredAt.ToString("o")
        source = "EXPERIMENT_CONTROLLED_MTTR_FORMAL"
    } | ConvertTo-Json -Compress

    $change = Invoke-RestMethod `
        -Method Patch `
        -Uri "$ApiBase/changes/$($change.id)/event-time" `
        -ContentType "application/json" `
        -Body $payload

    Write-Host ""
    Write-Host ">>> EVENTO DETECTADO. COMENZÁ LA REVISIÓN $condition AHORA. <<<"
    if ($condition -eq "MANUAL") {
        Write-Host "Usá únicamente el protocolo PowerShell manual."
    }
    else {
        Write-Host "Usá únicamente el frontend."
    }

    $reviewDeadline = (Get-Date).AddSeconds($ReviewTimeoutSeconds)
    $reviewed = $null

    while ((Get-Date) -lt $reviewDeadline) {
        $changes = @(Get-ApiItems -Uri "$ApiBase/changes?environment_id=$($environment.id)")
        $reviewed = $changes |
            Where-Object { [int]$_.id -eq [int]$change.id } |
            Select-Object -First 1

        if ($reviewed -and $reviewed.review_status -ne "PENDING") { break }
        Start-Sleep -Milliseconds 250
    }

    if (-not $reviewed -or $reviewed.review_status -eq "PENDING") {
        throw "${trialId}: no se registró REVIEWED dentro de $ReviewTimeoutSeconds s."
    }

    $baselineAfter = @(Get-ApiItems -Uri "$ApiBase/baseline?environment_id=$($environment.id)") |
        Where-Object {
            try { [System.IO.Path]::GetFullPath([string]$_.path) -ieq $path }
            catch { $false }
        } |
        Select-Object -First 1

    $baselinePreserved = (
        $baselineAfter -and
        $baselineAfter.baseline_approved -eq $true -and
        ([string]$baselineAfter.sha256 -eq $baselineSha)
    )

    $row = [PSCustomObject]@{
        trial_id = $trialId
        trial_number = [int]$trial.trial_number
        condition = $condition
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
        baseline_preserved = $baselinePreserved
    }

    $rows.Add($row)
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    $jsonPath = Join-Path $evidenceDir ("{0}.json" -f $trialId)
    $row | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $jsonPath -Encoding UTF8

    Write-Host "$trialId COMPLETADO - $condition - MTTR: $([double]$reviewed.response_time_seconds) s"

    if (-not $baselinePreserved) {
        throw "${trialId}: la baseline fue alterada. Se detiene la serie."
    }
}

function Get-Stats {
    param([object[]]$InputRows)

    $vals = @($InputRows | ForEach-Object { [double]$_.mttr_seconds } | Sort-Object)
    $mean = ($vals | Measure-Object -Average).Average
    $min = $vals[0]
    $max = $vals[-1]

    if (($vals.Count % 2) -eq 1) {
        $median = $vals[[int][Math]::Floor($vals.Count / 2)]
    }
    else {
        $median = ($vals[($vals.Count / 2) - 1] + $vals[$vals.Count / 2]) / 2
    }

    $std = $null
    if ($vals.Count -gt 1) {
        $ss = 0.0
        foreach ($v in $vals) { $ss += [Math]::Pow($v - $mean, 2) }
        $std = [Math]::Sqrt($ss / ($vals.Count - 1))
    }

    [PSCustomObject]@{
        n = $vals.Count
        mean_seconds = $mean
        median_seconds = $median
        min_seconds = $min
        max_seconds = $max
        sample_stddev_seconds = $std
    }
}

$manualRows = @($rows | Where-Object { $_.condition -eq "MANUAL" })
$assistedRows = @($rows | Where-Object { $_.condition -eq "ASSISTED" })

$manualStats = Get-Stats -InputRows $manualRows
$assistedStats = Get-Stats -InputRows $assistedRows

$meanDifference = $manualStats.mean_seconds - $assistedStats.mean_seconds
$relativeReduction = if ($manualStats.mean_seconds -gt 0) {
    100 * $meanDifference / $manualStats.mean_seconds
} else { $null }

$summary = [ordered]@{
    protocol = "FORMAL_MTTR_CONSOLE_VS_DASHBOARD_V1"
    total_trials = $rows.Count
    manual = $manualStats
    assisted = $assistedStats
    mean_difference_seconds_manual_minus_assisted = $meanDifference
    relative_mean_reduction_percent = $relativeReduction
    csv = $csvPath
    manifest = $manifestPath
}
$summary | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "=============================================="
Write-Host "FIN SERIE FORMAL MTTR"
Write-Host "Total: $($rows.Count)/20"
Write-Host ""
Write-Host "MANUAL (n=$($manualStats.n))"
Write-Host "Media:   $($manualStats.mean_seconds.ToString('0.000000', $inv)) s"
Write-Host "Mediana: $($manualStats.median_seconds.ToString('0.000000', $inv)) s"
Write-Host "Mínimo:  $($manualStats.min_seconds.ToString('0.000000', $inv)) s"
Write-Host "Máximo:  $($manualStats.max_seconds.ToString('0.000000', $inv)) s"
Write-Host "Desv.:   $($manualStats.sample_stddev_seconds.ToString('0.000000', $inv)) s"
Write-Host ""
Write-Host "ASSISTED (n=$($assistedStats.n))"
Write-Host "Media:   $($assistedStats.mean_seconds.ToString('0.000000', $inv)) s"
Write-Host "Mediana: $($assistedStats.median_seconds.ToString('0.000000', $inv)) s"
Write-Host "Mínimo:  $($assistedStats.min_seconds.ToString('0.000000', $inv)) s"
Write-Host "Máximo:  $($assistedStats.max_seconds.ToString('0.000000', $inv)) s"
Write-Host "Desv.:   $($assistedStats.sample_stddev_seconds.ToString('0.000000', $inv)) s"
Write-Host ""
Write-Host "Diferencia media MANUAL - ASSISTED: $($meanDifference.ToString('0.000000', $inv)) s"
if ($null -ne $relativeReduction) {
    Write-Host "Reducción media relativa observada: $($relativeReduction.ToString('0.000', $inv)) %"
}
Write-Host "CSV: $csvPath"
Write-Host "Resumen: $summaryPath"
Write-Host "Manifiesto: $manifestPath"
Write-Host "=============================================="
