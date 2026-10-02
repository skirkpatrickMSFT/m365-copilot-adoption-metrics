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
$spAgentList      = Get-ConfiguredValue -Value $env:SHAREPOINT_AGENT_LIST          -DefaultValue 'SharePointCopilotAgentRegistry'
$spInactiveList   = Get-ConfiguredValue -Value $env:SHAREPOINT_INACTIVE_AGENT_LIST -DefaultValue 'CopilotInactiveAgents'
$inactiveDays     = [int](Get-ConfiguredValue -Value $env:AGENT_INACTIVE_DAYS      -DefaultValue '60')
# AGENT_USAGE_REBUILD_DAYS: one-time rebuild of agent usage from the last N days of blobs (0 = off).
$usageRebuildDays = [int](Get-ConfiguredValue -Value $env:AGENT_USAGE_REBUILD_DAYS -DefaultValue '0')

if ([string]::IsNullOrWhiteSpace($spSiteUrl)) {
    Write-Warning 'SHAREPOINT_SITE_URL is not configured. Skipping export.'
    return
}

function Get-ManagedToken {
    param([string]$Resource)
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    (Invoke-RestMethod -Uri $tokenUri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }).access_token
}

# Normalizes DateTime/string values to a UTC DateTime; values without an offset are treated as UTC.
function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    return $null
}

# Records one Copilot interaction against an agent. Keyed by platform agent id when present, else by name.
function Add-AgentUsage {
    param([hashtable]$Table, $EventRecord)
    if (-not $EventRecord.AgentId -and -not $EventRecord.AgentName) { return }
    $key = if ($EventRecord.AgentId) { 'id:' + $EventRecord.AgentId.ToLowerInvariant() } else { 'name:' + $EventRecord.AgentName.Trim().ToLowerInvariant() }
    if (-not $Table.ContainsKey($key)) {
        $Table[$key] = @{ key = $key; id = [string]$EventRecord.AgentId; name = [string]$EventRecord.AgentName; siteUrl = [string]$EventRecord.AgentSiteUrl; lastUsed = $null; useCount = 0 }
    }
    $u = $Table[$key]
    $u.useCount++
    $when = ConvertTo-UtcDate $EventRecord.CreationTime
    if ($when -and (-not $u.lastUsed -or $when -gt $u.lastUsed)) { $u.lastUsed = $when }
    if (-not $u.name    -and $EventRecord.AgentName)    { $u.name    = [string]$EventRecord.AgentName }
    if (-not $u.siteUrl -and $EventRecord.AgentSiteUrl) { $u.siteUrl = [string]$EventRecord.AgentSiteUrl }
}

$storageToken = Get-ManagedToken -Resource $storageAudience
$spUri        = [System.Uri]$spSiteUrl
$spToken      = Get-ManagedToken -Resource "$($spUri.Scheme)://$($spUri.Host)/"

$baseUrl    = "https://$storageAccount.$storageSuffix/$container"
$storageHdr = @{ 'Authorization' = "Bearer $storageToken"; 'x-ms-version' = '2021-08-06' }

