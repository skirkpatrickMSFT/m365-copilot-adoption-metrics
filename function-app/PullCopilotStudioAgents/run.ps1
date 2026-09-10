param($Timer)

# Standalone, additive: tracks Copilot Studio / M365 agent-builder agents from the
# Audit.General feed (copilotstudio/minimalBots events). Uses only ActivityFeed.Read
# on the existing managed identity — no Power Platform or elevated SharePoint access.
# Audit events carry the bot GUID (not display name); registry keys on AgentId.

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'CloudEnvironment.ps1')

$cloudEnvironment = Get-ConfiguredValue -Value $env:CLOUD_ENVIRONMENT -DefaultValue 'Commercial'
$cloud            = Get-CloudEnvironmentConfiguration -CloudEnvironment $cloudEnvironment
$tenantId         = $env:TENANT_ID
$mgmtApiBase      = Get-ConfiguredValue -Value $env:MGMT_API_BASE -DefaultValue $cloud.ManagementApi
$spSiteUrl        = $env:SHAREPOINT_SITE_URL
$agentList        = Get-ConfiguredValue -Value $env:SHAREPOINT_AGENT_STUDIO_LIST -DefaultValue 'CopilotStudioAgentRegistry'
# Dedicated window (isolated from the other functions) so it can be widened for testing/backfill.
$windowMinutes    = [int](Get-ConfiguredValue -Value $env:AGENT_STUDIO_WINDOW_MINUTES -DefaultValue '16')

if ([string]::IsNullOrWhiteSpace($spSiteUrl)) {
    Write-Warning 'SHAREPOINT_SITE_URL not configured. Skipping.'
    return
}

function Get-ManagedToken {
    param([string]$Resource)
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    (Invoke-RestMethod -Uri $tokenUri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }).access_token
}

# Reads a value from a PowerPlatform audit event's PropertyCollection by name.
function Get-EventProp {
    param($Rec, [string]$Name)
    if (-not $Rec.PropertyCollection) { return $null }
    ($Rec.PropertyCollection | Where-Object { $_.Name -eq $Name } | Select-Object -First 1).Value
}

$mgmtToken = Get-ManagedToken -Resource $mgmtApiBase
$spUri     = [System.Uri]$spSiteUrl
$spToken   = Get-ManagedToken -Resource "$($spUri.Scheme)://$($spUri.Host)"

# Ensure Audit.General subscription is active (shared with PullCopilotAudit)
$subs   = @(Invoke-RestMethod -Method GET -Uri "$mgmtApiBase/api/v1.0/$tenantId/activity/feed/subscriptions/list" -Headers @{ Authorization = "Bearer $mgmtToken" })
$genSub = $subs | Where-Object { $_.contentType -eq 'Audit.General' -and $_.status -eq 'enabled' }
if (-not $genSub) {
    Write-Host 'Starting Audit.General subscription...'
    Invoke-RestMethod -Method POST -Uri ($mgmtApiBase + "/api/v1.0/$tenantId/activity/feed/subscriptions/start?contentType=Audit.General") -Headers @{ Authorization = "Bearer $mgmtToken"; 'Content-Length' = '0' } | Out-Null
}

# Pull content blobs for the time window
$endTime   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
$startTime = (Get-Date).ToUniversalTime().AddMinutes(-$windowMinutes).ToString('yyyy-MM-ddTHH:mm:ss')
$listUri   = $mgmtApiBase + "/api/v1.0/$tenantId/activity/feed/subscriptions/content?contentType=Audit.General&startTime=$startTime&endTime=$endTime"

$mgmtHdr  = @{ Authorization = "Bearer $mgmtToken" }
$allBlobs = [System.Collections.Generic.List[object]]::new()
while ($listUri) {
    $result = Invoke-WebRequest -Uri $listUri -Headers $mgmtHdr -UseBasicParsing
    $body   = $result.Content | ConvertFrom-Json
    if ($body) { $allBlobs.AddRange(@($body)) }
    $next    = $result.Headers['NextPageUri'] | Select-Object -First 1
    $listUri = if ($next) { $next } else { $null }
}

Write-Host "Found $($allBlobs.Count) Audit.General blob(s) in window"
if ($allBlobs.Count -eq 0) { return }

# Extract Copilot Studio agent (minimalBots) create/publish events
$agentRegex = [regex]'/copilotstudio/minimalBots/api(?:/(?<botId>[0-9a-fA-F-]{36}))?(?<suffix>/[^?]*)?'
$agents = @{}   # botId -> record (prefer a Published event)
$totalHits = 0
foreach ($blob in $allBlobs) {
    try { $events = @((Invoke-RestMethod -Uri $blob.contentUri -Headers $mgmtHdr)) }
    catch { Write-Warning "Failed to fetch blob: $($_.Exception.Message)"; continue }

    foreach ($e in $events) {
        if ($e.Workload -ne 'PowerPlatform' -or $e.Operation -ne 'ApiEndpointCallEvent') { continue }
        $path = Get-EventProp -Rec $e -Name 'url.path'
        if (-not $path -or $path -notmatch '/copilotstudio/minimalBots/api') { continue }
        $totalHits++
        $m = $agentRegex.Match($path)
        $botId = $m.Groups['botId'].Value
        if (-not $botId) { continue }   # create(201) has no botId in path; captured on first publish/authoring call

        $eventType = if ($m.Groups['suffix'].Value -match 'publish') { 'Published' } else { 'Authoring' }
        $existing  = $agents[$botId]
        if (-not $existing -or ($eventType -eq 'Published' -and $existing.EventType -ne 'Published')) {
            $agents[$botId] = [pscustomobject]@{
                AgentId       = $botId
                EnvironmentId = [string]$e.EnvironmentId
                CreatedBy     = [string]$e.UserId
                EventDate     = [string]$e.CreationTime
                EventType     = $eventType
                ApiPath       = [string]$path
            }
        }
    }
}

Write-Host "minimalBots events seen: $totalHits; distinct agents with a bot id: $($agents.Count)"
if ($agents.Count -eq 0) { return }

# Write new agents to SharePoint — deduplicate by AgentId
$listApiBase = "$spSiteUrl/_api/web/lists/getbytitle('$agentList')/items"
$readHdr     = @{ 'Authorization' = "Bearer $spToken"; 'Accept' = 'application/json;odata=nometadata' }
$writeHdr    = @{ 'Authorization' = "Bearer $spToken"; 'Accept' = 'application/json;odata=nometadata'; 'Content-Type' = 'application/json;odata=nometadata' }

$existingIds = [System.Collections.Generic.HashSet[string]]::new()
$allItems = try { (Invoke-RestMethod -Uri "${listApiBase}?`$select=AgentId&`$top=5000" -Headers $readHdr).value } catch { @() }
foreach ($item in @($allItems)) { if ($item -and $item.AgentId) { $existingIds.Add($item.AgentId) | Out-Null } }

foreach ($botId in $agents.Keys) {
    if ($existingIds.Contains($botId)) { Write-Host "  Already recorded: $botId"; continue }
    $a = $agents[$botId]
    $body = @{
        Title = $a.AgentId; AgentId = $a.AgentId; EnvironmentId = $a.EnvironmentId
        EventType = $a.EventType; CreatedBy = $a.CreatedBy; EventDate = $a.EventDate; ApiPath = $a.ApiPath
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $listApiBase -Method POST -Headers $writeHdr -Body $body | Out-Null
    Write-Host "  Recorded: $botId | $($a.EventType) | $($a.CreatedBy)"
}

Write-Host 'Copilot Studio agent registry update complete.'
