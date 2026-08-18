param($Timer)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'CloudEnvironment.ps1')

$cloudEnvironment = Get-ConfiguredValue -Value $env:CLOUD_ENVIRONMENT -DefaultValue 'Commercial'
$cloud            = Get-CloudEnvironmentConfiguration -CloudEnvironment $cloudEnvironment
$tenantId         = $env:TENANT_ID
$mgmtApiBase      = Get-ConfiguredValue -Value $env:MGMT_API_BASE     -DefaultValue $cloud.ManagementApi
$spSiteUrl        = $env:SHAREPOINT_SITE_URL
$agentList        = Get-ConfiguredValue -Value $env:SHAREPOINT_AGENT_LIST -DefaultValue 'CopilotAgentRegistry'
$windowMinutes    = [int](Get-ConfiguredValue -Value $env:TIME_WINDOW_MINUTES -DefaultValue '16')

if ([string]::IsNullOrWhiteSpace($spSiteUrl)) {
    Write-Warning 'SHAREPOINT_SITE_URL not configured. Skipping.'
    return
}

function Get-ManagedToken {
    param([string]$Resource)
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    (Invoke-RestMethod -Uri $tokenUri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }).access_token
}

$mgmtToken = Get-ManagedToken -Resource $mgmtApiBase
$spUri     = [System.Uri]$spSiteUrl
$spToken   = Get-ManagedToken -Resource "$($spUri.Scheme)://$($spUri.Host)"

# Ensure Audit.SharePoint subscription is active
$subs  = @(Invoke-RestMethod -Method GET -Uri "$mgmtApiBase/api/v1.0/$tenantId/activity/feed/subscriptions/list" -Headers @{ Authorization = "Bearer $mgmtToken" })
$spSub = $subs | Where-Object { $_.contentType -eq 'Audit.SharePoint' -and $_.status -eq 'enabled' }
if (-not $spSub) {
    Write-Host 'Starting Audit.SharePoint subscription...'
    Invoke-RestMethod -Method POST `
        -Uri ($mgmtApiBase + "/api/v1.0/$tenantId/activity/feed/subscriptions/start?contentType=Audit.SharePoint") `
        -Headers @{ Authorization = "Bearer $mgmtToken"; "Content-Length" = "0" } | Out-Null
    Write-Host 'Audit.SharePoint subscription started.'
}

# Pull content blobs for the time window
$endTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")
$startTime = (Get-Date).ToUniversalTime().AddMinutes(-$windowMinutes).ToString("yyyy-MM-ddTHH:mm:ss")
$listUri   = $mgmtApiBase + "/api/v1.0/$tenantId/activity/feed/subscriptions/content?contentType=Audit.SharePoint" `
           + "&startTime=$startTime&endTime=$endTime"

$mgmtHdr  = @{ Authorization = "Bearer $mgmtToken" }
$allBlobs = [System.Collections.Generic.List[object]]::new()
while ($listUri) {
    $result = Invoke-WebRequest -Uri $listUri -Headers $mgmtHdr -UseBasicParsing
    $body   = $result.Content | ConvertFrom-Json
    if ($body) { $allBlobs.AddRange(@($body)) }
    $next    = $result.Headers["NextPageUri"] | Select-Object -First 1
    $listUri = if ($next) { $next } else { $null }
}

Write-Host "Found $($allBlobs.Count) Audit.SharePoint blob(s) in window"
if ($allBlobs.Count -eq 0) { return }

# Extract .agent FileUploaded events
$agentEvents = [System.Collections.Generic.List[object]]::new()
foreach ($blob in $allBlobs) {
    try {
        $events = @((Invoke-RestMethod -Uri $blob.contentUri -Headers $mgmtHdr))
        $hits   = @($events | Where-Object { $_.Operation -eq 'FileUploaded' -and $_.SourceFileExtension -eq 'agent' })
        if ($hits.Count -gt 0) { $agentEvents.AddRange($hits) }
    } catch { Write-Warning "Failed to fetch blob: $($_.Exception.Message)" }
}

Write-Host "Found $($agentEvents.Count) .agent upload event(s)"
if ($agentEvents.Count -eq 0) { return }

# Write new agents to SharePoint — deduplicate by AgentFileUrl
$listApiBase = "$spSiteUrl/_api/web/lists/getbytitle('$agentList')/items"
$readHdr     = @{ 'Authorization' = "Bearer $spToken"; 'Accept' = 'application/json;odata=nometadata' }
$writeHdr    = @{ 'Authorization' = "Bearer $spToken"; 'Accept' = 'application/json;odata=nometadata'; 'Content-Type' = 'application/json;odata=nometadata' }

foreach ($evt in $agentEvents) {
    $agentName = [System.IO.Path]::GetFileNameWithoutExtension($evt.SourceFileName)
    $agentUrl  = $evt.ObjectId

    # Skip if this exact file URL is already in the list
    $escaped  = [System.Uri]::EscapeDataString(($agentUrl -replace "'", "''"))
    $existing = try { (Invoke-RestMethod -Uri "${listApiBase}?`$filter=AgentFileUrl%20eq%20'${escaped}'&`$select=Id" -Headers $readHdr).value } catch { $null }
    if ($existing -and @($existing).Count -gt 0) {
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

    Invoke-RestMethod -Uri $listApiBase -Method POST -Headers $writeHdr -Body $body | Out-Null
    Write-Host "  Recorded: $agentName | $($evt.SiteUrl) | $($evt.UserId)"
}

Write-Host 'Agent registry update complete.'
