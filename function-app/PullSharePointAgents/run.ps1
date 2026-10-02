param($Timer)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'CloudEnvironment.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'SharedHelpers.ps1')

$cloudEnvironment = Get-ConfiguredValue -Value $env:CLOUD_ENVIRONMENT -DefaultValue 'Commercial'
$cloud            = Get-CloudEnvironmentConfiguration -CloudEnvironment $cloudEnvironment
$tenantId         = $env:TENANT_ID
$mgmtApiBase      = Get-ConfiguredValue -Value $env:MGMT_API_BASE     -DefaultValue $cloud.ManagementApi
$spSiteUrl        = $env:SHAREPOINT_SITE_URL
$agentList        = Get-ConfiguredValue -Value $env:SHAREPOINT_AGENT_LIST -DefaultValue 'SharePointCopilotAgentRegistry'
$windowMinutes    = [int](Get-ConfiguredValue -Value $env:TIME_WINDOW_MINUTES -DefaultValue '16')
$storageAccount   = $env:STORAGE_ACCOUNT_NAME
$container        = Get-ConfiguredValue -Value $env:STORAGE_CONTAINER_NAME -DefaultValue 'copilot-logs'
$storageSuffix    = Get-ConfiguredValue -Value $env:STORAGE_SUFFIX         -DefaultValue $cloud.StorageSuffix
$storageAudience  = Get-ConfiguredValue -Value $env:STORAGE_AUDIENCE       -DefaultValue $cloud.StorageAudience

if ([string]::IsNullOrWhiteSpace($spSiteUrl)) {
    Write-Warning 'SHAREPOINT_SITE_URL not configured. Skipping.'
    return
}

function Get-ManagedToken {
    param([string]$Resource)
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    (Invoke-HttpWithRetry -Description 'Managed identity token' -Request {
        Invoke-RestMethod -Uri $tokenUri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
    }).access_token
}

$mgmtToken = Get-ManagedToken -Resource $mgmtApiBase
$spUri     = [System.Uri]$spSiteUrl
$spToken   = Get-ManagedToken -Resource "$($spUri.Scheme)://$($spUri.Host)/"

# Window: always at least TIME_WINDOW_MINUTES, extended back to the last fully processed run so a
# failed run is retried (registry writes are de-duplicated). The Management API allows at most 24h.
$nowUtc       = (Get-Date).ToUniversalTime()
$windowStart  = $nowUtc.AddMinutes(-$windowMinutes)
$watermarkUri = $null
$storageToken = $null
if (-not [string]::IsNullOrWhiteSpace($storageAccount)) {
    $watermarkUri = "https://$storageAccount.$storageSuffix/$container/_state/lastProcessed-spagents.txt"
    $storageToken = Get-ManagedToken -Resource $storageAudience
    $mark = Get-Watermark -Uri $watermarkUri -Token $storageToken
    if ($mark -and $mark -lt $windowStart) { $windowStart = $mark }
}
$oldestAllowed = $nowUtc.AddHours(-23)
if ($windowStart -lt $oldestAllowed) {
    Write-Warning "Processing window exceeds the 24h API limit; capping to $($oldestAllowed.ToString('s'))."
    $windowStart = $oldestAllowed
}

$runFailures = 0
function Save-Progress {
    if ($watermarkUri -and $runFailures -eq 0) { Set-Watermark -Uri $watermarkUri -Token $storageToken -Value $nowUtc | Out-Null }
}

$mgmtHdr = @{ Authorization = "Bearer $mgmtToken" }

# Ensure Audit.SharePoint subscription is active
$subs  = @(Invoke-HttpWithRetry -Description 'List audit subscriptions' -Request {
    Invoke-RestMethod -Method GET -Uri "$mgmtApiBase/api/v1.0/$tenantId/activity/feed/subscriptions/list" -Headers $mgmtHdr
})
$spSub = $subs | Where-Object { $_.contentType -eq 'Audit.SharePoint' -and $_.status -eq 'enabled' }
if (-not $spSub) {
    Write-Host 'Starting Audit.SharePoint subscription...'
    Invoke-HttpWithRetry -Description 'Start Audit.SharePoint subscription' -Request {
        Invoke-RestMethod -Method POST `
            -Uri ($mgmtApiBase + "/api/v1.0/$tenantId/activity/feed/subscriptions/start?contentType=Audit.SharePoint") `
            -Headers @{ Authorization = "Bearer $mgmtToken"; "Content-Length" = "0" }
    } | Out-Null
    Write-Host 'Audit.SharePoint subscription started.'
}