# ── Acquire a 60-second blob lease as a distributed lock ─────────────────────
# A second run that starts while this one is in progress will fail to acquire
# the lease and exit cleanly, preventing duplicate SharePoint writes.
$lockUri = "${baseUrl}/_state/export.lock"
try { Invoke-RestMethod -Uri $lockUri -Method PUT -Headers (@{ 'Authorization' = "Bearer $storageToken"; 'x-ms-version' = '2021-08-06'; 'x-ms-blob-type' = 'BlockBlob'; 'Content-Length' = '0' }) -Body '' | Out-Null } catch {}
$leaseId = $null
try {
    $acqHdr = @{ 'Authorization' = "Bearer $storageToken"; 'x-ms-version' = '2021-08-06'; 'x-ms-lease-action' = 'acquire'; 'x-ms-lease-duration' = '60' }
    $leaseResp = Invoke-WebRequest -Uri "${lockUri}?comp=lease" -Method PUT -Headers $acqHdr -UseBasicParsing
    $leaseId = [string]($leaseResp.Headers['x-ms-lease-id'] | Select-Object -First 1)
    Write-Host "Acquired export lock: $leaseId"
} catch {
    Write-Warning 'Another export run already holds the lock. Exiting to avoid duplicate writes.'
    return
}
try {
$today      = (Get-Date).ToUniversalTime().Date
$yesterday  = $today.AddDays(-1)
$todayStr   = $today.ToString('yyyy-MM-dd')
$yestStr    = $yesterday.ToString('yyyy-MM-dd')

# ── Load state ───────────────────────────────────────────────────────────────
# blobTracker + liveUserSets only ever hold entries for "open" dates (today,
# yesterday, or in-progress backfill). Once a date is finalized (exportedDates),
# its entries are pruned so these stay small regardless of total history.
$exportStateUri  = "${baseUrl}/_state/exportedDates.json"
$aggregatesUri   = "${baseUrl}/_state/dailyAggregates.json"
$firstSeenUri    = "${baseUrl}/_state/firstSeen.json"
$blobTrackerUri  = "${baseUrl}/_state/blobTracker.json"
$liveSetsUri     = "${baseUrl}/_state/liveUserSets.json"
$agentUsageUri   = "${baseUrl}/_state/agentUsage.json"

$agentUsage      = @{}   # key (id:<platformId> | name:<name>) -> @{ key; id; name; siteUrl; lastUsed; useCount }
$exportedDates   = @{}
$dailyAggregates = @{}
$firstSeenMap    = @{}
$blobTracker     = @{}   # date -> HashSet[string] of already-processed blob names
$liveUserSets    = @{}   # date -> @{ users = HashSet[string]; appUsers = @{ app -> HashSet[string] } }

try { $d = Invoke-RestMethod -Uri $exportStateUri -Headers $storageHdr; foreach ($item in @($d)) { $exportedDates[$item] = $true } }
catch { Write-Host 'No export state; will process all dates in lookback window.' }

try { $a = Invoke-RestMethod -Uri $aggregatesUri -Headers $storageHdr; foreach ($prop in $a.PSObject.Properties) { $dailyAggregates[$prop.Name] = $prop.Value } }
catch { Write-Host 'No daily aggregates cache.' }

try { $fs = Invoke-RestMethod -Uri $firstSeenUri -Headers $storageHdr; foreach ($prop in $fs.PSObject.Properties) { $firstSeenMap[$prop.Name] = $prop.Value } }
catch { Write-Host 'No firstSeen cache.' }

try {
    $au = Invoke-RestMethod -Uri $agentUsageUri -Headers $storageHdr
    foreach ($prop in $au.PSObject.Properties) {
        $v = $prop.Value
        $agentUsage[$prop.Name] = @{ key = $prop.Name; id = [string]$v.id; name = [string]$v.name; siteUrl = [string]$v.siteUrl; lastUsed = (ConvertTo-UtcDate $v.lastUsed); useCount = [int]$v.useCount }
    }
} catch { Write-Host 'No agent usage cache.' }

try {
    $bt = Invoke-RestMethod -Uri $blobTrackerUri -Headers $storageHdr
    foreach ($prop in $bt.PSObject.Properties) { $blobTracker[$prop.Name] = [System.Collections.Generic.HashSet[string]]::new([string[]]$prop.Value) }
} catch { Write-Host 'No blob tracker cache; will treat all blobs as new.' }

try {
    $ls = Invoke-RestMethod -Uri $liveSetsUri -Headers $storageHdr
    foreach ($prop in $ls.PSObject.Properties) {
        $entry = $prop.Value
        $appUsersDict = @{}
        if ($entry.appUsers) {
            foreach ($ap in $entry.appUsers.PSObject.Properties) { $appUsersDict[$ap.Name] = [System.Collections.Generic.HashSet[string]]::new([string[]]$ap.Value) }
        }
        $liveUserSets[$prop.Name] = @{
            users    = [System.Collections.Generic.HashSet[string]]::new([string[]]$entry.users)
            appUsers = $appUsersDict
        }
    }
} catch { Write-Host 'No live user-set cache; DAU will be rebuilt from new blobs only.' }

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

# ── Helper: parse a single event's fields (shared shape used everywhere) ─────
function ConvertTo-EventRecord {
    param($e)
    if (-not $e.UserId) { return $null }
    $agentResource = $e.CopilotEventData.AccessedResources | Where-Object { $_.Type -eq 'agent' } | Select-Object -First 1
    [pscustomobject]@{
        UserId       = [string]$e.UserId
        AppHost      = if ($e.CopilotEventData.AppHost) { [string]$e.CopilotEventData.AppHost }
                       elseif ($e.AppHost)              { [string]$e.AppHost }
                       else                              { 'Copilot Chat' }
        AgentName    = if ($e.CopilotEventData.TargetAgentName) { [string]$e.CopilotEventData.TargetAgentName }
                       elseif ($e.AgentName)                    { [string]$e.AgentName }
                       else                                      { $null }
        AgentSiteUrl = if ($agentResource) { [string]$agentResource.SiteUrl } else { $null }
        AgentId      = if ($e.CopilotEventData.TargetPlatformAgentId) { [string]$e.CopilotEventData.TargetPlatformAgentId } else { $null }
        CreationTime = $e.CreationTime
    }
}

# ── List blob names for a date (cheap — no content download) ─────────────────
function Get-DayBlobNames {
    param([string]$DateStr)
    $names    = [System.Collections.Generic.List[string]]::new()
    $enc      = [System.Uri]::EscapeDataString(([datetime]$DateStr).ToString('yyyy/MM/dd'))
    $listBase = $baseUrl + '?restype=container' + '&comp=list' + '&prefix=' + $enc + '&maxresults=1000'
    $uri      = $listBase
    while ($uri) {
        $xml   = [xml](Invoke-WebRequest -Uri $uri -Headers $storageHdr -UseBasicParsing).Content.TrimStart([char]0xFEFF)
        $nodes = $xml.EnumerationResults.Blobs.Blob
        if ($nodes) { foreach ($n in @($nodes | Where-Object { $_.Name -and $_.Name.EndsWith('.json') } | Select-Object -ExpandProperty Name)) { $names.Add($n) } }
        $marker = $xml.EnumerationResults.NextMarker
        $uri    = if ($marker) { $listBase + '&marker=' + [System.Uri]::EscapeDataString($marker) } else { $null }
    }
    return ,$names
}

function Get-WeekStart {
    param([datetime]$Date)
    $dow = [int]$Date.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
    $Date.AddDays(1 - $dow).Date
}

# ── Process each date: only download/parse blobs not already counted ─────────
foreach ($dateStr in $datesToProcess) {
    Write-Host "Processing $dateStr ..."
    $allBlobNames = Get-DayBlobNames -DateStr $dateStr
    if (-not $blobTracker.ContainsKey($dateStr)) { $blobTracker[$dateStr] = [System.Collections.Generic.HashSet[string]]::new() }
    $seenBlobs = $blobTracker[$dateStr]
    $newBlobNames = @($allBlobNames | Where-Object { -not $seenBlobs.Contains($_) })

    Write-Host "  $($allBlobNames.Count) blob(s) total, $($newBlobNames.Count) new since last run."
    if ($newBlobNames.Count -eq 0) {
        Write-Host "  Nothing new."
        continue
    }

    if (-not $liveUserSets.ContainsKey($dateStr)) {
        $liveUserSets[$dateStr] = @{ users = [System.Collections.Generic.HashSet[string]]::new(); appUsers = @{} }
    }
    $userSet    = $liveUserSets[$dateStr].users
    $appUserSets = $liveUserSets[$dateStr].appUsers

    $existingAgg   = $dailyAggregates[$dateStr]
    $interactions  = if ($existingAgg) { [int]$existingAgg.interactions } else { 0 }
    $appCounts     = @{}
    if ($existingAgg -and $existingAgg.appCounts) {
        foreach ($p in $existingAgg.appCounts.PSObject.Properties) { $appCounts[$p.Name] = [int]$p.Value }
    }

    $newEventCount = 0
    foreach ($name in $newBlobNames) {
        try {
            $raw  = Invoke-RestMethod -Uri "${baseUrl}/${name}" -Headers $storageHdr
            $evts = if ($raw -is [array]) { $raw } else { @($raw) }
            foreach ($rawEvt in $evts) {
                $e = ConvertTo-EventRecord -e $rawEvt
                if (-not $e) { continue }
                $newEventCount++
                $interactions++
                if (-not $appCounts.ContainsKey($e.AppHost)) { $appCounts[$e.AppHost] = 0 }
                $appCounts[$e.AppHost]++
                $userSet.Add($e.UserId) | Out-Null
                if (-not $appUserSets.ContainsKey($e.AppHost)) { $appUserSets[$e.AppHost] = [System.Collections.Generic.HashSet[string]]::new() }
                $appUserSets[$e.AppHost].Add($e.UserId) | Out-Null
                if (-not $firstSeenMap.ContainsKey($e.UserId)) { $firstSeenMap[$e.UserId] = $dateStr }
                Add-AgentUsage -Table $agentUsage -EventRecord $e
            }
        } catch { Write-Warning "  Skipping ${name}: $($_.Exception.Message)" }
        $seenBlobs.Add($name) | Out-Null
    }
    Write-Host "  Parsed $newEventCount new event(s)."

    $appUserCounts = @{}
    $appUserIds    = @{}
    foreach ($app in $appUserSets.Keys) {
        $appUserCounts[$app] = $appUserSets[$app].Count
        $appUserIds[$app]    = @($appUserSets[$app])
    }

    # users/appUserIds hold the distinct user IDs so the weekly rollup can union
    # them across the 7 days rather than summing daily counts (which double-counts).
    $dailyAggregates[$dateStr] = [pscustomobject]@{
        dau          = $userSet.Count
        interactions = $interactions
        newUsers     = @($firstSeenMap.GetEnumerator() | Where-Object { $_.Value -eq $dateStr }).Count
        appCounts    = [pscustomobject]$appCounts
        appUsers     = [pscustomobject]$appUserCounts
        users        = @($userSet)
        appUserIds   = [pscustomobject]$appUserIds
    }
}

# ── Optional one-time rebuild of agent usage from historical blobs ───────────
# Replaces the usage table with a fresh scan. For still-open dates only blobs already in the
# blob tracker are read, so blobs arriving later are counted exactly once by the next run.
if ($usageRebuildDays -gt 0) {
    Write-Host "Rebuilding agent usage from the last $usageRebuildDays day(s)..."
    $rebuilt = @{}
    for ($d = $today.AddDays(-$usageRebuildDays); $d -le $today; $d = $d.AddDays(1)) {
        $ds = $d.ToString('yyyy-MM-dd')
        foreach ($name in (Get-DayBlobNames -DateStr $ds)) {
            if ($blobTracker.ContainsKey($ds) -and -not $blobTracker[$ds].Contains($name)) { continue }
            try {
                $raw = Invoke-RestMethod -Uri "${baseUrl}/${name}" -Headers $storageHdr
                foreach ($rawEvt in @($raw)) {
                    $e = ConvertTo-EventRecord -e $rawEvt
                    if ($e) { Add-AgentUsage -Table $rebuilt -EventRecord $e }
                }
            } catch { Write-Warning "  Rebuild skipped ${name}: $($_.Exception.Message)" }
        }
    }
    $agentUsage = $rebuilt
    Write-Host "Rebuilt usage for $($agentUsage.Count) agent key(s). Reset AGENT_USAGE_REBUILD_DAYS to 0."
}

# ── Persist computed data (not yet marking dates as done) ────────────────────
$saveHdr = @{ 'Authorization' = "Bearer $storageToken"; 'x-ms-version' = '2021-08-06'; 'x-ms-blob-type' = 'BlockBlob'; 'Content-Type' = 'application/json' }
$agentUsageOut = [ordered]@{}
foreach ($k in $agentUsage.Keys) {
    $u = $agentUsage[$k]
    $agentUsageOut[$k] = [pscustomobject]@{
        id = $u.id; name = $u.name; siteUrl = $u.siteUrl; useCount = $u.useCount
        lastUsed = if ($u.lastUsed) { $u.lastUsed.ToString('o') } else { $null }
    }
}
Invoke-RestMethod -Uri $agentUsageUri -Method PUT -Headers $saveHdr -Body ($agentUsageOut | ConvertTo-Json -Compress -Depth 3) | Out-Null
Invoke-RestMethod -Uri $firstSeenUri -Method PUT -Headers $saveHdr -Body ($firstSeenMap   | ConvertTo-Json -Compress -Depth 2) | Out-Null
Invoke-RestMethod -Uri $aggregatesUri -Method PUT -Headers $saveHdr -Body ($dailyAggregates | ConvertTo-Json -Compress -Depth 5) | Out-Null

# Serialize blobTracker (HashSet -> array) — only open dates are ever present here
$blobTrackerOut = @{}
foreach ($k in $blobTracker.Keys) { $blobTrackerOut[$k] = @($blobTracker[$k]) }
Invoke-RestMethod -Uri $blobTrackerUri -Method PUT -Headers $saveHdr -Body ($blobTrackerOut | ConvertTo-Json -Compress -Depth 3) | Out-Null

# Serialize liveUserSets (HashSet -> array), same open-dates-only scope
$liveSetsOut = @{}
foreach ($k in $liveUserSets.Keys) {
    $appUsersOut = @{}
    foreach ($ap in $liveUserSets[$k].appUsers.Keys) { $appUsersOut[$ap] = @($liveUserSets[$k].appUsers[$ap]) }
    $liveSetsOut[$k] = @{ users = @($liveUserSets[$k].users); appUsers = $appUsersOut }
}
Invoke-RestMethod -Uri $liveSetsUri -Method PUT -Headers $saveHdr -Body ($liveSetsOut | ConvertTo-Json -Compress -Depth 4) | Out-Null

# ── Write to SharePoint ───────────────────────────────────────────────────────
# Delete items from a list whose Title exactly matches any value in the provided set.
# Uses Invoke-WebRequest + ConvertFrom-Json -AsHashtable because SharePoint's response
# includes both "Id" and "ID" keys, which breaks Invoke-RestMethod auto-deserialization.
function Remove-SpItemsByTitles {
    param([string]$ListUrl, [string]$Token, [string[]]$Titles)
    if (-not $Titles -or $Titles.Count -eq 0) { return }
    $readHdr  = @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/json;odata=nometadata' }
    $writeHdr = @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/json;odata=nometadata'; 'Content-Type' = 'application/json;odata=nometadata' }
    $titleSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Titles)
    $deleted  = 0

    $rawResp = try { Invoke-WebRequest -Uri "${ListUrl}?`$select=Id,Title&`$top=5000" -Headers $readHdr -UseBasicParsing } catch { $null }
    $parsed  = if ($rawResp) { try { $rawResp.Content | ConvertFrom-Json -AsHashtable } catch { $null } } else { $null }
    $all     = if ($parsed -and $parsed.ContainsKey('value')) { @($parsed['value']) } else { @() }

    foreach ($item in $all) {
        $id    = if ($item -is [hashtable]) { $item['Id'] } else { $item.Id }
        $title = if ($item -is [hashtable]) { $item['Title'] } else { $item.Title }
        if (-not $id -or -not $titleSet.Contains($title)) { continue }
        $delHdr = $writeHdr.Clone(); $delHdr['IF-MATCH'] = '*'; $delHdr['X-HTTP-Method'] = 'DELETE'
        try {
            Invoke-WebRequest -Uri "${ListUrl}($id)" -Method POST -Headers $delHdr -UseBasicParsing | Out-Null
            $deleted++
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 429 -or $code -eq 503) { Start-Sleep -Seconds 10 }
            else { Write-Warning "  Delete failed ($code) for $id" }
        }
    }
    Write-Host "  Deleted $deleted item(s) matching $($Titles.Count) title(s)."
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

