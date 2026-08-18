param($Timer)

# Incremental design: only reads blobs for dates not yet processed.
# Normal runs touch today + yesterday only. METRICS_LOOKBACK_DAYS controls backfill depth only.

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'CloudEnvironment.ps1')

$cloudEnvironment = Get-ConfiguredValue -Value $env:CLOUD_ENVIRONMENT   -DefaultValue 'Commercial'
$cloud            = Get-CloudEnvironmentConfiguration -CloudEnvironment $cloudEnvironment
$storageAccount   = $env:STORAGE_ACCOUNT_NAME
$container        = Get-ConfiguredValue -Value $env:STORAGE_CONTAINER_NAME -DefaultValue 'copilot-logs'
$storageSuffix    = Get-ConfiguredValue -Value $env:STORAGE_SUFFIX         -DefaultValue $cloud.StorageSuffix
$storageAudience  = Get-ConfiguredValue -Value $env:STORAGE_AUDIENCE       -DefaultValue $cloud.StorageAudience
$spSiteUrl        = $env:SHAREPOINT_SITE_URL
$spDailyList      = Get-ConfiguredValue -Value $env:SHAREPOINT_DAILY_LIST       -DefaultValue 'CopilotDailyMetrics'
$spAppList        = Get-ConfiguredValue -Value $env:SHAREPOINT_APP_LIST         -DefaultValue 'CopilotAppMetrics'
$spWeeklyList     = Get-ConfiguredValue -Value $env:SHAREPOINT_WEEKLY_LIST      -DefaultValue 'CopilotWeeklyMetrics'
$spWeeklyAppList  = Get-ConfiguredValue -Value $env:SHAREPOINT_WEEKLY_APP_LIST  -DefaultValue 'CopilotWeeklyAppMetrics'
# METRICS_LOOKBACK_DAYS: only used for backfill. Normal runs process today + yesterday only.
$lookbackDays     = [int](Get-ConfiguredValue -Value $env:METRICS_LOOKBACK_DAYS -DefaultValue '7')

if ([string]::IsNullOrWhiteSpace($spSiteUrl)) {
    Write-Warning 'SHAREPOINT_SITE_URL is not configured. Skipping export.'
    return
}

function Get-ManagedToken {
    param([string]$Resource)
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    (Invoke-RestMethod -Uri $tokenUri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }).access_token
}

$storageToken = Get-ManagedToken -Resource $storageAudience
$spUri        = [System.Uri]$spSiteUrl
$spToken      = Get-ManagedToken -Resource "$($spUri.Scheme)://$($spUri.Host)"

$baseUrl    = "https://$storageAccount.$storageSuffix/$container"
$storageHdr = @{ 'Authorization' = "Bearer $storageToken"; 'x-ms-version' = '2021-08-06' }
$today      = (Get-Date).ToUniversalTime().Date
$yesterday  = $today.AddDays(-1)
$todayStr   = $today.ToString('yyyy-MM-dd')
$yestStr    = $yesterday.ToString('yyyy-MM-dd')

# ── Load state ───────────────────────────────────────────────────────────────
$exportStateUri = "${baseUrl}/_state/exportedDates.json"
$aggregatesUri  = "${baseUrl}/_state/dailyAggregates.json"
$firstSeenUri   = "${baseUrl}/_state/firstSeen.json"

$exportedDates   = @{}
$dailyAggregates = @{}
$firstSeenMap    = @{}

try { $d = Invoke-RestMethod -Uri $exportStateUri -Headers $storageHdr; foreach ($item in @($d)) { $exportedDates[$item] = $true } }
catch { Write-Host 'No export state; will process all dates in lookback window.' }

try { $a = Invoke-RestMethod -Uri $aggregatesUri -Headers $storageHdr; foreach ($prop in $a.PSObject.Properties) { $dailyAggregates[$prop.Name] = $prop.Value } }
catch { Write-Host 'No daily aggregates cache.' }

try { $fs = Invoke-RestMethod -Uri $firstSeenUri -Headers $storageHdr; foreach ($prop in $fs.PSObject.Properties) { $firstSeenMap[$prop.Name] = $prop.Value } }
catch { Write-Host 'No firstSeen cache.' }