# Pull content blobs for the time window
$endTime   = $nowUtc.ToString("yyyy-MM-ddTHH:mm:ss")
$startTime = $windowStart.ToString("yyyy-MM-ddTHH:mm:ss")
$listUri   = $mgmtApiBase + "/api/v1.0/$tenantId/activity/feed/subscriptions/content?contentType=Audit.SharePoint" `
           + "&startTime=$startTime&endTime=$endTime"

$allBlobs = [System.Collections.Generic.List[object]]::new()
while ($listUri) {
    $result = Invoke-HttpWithRetry -Description 'List Audit.SharePoint content' -Request {
        Invoke-WebRequest -Uri $listUri -Headers $mgmtHdr -UseBasicParsing
    }
    $body   = $result.Content | ConvertFrom-Json
    if ($body) { $allBlobs.AddRange(@($body)) }
    $next    = $result.Headers["NextPageUri"] | Select-Object -First 1
    $listUri = if ($next) { $next } else { $null }
}

Write-Host "Found $($allBlobs.Count) Audit.SharePoint blob(s) in window $startTime to $endTime"
if ($allBlobs.Count -eq 0) { Save-Progress; return }

# Extract .agent FileUploaded events
$agentEvents = [System.Collections.Generic.List[object]]::new()
foreach ($blob in $allBlobs) {
    try {
        $events = @(Invoke-HttpWithRetry -Description 'Fetch audit content blob' -Request {
            Invoke-RestMethod -Uri $blob.contentUri -Headers $mgmtHdr
        })
        $hits   = @($events | Where-Object { $_.Operation -eq 'FileUploaded' -and $_.SourceFileExtension -eq 'agent' })
        if ($hits.Count -gt 0) { $agentEvents.AddRange($hits) }
    } catch {
        $runFailures++
        Write-Warning "Failed to fetch blob: $($_.Exception.Message)"
    }
}

Write-Host "Found $($agentEvents.Count) .agent upload event(s)"
if ($agentEvents.Count -eq 0) {
    Save-Progress
    if ($runFailures -gt 0) { throw "$runFailures audit content blob(s) could not be fetched; the window will be retried on the next run." }
    return
}

# Write new agents to SharePoint — deduplicate by AgentFileUrl
$listApiBase = "$spSiteUrl/_api/web/lists/getbytitle('$agentList')/items"
$readHdr     = @{ 'Authorization' = "Bearer $spToken"; 'Accept' = 'application/json;odata=nometadata' }
$writeHdr    = @{ 'Authorization' = "Bearer $spToken"; 'Accept' = 'application/json;odata=nometadata'; 'Content-Type' = 'application/json;odata=nometadata' }

# Fetch all existing AgentFileUrls once to deduplicate in-memory (OData filter unreliable).
# A failed read must stop the run: continuing with an empty set would insert duplicates.
$existingUrls = [System.Collections.Generic.HashSet[string]]::new()
$allItems = (Invoke-HttpWithRetry -Description 'Read agent registry' -Request {
    Invoke-RestMethod -Uri "${listApiBase}?`$select=AgentFileUrl&`$top=5000" -Headers $readHdr
}).value
foreach ($item in @($allItems)) {
    if ($item -and $item.AgentFileUrl) { $existingUrls.Add($item.AgentFileUrl) | Out-Null }
}

foreach ($evt in $agentEvents) {
    $agentName = [System.IO.Path]::GetFileNameWithoutExtension($evt.SourceFileName)
    $agentUrl  = $evt.ObjectId

    if ($existingUrls.Contains($agentUrl)) {
        Write-Host "  Already recorded: $agentName"
        continue
    }

    $body = @{
        Title        = $agentName
        AgentName    = $agentName
        SiteUrl      = $evt.SiteUrl
        AgentFileUrl = $agentUrl
        CreatedBy    = $evt.UserId
        CreatedDate  = $evt.CreationTime
    } | ConvertTo-Json -Compress

    try {
        Invoke-HttpWithRetry -Description "Record agent '$agentName'" -Request {
            Invoke-RestMethod -Uri $listApiBase -Method POST -Headers $writeHdr -Body $body
        } | Out-Null
        $existingUrls.Add($agentUrl) | Out-Null
        Write-Host "  Recorded: $agentName | $($evt.SiteUrl) | $($evt.UserId)"
    } catch {
        $runFailures++
        Write-Warning "  Failed to record '$agentName': $($_.Exception.Message)"
    }
}

Save-Progress
if ($runFailures -gt 0) { throw "$runFailures operation(s) failed; the window will be retried on the next run (registry writes are de-duplicated)." }
Write-Host 'Agent registry update complete.'