$affectedWeeks = $datesToProcess | ForEach-Object { (Get-WeekStart ([datetime]$_)).ToString('yyyy-MM-dd') } | Select-Object -Unique

# Only touch the specific dates/weeks affected by this run — scales to years of history
$dailyTitles = [string[]]@($datesToProcess | Where-Object { $dailyAggregates[$_] })
$appTitles   = [string[]]@(
    foreach ($d in $datesToProcess) {
        $agg = $dailyAggregates[$d]; if (-not $agg) { continue }
        foreach ($app in $agg.appCounts.PSObject.Properties) { "$d|$($app.Name)" }
    }
)
$weeklyTitles = [string[]]@($affectedWeeks)
$weeklyAppTitles = [string[]]@(
    foreach ($ws in $affectedWeeks) {
        foreach ($offset in 0..6) {
            $wd  = ([datetime]$ws).AddDays($offset).ToString('yyyy-MM-dd')
            $agg = $dailyAggregates[$wd]; if (-not $agg) { continue }
            foreach ($app in $agg.appCounts.PSObject.Properties) { "$ws|$($app.Name)" }
        }
    }
)

Write-Host "Clearing $($dailyTitles.Count) daily, $($appTitles.Count) app, $($weeklyTitles.Count) weekly, $($weeklyAppTitles.Count) weeklyApp row(s) to be rewritten..."
Remove-SpItemsByTitles -ListUrl $dailyApiBase     -Token $spToken -Titles $dailyTitles
Remove-SpItemsByTitles -ListUrl $appApiBase       -Token $spToken -Titles $appTitles
Remove-SpItemsByTitles -ListUrl $weeklyApiBase    -Token $spToken -Titles $weeklyTitles
Remove-SpItemsByTitles -ListUrl $weeklyAppApiBase -Token $spToken -Titles $weeklyAppTitles

