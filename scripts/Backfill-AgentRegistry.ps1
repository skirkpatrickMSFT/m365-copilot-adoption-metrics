<#
.SYNOPSIS
    One-time baseline scan: inventories all existing SharePoint Copilot agent (.agent) files
    across the tenant and populates the SharePointCopilotAgentRegistry list.
.DESCRIPTION
    Run this locally (not in Cloud Shell) once, before or after deployment, to capture agents
    that were created before the audit pipeline started tracking them. Unlike the
    PullSharePointAgents function (which relies on Audit.SharePoint log retention, typically
    90-180 days), this script uses the Microsoft Search API to find every .agent file that
    currently exists in SharePoint, regardless of when it was created.

    Safe to re-run — existing entries are skipped by matching on AgentFileUrl, same
    deduplication approach used by the PullSharePointAgents function.
.PARAMETER TenantId
    Your Entra tenant ID.
.PARAMETER SharePointSiteUrl
    The SharePoint site hosting the SharePointCopilotAgentRegistry list.
.PARAMETER AgentListName
    Name of the agent registry list. Defaults to SharePointCopilotAgentRegistry.
.PARAMETER CloudEnvironment
    Target Microsoft 365 cloud environment.
.EXAMPLE
    .\Backfill-AgentRegistry.ps1 -TenantId "<your-tenant-id>" -SharePointSiteUrl "https://contoso.sharepoint.com/sites/CopilotReporting"
#>
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$SharePointSiteUrl,

    [string]$AgentListName = 'SharePointCopilotAgentRegistry',

    [ValidateSet('Commercial', 'GCC', 'GCCHigh', 'DoD')]
    [string]$CloudEnvironment = 'Commercial'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path (Join-Path $repoRoot 'function-app') 'CloudEnvironment.ps1')
$cloud = Get-CloudEnvironmentConfiguration -CloudEnvironment $CloudEnvironment

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes "Sites.Read.All", "Sites.ReadWrite.All" -TenantId $TenantId -Environment $cloud.GraphEnvironment

# Resolve the registry site and list IDs via Graph
$siteUri  = [System.Uri]$SharePointSiteUrl
$sitePath = $siteUri.AbsolutePath.TrimEnd('/')
Write-Host "Resolving SharePoint site..." -ForegroundColor Cyan
$site = Invoke-MgGraphRequest -Method GET -Uri "$($cloud.GraphBaseUri)/v1.0/sites/$($siteUri.Host):$($sitePath)"

Write-Host "Resolving list '$AgentListName'..." -ForegroundColor Cyan
$listsResult = Invoke-MgGraphRequest -Method GET -Uri "$($cloud.GraphBaseUri)/v1.0/sites/$($site.id)/lists?`$filter=displayName eq '$AgentListName'"
$agentList = $listsResult.value | Select-Object -First 1
if (-not $agentList) {
    throw "List '$AgentListName' not found at $SharePointSiteUrl. Create it first (see README) before running this script."
}

# Load existing AgentFileUrl values to avoid duplicate inserts
Write-Host "Reading existing registry entries..." -ForegroundColor Cyan
$existingUrls = [System.Collections.Generic.HashSet[string]]::new()
$itemsUri = "$($cloud.GraphBaseUri)/v1.0/sites/$($site.id)/lists/$($agentList.id)/items?expand=fields(select=AgentFileUrl)&`$top=200"
while ($itemsUri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $itemsUri
    foreach ($item in $page.value) {
        $url = $item.fields.AgentFileUrl
        if ($url) { $existingUrls.Add($url) | Out-Null }
    }
    $itemsUri = $page.'@odata.nextLink'
}
Write-Host "Found $($existingUrls.Count) existing registry entr$(if ($existingUrls.Count -eq 1) {'y'} else {'ies'})."

# Derives the SharePoint site URL (e.g. https://contoso.sharepoint.com/sites/MySite) from a file's webUrl
function Get-SiteUrlFromWebUrl {
    param([string]$WebUrl)
    if ($WebUrl -match '^(https?://[^/]+/(?:sites|teams)/[^/]+)/') { return $Matches[1] }
    if ($WebUrl -match '^(https?://[^/]+)/') { return $Matches[1] }
    return $WebUrl
}

# Search the entire tenant for .agent files via Microsoft Search API
Write-Host "Searching tenant for .agent files..." -ForegroundColor Cyan
$foundAgents = [System.Collections.Generic.List[object]]::new()
$from = 0
$pageSize = 25
do {
    $searchBody = @{
        requests = @(@{
            entityTypes = @('driveItem')
            query       = @{ queryString = 'filetype:agent' }
            from        = $from
            size        = $pageSize
        })
    } | ConvertTo-Json -Depth 6

    $searchResult = Invoke-MgGraphRequest -Method POST -Uri "$($cloud.GraphBaseUri)/v1.0/search/query" -Body $searchBody -ContentType 'application/json'
    $container = $searchResult.value[0].hitsContainers[0]
    $hits = @($container.hits)
    foreach ($hit in $hits) { $foundAgents.Add($hit.resource) }

    $from += $pageSize
    $more = [bool]$container.moreResultsAvailable
} while ($more -and $hits.Count -gt 0)

Write-Host "Found $($foundAgents.Count) .agent file(s) across the tenant."
if ($foundAgents.Count -eq 0) {
    Write-Host "Nothing to backfill." -ForegroundColor Yellow
    return
}

# Insert any agents not already present in the registry
$writeUri = "$($cloud.GraphBaseUri)/v1.0/sites/$($site.id)/lists/$($agentList.id)/items"
$added = 0
foreach ($agent in $foundAgents) {
    $webUrl = $agent.webUrl
    if (-not $webUrl -or $existingUrls.Contains($webUrl)) {
        Write-Host "  Skipping (already recorded or no URL): $($agent.name)"
        continue
    }

    $agentName = [System.IO.Path]::GetFileNameWithoutExtension($agent.name)
    $siteUrl   = Get-SiteUrlFromWebUrl -WebUrl $webUrl
    $createdBy = if ($agent.createdBy.user.userPrincipalName) { $agent.createdBy.user.userPrincipalName }
                 elseif ($agent.createdBy.user.displayName)   { $agent.createdBy.user.displayName }
                 else                                          { 'Unknown' }
    $createdDate = if ($agent.createdDateTime) { $agent.createdDateTime } else { (Get-Date).ToUniversalTime().ToString('o') }

    $body = @{
        fields = @{
            Title        = $agentName
            AgentName    = $agentName
            SiteUrl      = $siteUrl
            AgentFileUrl = $webUrl
            CreatedBy    = $createdBy
            CreatedDate  = $createdDate
        }
    } | ConvertTo-Json -Depth 4

    try {
        Invoke-MgGraphRequest -Method POST -Uri $writeUri -Body $body -ContentType 'application/json' | Out-Null
        Write-Host "  Added: $agentName | $siteUrl | $createdBy" -ForegroundColor Green
        $added++
    } catch {
        Write-Warning "  Failed to add $agentName : $($_.Exception.Message)"
    }
}

Write-Host "`nBackfill complete. Added $added new agent(s) to '$AgentListName'." -ForegroundColor Green
Write-Host "Note: PullSharePointAgents will continue to track new agent creations going forward." -ForegroundColor Yellow