# ── Determine which dates to process ────────────────────────────────────────
# Always: today (incomplete) and yesterday (late-arriving events).
# Also any unprocessed date within the lookback window (for backfill).
$datesToProcess = [System.Collections.Generic.List[string]]::new()
for ($d = $today.AddDays(-$lookbackDays); $d -le $today; $d = $d.AddDays(1)) {
    $ds = $d.ToString('yyyy-MM-dd')
    if ($ds -eq $todayStr -or $ds -eq $yestStr -or -not $exportedDates.ContainsKey($ds)) {
        $datesToProcess.Add($ds)
    }
}
Write-Host "Dates to process: $($datesToProcess.Count) — $($datesToProcess -join ', ')"
if ($datesToProcess.Count -eq 0) { Write-Host 'Nothing to do.'; return }

# ── Helper: read all events from blob storage for a single date ──────────────
function Read-DayEvents {
    param([string]$DateStr)
    $events = [System.Collections.Generic.List[pscustomobject]]::new()
    $enc    = [System.Uri]::EscapeDataString(([datetime]$DateStr).ToString('yyyy/MM/dd'))
    $uri    = "${baseUrl}?restype=container&comp=list&prefix=${enc}&maxresults=1000"
    while ($uri) {
        $xml   = [xml](Invoke-WebRequest -Uri $uri -Headers $storageHdr -UseBasicParsing).Content.TrimStart([char]0xFEFF)
        $nodes = $xml.EnumerationResults.Blobs.Blob
        $names = if ($nodes) { @($nodes | Where-Object { $_.Name -and $_.Name.EndsWith('.json') } | Select-Object -ExpandProperty Name) } else { @() }
        foreach ($name in $names) {
            try {
                $raw  = Invoke-RestMethod -Uri "${baseUrl}/${name}" -Headers $storageHdr
                $evts = if ($raw -is [array]) { $raw } else { @($raw) }
                foreach ($e in $evts) {
                    if (-not $e.UserId) { continue }
                    $events.Add([pscustomobject]@{
                        UserId  = [string]$e.UserId
                        AppHost = if ($e.CopilotEventData.AppHost) { [string]$e.CopilotEventData.AppHost }
                                  elseif ($e.AppHost)              { [string]$e.AppHost }
                                  else                             { 'Copilot Chat' }
                    })
                }
            } catch { Write-Warning "Skipping ${name}: $($_.Exception.Message)" }
        }
        $marker = $xml.EnumerationResults.NextMarker
        $uri    = if ($marker) { "${baseUrl}?restype=container&comp=list&prefix=${enc}&maxresults=1000&marker=$([System.Uri]::EscapeDataString($marker))" } else { $null }
    }
    return ,$events
}

function Get-WeekStart {
    param([datetime]$Date)
    $dow = [int]$Date.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
    $Date.AddDays(1 - $dow).Date
}

# ── Process each date: compute aggregates, update firstSeen, save state ──────
foreach ($dateStr in $datesToProcess) {
    Write-Host "Processing $dateStr ..."
    $events = Read-DayEvents -DateStr $dateStr

    if ($events.Count -eq 0) {
        Write-Host "  No events."
        continue
    }

    foreach ($e in $events) {
        if (-not $firstSeenMap.ContainsKey($e.UserId)) { $firstSeenMap[$e.UserId] = $dateStr }
    }

    $appCounts = @{}; $appUsers = @{}
    foreach ($e in $events) {
        if (-not $appCounts.ContainsKey($e.AppHost)) { $appCounts[$e.AppHost] = 0; $appUsers[$e.AppHost] = [System.Collections.Generic.HashSet[string]]::new() }
        $appCounts[$e.AppHost]++
        $appUsers[$e.AppHost].Add($e.UserId) | Out-Null
    }

    $appUserCounts = @{}
    foreach ($app in $appUsers.Keys) { $appUserCounts[$app] = $appUsers[$app].Count }

    $dailyAggregates[$dateStr] = [pscustomobject]@{
        dau          = ($events.UserId | Select-Object -Unique).Count
        interactions = $events.Count
        newUsers     = @($firstSeenMap.GetEnumerator() | Where-Object { $_.Value -eq $dateStr }).Count
        appCounts    = [pscustomobject]$appCounts
        appUsers     = [pscustomobject]$appUserCounts
    }

}