Write-Host "Writing daily and app rows..."
foreach ($dateStr in $datesToProcess) {
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
Write-Host "Writing $($affectedWeeks.Count) week(s)..."
foreach ($ws in $affectedWeeks) {
    $we       = ([datetime]$ws).AddDays(6).ToString('yyyy-MM-dd')
    $weekDays = 0..6 | ForEach-Object { ([datetime]$ws).AddDays($_).ToString('yyyy-MM-dd') }
    $totalInter = 0; $totalNew = 0; $legacyDAU = 0
    $weekUsers  = [System.Collections.Generic.HashSet[string]]::new()
    $appWkCounts = @{}; $appWkUserSets = @{}; $appWkUsersLegacy = @{}; $allApps = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($wd in $weekDays) {
        $agg = $dailyAggregates[$wd]; if (-not $agg) { continue }
        $totalInter += $agg.interactions
        $totalNew   += $agg.newUsers
        # Union distinct user IDs across the week. Aggregates written before this
        # fix only stored a daily count, so fall back to summing DAU for those.
        if ($agg.users) { foreach ($u in @($agg.users)) { if ($u) { $weekUsers.Add([string]$u) | Out-Null } } }
        else            { $legacyDAU += [int]$agg.dau }
        foreach ($app in $agg.appCounts.PSObject.Properties) {
            $allApps.Add($app.Name) | Out-Null
            if (-not $appWkCounts.ContainsKey($app.Name)) {
                $appWkCounts[$app.Name] = 0
                $appWkUserSets[$app.Name] = [System.Collections.Generic.HashSet[string]]::new()
                $appWkUsersLegacy[$app.Name] = 0
            }
            $appWkCounts[$app.Name] += $app.Value
            $ids = if ($agg.appUserIds) { $agg.appUserIds.PSObject.Properties | Where-Object { $_.Name -eq $app.Name } | Select-Object -ExpandProperty Value } else { $null }
            if ($null -ne $ids) { foreach ($id in @($ids)) { if ($id) { $appWkUserSets[$app.Name].Add([string]$id) | Out-Null } } }
            else {
                $u = ($agg.appUsers.PSObject.Properties | Where-Object { $_.Name -eq $app.Name } | Select-Object -ExpandProperty Value)
                $appWkUsersLegacy[$app.Name] += [int]$u
            }
        }
    }

    Write-SpItem -ListUrl $weeklyApiBase -Token $spToken -Title $ws -Fields @{
        WeekStart         = $ws
        WeekEnd           = $we
        TotalInteractions = $totalInter
        UniqueUsers       = ($weekUsers.Count + $legacyDAU)
        NewUsers          = $totalNew
        AppsUsed          = ($allApps | Sort-Object) -join ', '
    }

    foreach ($app in $appWkCounts.Keys) {
        Write-SpItem -ListUrl $weeklyAppApiBase -Token $spToken -Title "$ws|$app" -Fields @{
            WeekStart    = $ws
            AppHost      = $app
            Interactions = $appWkCounts[$app]
            Users        = ($appWkUserSets[$app].Count + $appWkUsersLegacy[$app])
        }
    }
}

# ── Mark dates as exported only after all SharePoint writes succeeded ────────
foreach ($dateStr in $datesToProcess) {
    if ($dateStr -ne $todayStr -and $dateStr -ne $yestStr) { $exportedDates[$dateStr] = $true }
}
Invoke-RestMethod -Uri $exportStateUri -Method PUT -Headers $saveHdr -Body ($exportedDates.Keys | ConvertTo-Json -Compress) | Out-Null

# Prune blobTracker/liveUserSets for dates that are now finalized — their final
# counts are permanently kept in dailyAggregates, so the per-blob/per-user
# tracking is no longer needed and would otherwise grow with total history.
$closedDates = @($blobTracker.Keys) | Where-Object { $exportedDates.ContainsKey($_) }
foreach ($cd in $closedDates) { $blobTracker.Remove($cd); $liveUserSets.Remove($cd) }
if ($closedDates.Count -gt 0) {
    $blobTrackerOut2 = @{}
    foreach ($k in $blobTracker.Keys) { $blobTrackerOut2[$k] = @($blobTracker[$k]) }
    Invoke-RestMethod -Uri $blobTrackerUri -Method PUT -Headers $saveHdr -Body ($blobTrackerOut2 | ConvertTo-Json -Compress -Depth 3) | Out-Null

    $liveSetsOut2 = @{}
    foreach ($k in $liveUserSets.Keys) {
        $appUsersOut2 = @{}
        foreach ($ap in $liveUserSets[$k].appUsers.Keys) { $appUsersOut2[$ap] = @($liveUserSets[$k].appUsers[$ap]) }
        $liveSetsOut2[$k] = @{ users = @($liveUserSets[$k].users); appUsers = $appUsersOut2 }
    }
    Invoke-RestMethod -Uri $liveSetsUri -Method PUT -Headers $saveHdr -Body ($liveSetsOut2 | ConvertTo-Json -Compress -Depth 4) | Out-Null
    Write-Host "Pruned tracking state for $($closedDates.Count) finalized date(s): $($closedDates -join ', ')"
}

# ── Agent usage → registry columns + inactive-agent list ─────────────────────
# Runs every export (even with no new blobs) so agents age into the inactive list on day N.
# Failures here are logged and never fail the metrics export.
function Get-SpListItems {
    param([string]$ListUrl, [string]$Fields, [hashtable]$Headers)
    $items = [System.Collections.Generic.List[object]]::new()
    $uri   = "${ListUrl}?`$select=${Fields}&`$top=5000"
    while ($uri) {
        $parsed = (Invoke-WebRequest -Uri $uri -Headers $Headers -UseBasicParsing).Content | ConvertFrom-Json -AsHashtable
        if ($parsed.ContainsKey('value')) { foreach ($i in @($parsed['value'])) { $items.Add($i) } }
        $uri = if ($parsed.ContainsKey('odata.nextLink')) { [string]$parsed['odata.nextLink'] } else { $null }
    }
    return ,$items
}

function Get-NormName { param($s) if ($s) { ([string]$s).Trim().ToLowerInvariant() } else { '' } }

# SharePoint puts the useful reason (e.g. a missing column) in the response body, not the exception message.
function Get-SpErrorText {
    param($ErrorRecord)
    $detail = $ErrorRecord.ErrorDetails.Message
    if ($detail) { return "$($ErrorRecord.Exception.Message) | $($detail.Substring(0, [Math]::Min(300, $detail.Length)))" }
    return $ErrorRecord.Exception.Message
}
function Get-NormSite { param($s) if ($s) { ([string]$s).Trim().TrimEnd('/').ToLowerInvariant() } else { '' } }

try {
    $spReadHdr  = @{ 'Authorization' = "Bearer $spToken"; 'Accept' = 'application/json;odata=nometadata' }
    $spWriteHdr = @{ 'Authorization' = "Bearer $spToken"; 'Accept' = 'application/json;odata=nometadata'; 'Content-Type' = 'application/json;odata=nometadata' }
    $agentApiBase    = "$spSiteUrl/_api/web/lists/getbytitle('$spAgentList')/items"
    $inactiveApiBase = "$spSiteUrl/_api/web/lists/getbytitle('$spInactiveList')/items"

    $baseFields   = 'Id,Title,AgentName,SiteUrl,CreatedDate'
    $usageColumns = $true
    $registry     = $null
    try { $registry = Get-SpListItems -ListUrl $agentApiBase -Fields "$baseFields,LastUsedDate,UseCount,AgentPlatformID" -Headers $spReadHdr }
    catch {
        $usageColumns = $false
        Write-Warning "Registry read with usage columns failed ($(Get-SpErrorText $_)). Create LastUsedDate, UseCount and AgentPlatformID on '$spAgentList'. Continuing without registry updates."
        try { $registry = Get-SpListItems -ListUrl $agentApiBase -Fields $baseFields -Headers $spReadHdr }
        catch { Write-Warning "Registry read failed: $(Get-SpErrorText $_). Skipping agent usage sync." }
    }

    if ($null -ne $registry) {
        $rows = foreach ($item in $registry) {
            $nm = if ($item['AgentName']) { [string]$item['AgentName'] } else { [string]$item['Title'] }
            if (-not $nm) { continue }
            [pscustomobject]@{
                Id       = $item['Id']
                Name     = $nm
                SiteUrl  = [string]$item['SiteUrl']
                Created  = ConvertTo-UtcDate $item['CreatedDate']
                CurLast  = ConvertTo-UtcDate $item['LastUsedDate']
                CurCount = [int]$item['UseCount']
                CurPid   = [string]$item['AgentPlatformID']
            }
        }
        $rows = @($rows)

        $entries    = @($agentUsage.Values)
        $claimedIds = [System.Collections.Generic.HashSet[string]]::new()
        $nameCounts = @{}
        foreach ($r in $rows) {
            if ($r.CurPid) { $claimedIds.Add($r.CurPid.ToLowerInvariant()) | Out-Null }
            $nk = Get-NormName $r.Name
            $nameCounts[$nk] = 1 + [int]$nameCounts[$nk]
        }

        $matchedKeys = [System.Collections.Generic.HashSet[string]]::new()
        $now         = (Get-Date).ToUniversalTime()
        $inactive    = [System.Collections.Generic.List[object]]::new()
        $updated     = 0

        foreach ($r in $rows) {
            # Match order: stored AgentPlatformID, then agent name (site-qualified when names repeat)
            if ($r.CurPid) {
                $hits = @($entries | Where-Object { $_.id -and $_.id.ToLowerInvariant() -eq $r.CurPid.ToLowerInvariant() })
            } else {
                $nk   = Get-NormName $r.Name
                $hits = @($entries | Where-Object { (Get-NormName $_.name) -eq $nk -and (-not $_.id -or -not $claimedIds.Contains($_.id.ToLowerInvariant())) })
                if ($nameCounts[$nk] -gt 1) {
                    $rowSite = Get-NormSite $r.SiteUrl
                    $hits    = @($hits | Where-Object { -not $_.siteUrl -or (Get-NormSite $_.siteUrl) -eq $rowSite })
                    if ($hits.Count -gt 0) { Write-Warning "Agent name '$($r.Name)' is used by $($nameCounts[$nk]) registry rows; usage matched by site where possible." }
                }
            }

            $useCount = 0; $lastUsed = $null
            foreach ($h in $hits) {
                $matchedKeys.Add($h.key) | Out-Null
                $useCount += [int]$h.useCount
                if ($h.lastUsed -and (-not $lastUsed -or $h.lastUsed -gt $lastUsed)) { $lastUsed = $h.lastUsed }
            }
            # Never regress values already stored on the row (e.g. after a partial rebuild)
            if ($r.CurCount -gt $useCount) { $useCount = $r.CurCount }
            if ($r.CurLast -and (-not $lastUsed -or $r.CurLast -gt $lastUsed)) { $lastUsed = $r.CurLast }

            $newPid = $null
            $hitIds = @($hits | Where-Object { $_.id } | ForEach-Object { $_.id } | Select-Object -Unique)
            if (-not $r.CurPid -and $hitIds.Count -eq 1) { $newPid = $hitIds[0] }

            if ($usageColumns) {
                $patch = @{}
                if ($useCount -ne $r.CurCount) { $patch['UseCount'] = $useCount }
                if ($lastUsed -and (-not $r.CurLast -or [Math]::Abs(($r.CurLast - $lastUsed).TotalSeconds) -ge 1)) { $patch['LastUsedDate'] = $lastUsed.ToString('yyyy-MM-ddTHH:mm:ssZ') }
                if ($newPid) { $patch['AgentPlatformID'] = $newPid }
                if ($patch.Count -gt 0) {
                    $mergeHdr = $spWriteHdr.Clone(); $mergeHdr['IF-MATCH'] = '*'; $mergeHdr['X-HTTP-Method'] = 'MERGE'
                    try {
                        Invoke-RestMethod -Uri "${agentApiBase}($($r.Id))" -Method POST -Headers $mergeHdr -Body ($patch | ConvertTo-Json -Compress) | Out-Null
                        $updated++
                    } catch { Write-Warning "  Registry update failed for '$($r.Name)': $(Get-SpErrorText $_)" }
                }
            }

            # Never-used agents are measured from their creation date
            $ref = if ($lastUsed) { $lastUsed } elseif ($r.Created) { $r.Created } else { $null }
            if ($ref) {
                $daysInactive = [int][Math]::Floor(($now - $ref).TotalDays)
                if ($daysInactive -ge $inactiveDays) {
                    $inactive.Add([pscustomobject]@{ Row = $r; LastUsed = $lastUsed; UseCount = $useCount; DaysInactive = $daysInactive })
                }
            }
        }
        Write-Host "Agent registry: $($rows.Count) agent(s), $updated row(s) updated, $($inactive.Count) inactive >= $inactiveDays day(s)."

        $unmatched = @($entries | Where-Object { -not $matchedKeys.Contains($_.key) })
        if ($unmatched.Count -gt 0) {
            Write-Host "Usage not matched to a registry row ($($unmatched.Count)); showing up to 20:"
            foreach ($u in ($unmatched | Sort-Object { $_.useCount } -Descending | Select-Object -First 20)) {
                Write-Host "  '$($u.name)' | id=$($u.id) | site=$($u.siteUrl) | uses=$($u.useCount) | last=$($u.lastUsed)"
            }
        }

        # Rewrite the inactive list: clear, then Summary row + one row per inactive agent
        try {
            $existing = Get-SpListItems -ListUrl $inactiveApiBase -Fields 'Id' -Headers $spReadHdr
            foreach ($item in $existing) {
                $delHdr = $spWriteHdr.Clone(); $delHdr['IF-MATCH'] = '*'; $delHdr['X-HTTP-Method'] = 'DELETE'
                try { Invoke-WebRequest -Uri "${inactiveApiBase}($($item['Id']))" -Method POST -Headers $delHdr -UseBasicParsing | Out-Null }
                catch {
                    $code = $_.Exception.Response.StatusCode.value__
                    if ($code -eq 429 -or $code -eq 503) {
                        Start-Sleep -Seconds 10
                        try { Invoke-WebRequest -Uri "${inactiveApiBase}($($item['Id']))" -Method POST -Headers $delHdr -UseBasicParsing | Out-Null } catch { Write-Warning "  Delete failed for $($item['Id'])" }
                    } else { Write-Warning "  Delete failed ($code) for $($item['Id'])" }
                }
            }

            Write-SpItem -ListUrl $inactiveApiBase -Token $spToken -Title 'Summary' -Fields @{
                RowType       = 'Summary'
                TotalAgents   = $rows.Count
                InactiveCount = $inactive.Count
                ThresholdDays = $inactiveDays
                RunDate       = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            foreach ($i in ($inactive | Sort-Object DaysInactive -Descending)) {
                $f = @{
                    RowType      = 'InactiveAgent'
                    AgentName    = $i.Row.Name
                    SiteUrl      = $i.Row.SiteUrl
                    UseCount     = $i.UseCount
                    DaysInactive = $i.DaysInactive
                }
                if ($i.Row.Created) { $f['CreatedDate']  = $i.Row.Created.ToString('yyyy-MM-ddTHH:mm:ssZ') }
                if ($i.LastUsed)    { $f['LastUsedDate'] = $i.LastUsed.ToString('yyyy-MM-ddTHH:mm:ssZ') }
                Write-SpItem -ListUrl $inactiveApiBase -Token $spToken -Title $i.Row.Name -Fields $f
            }
        } catch { Write-Warning "Inactive agent list update failed: $(Get-SpErrorText $_)" }
    }
} catch { Write-Warning "Agent usage sync failed: $($_.Exception.Message)" }

Write-Host "Export complete. Processed: $($datesToProcess.Count) date(s). Total in history: $($exportedDates.Count)."

} finally {
    if ($leaseId) {
        try {
            $relHdr = @{ 'Authorization' = "Bearer $storageToken"; 'x-ms-version' = '2021-08-06'; 'x-ms-lease-action' = 'release'; 'x-ms-lease-id' = $leaseId }
            Invoke-WebRequest -Uri "${lockUri}?comp=lease" -Method PUT -Headers $relHdr -UseBasicParsing | Out-Null
            Write-Host "Released export lock."
        } catch { Write-Warning "Failed to release lock: $($_.Exception.Message)" }
    }
}