# ── Persist computed data (not yet marking dates as done) ────────────────────
$saveHdr = @{ 'Authorization' = "Bearer $storageToken"; 'x-ms-version' = '2021-08-06'; 'x-ms-blob-type' = 'BlockBlob'; 'Content-Type' = 'application/json' }
Invoke-RestMethod -Uri $firstSeenUri -Method PUT -Headers $saveHdr -Body ($firstSeenMap   | ConvertTo-Json -Compress -Depth 2) | Out-Null
Invoke-RestMethod -Uri $aggregatesUri -Method PUT -Headers $saveHdr -Body ($dailyAggregates | ConvertTo-Json -Compress -Depth 5) | Out-Null

# ── Write to SharePoint ───────────────────────────────────────────────────────
# Fetch all existing items from a list once, delete those whose Title is in the
# provided set (in-memory filter avoids unreliable OData filter on the server).
function Clear-SpTitles {
    param([string]$ListUrl, [string]$Token, [System.Collections.Generic.HashSet[string]]$Titles)
    $readHdr  = @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/json;odata=nometadata' }
    $writeHdr = @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/json;odata=nometadata'; 'Content-Type' = 'application/json;odata=nometadata' }
    $all = try { (Invoke-RestMethod -Uri "${ListUrl}?`$select=Id,Title&`$top=5000" -Headers $readHdr).value } catch { @() }
    foreach ($item in @($all)) {
        if (-not $item -or -not $item.Id -or -not $Titles.Contains($item.Title)) { continue }
        $delHdr = $writeHdr.Clone(); $delHdr['IF-MATCH'] = '*'; $delHdr['X-HTTP-Method'] = 'DELETE'
        Invoke-WebRequest -Uri "${ListUrl}($($item.Id))" -Method POST -Headers $delHdr -UseBasicParsing | Out-Null
    }
}

function Write-SpItem {
    param([string]$ListUrl, [string]$Token, [string]$Title, [hashtable]$Fields)
    $Fields['Title'] = $Title
    $writeHdr = @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/json;odata=nometadata'; 'Content-Type' = 'application/json;odata=nometadata' }
    Invoke-RestMethod -Uri $ListUrl -Method POST -Headers $writeHdr -Body ($Fields | ConvertTo-Json -Compress) | Out-Null
    Write-Host "  Written: $Title"
}

$dailyApiBase     = "$spSiteUrl/_api/web/lists/getbytitle('$spDailyList')/items"
$appApiBase       = "$spSiteUrl/_api/web/lists/getbytitle('$spAppList')/items"
$weeklyApiBase    = "$spSiteUrl/_api/web/lists/getbytitle('$spWeeklyList')/items"
$weeklyAppApiBase = "$spSiteUrl/_api/web/lists/getbytitle('$spWeeklyAppList')/items"

# Build title sets from ALL historical aggregates (not just datesToProcess) so
# SharePoint always receives a complete snapshot even if lists were manually cleared.
$allAggDates    = @($dailyAggregates.Keys | Sort-Object)
$dailyTitles    = [System.Collections.Generic.HashSet[string]]::new()
$appTitles      = [System.Collections.Generic.HashSet[string]]::new()
$weeklyTitles   = [System.Collections.Generic.HashSet[string]]::new()
$weeklyAppTitles= [System.Collections.Generic.HashSet[string]]::new()

foreach ($dateStr in $allAggDates) {
    $agg = $dailyAggregates[$dateStr]; if (-not $agg) { continue }
    $dailyTitles.Add($dateStr) | Out-Null
    foreach ($app in $agg.appCounts.PSObject.Properties) { $appTitles.Add("$dateStr|$($app.Name)") | Out-Null }
}
$allWeeks = $allAggDates | ForEach-Object { (Get-WeekStart ([datetime]$_)).ToString('yyyy-MM-dd') } | Select-Object -Unique
$affectedWeeks = $datesToProcess | ForEach-Object { (Get-WeekStart ([datetime]$_)).ToString('yyyy-MM-dd') } | Select-Object -Unique
foreach ($ws in $allWeeks) {
    $weeklyTitles.Add($ws) | Out-Null
    $wsDays = 0..6 | ForEach-Object { ([datetime]$ws).AddDays($_).ToString('yyyy-MM-dd') }
    foreach ($wd in $wsDays) {
        $agg = $dailyAggregates[$wd]; if (-not $agg) { continue }
        foreach ($app in $agg.appCounts.PSObject.Properties) { $weeklyAppTitles.Add("$ws|$($app.Name)") | Out-Null }
    }
}

# One bulk read + delete per list, then write complete snapshot
Write-Host "Clearing stale SharePoint rows..."
Clear-SpTitles -ListUrl $dailyApiBase     -Token $spToken -Titles $dailyTitles
Clear-SpTitles -ListUrl $appApiBase       -Token $spToken -Titles $appTitles
Clear-SpTitles -ListUrl $weeklyApiBase    -Token $spToken -Titles $weeklyTitles
Clear-SpTitles -ListUrl $weeklyAppApiBase -Token $spToken -Titles $weeklyAppTitles

Write-Host "Writing daily and app rows..."
foreach ($dateStr in $allAggDates) {
    $agg = $dailyAggregates[$dateStr]
    if (-not $agg) { continue }

    Write-SpItem -ListUrl $dailyApiBase -Token $spToken -Title $dateStr -Fields @{
        MetricDate        = $dateStr
        DAU               = $agg.dau
        TotalInteractions = $agg.interactions
        NewUsers          = $agg.newUsers
    }

    foreach ($app in $agg.appCounts.PSObject.Properties) {
        $uCount = if ($agg.appUsers) { ($agg.appUsers.PSObject.Properties | Where-Object { $_.Name -eq $app.Name } | Select-Object -ExpandProperty Value) } else { 0 }
        Write-SpItem -ListUrl $appApiBase -Token $spToken -Title "$dateStr|$($app.Name)" -Fields @{
            MetricDate   = $dateStr
            AppHost      = $app.Name
            Interactions = $app.Value
            Users        = [int]$uCount
        }
    }
}

# ── Weekly rollup — recompute from stored daily aggregates, no blob re-reads ─
Write-Host "Writing $($allWeeks.Count) week(s)..."
foreach ($ws in $allWeeks) {
    $we       = ([datetime]$ws).AddDays(6).ToString('yyyy-MM-dd')
    $weekDays = 0..6 | ForEach-Object { ([datetime]$ws).AddDays($_).ToString('yyyy-MM-dd') }
    $totalInter = 0; $totalDAU = 0; $totalNew = 0
    $appWkCounts = @{}; $appWkUsers = @{}; $allApps = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($wd in $weekDays) {
        $agg = $dailyAggregates[$wd]; if (-not $agg) { continue }
        $totalInter += $agg.interactions
        $totalDAU   += $agg.dau
        $totalNew   += $agg.newUsers
        foreach ($app in $agg.appCounts.PSObject.Properties) {
            $allApps.Add($app.Name) | Out-Null
            if (-not $appWkCounts.ContainsKey($app.Name)) { $appWkCounts[$app.Name] = 0; $appWkUsers[$app.Name] = 0 }
            $appWkCounts[$app.Name] += $app.Value
            $u = ($agg.appUsers.PSObject.Properties | Where-Object { $_.Name -eq $app.Name } | Select-Object -ExpandProperty Value)
            $appWkUsers[$app.Name] += [int]$u
        }
    }

    Write-SpItem -ListUrl $weeklyApiBase -Token $spToken -Title $ws -Fields @{
        WeekStart         = $ws
        WeekEnd           = $we
        TotalInteractions = $totalInter
        UniqueUsers       = $totalDAU
        NewUsers          = $totalNew
        AppsUsed          = ($allApps | Sort-Object) -join ', '
    }

    foreach ($app in $appWkCounts.Keys) {
        Write-SpItem -ListUrl $weeklyAppApiBase -Token $spToken -Title "$ws|$app" -Fields @{
            WeekStart    = $ws
            AppHost      = $app
            Interactions = $appWkCounts[$app]
            Users        = $appWkUsers[$app]
        }
    }
}

# ── Mark dates as exported only after all SharePoint writes succeeded ────────
foreach ($dateStr in $datesToProcess) {
    if ($dateStr -ne $todayStr -and $dateStr -ne $yestStr) { $exportedDates[$dateStr] = $true }
}
Invoke-RestMethod -Uri $exportStateUri -Method PUT -Headers $saveHdr -Body ($exportedDates.Keys | ConvertTo-Json -Compress) | Out-Null

Write-Host "Export complete. Processed: $($datesToProcess.Count) date(s). Total in history: $($exportedDates.Count)."
