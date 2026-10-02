param($Timer)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'CloudEnvironment.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'SharedHelpers.ps1')

# --- Configuration ---
$cloudEnvironment = Get-ConfiguredValue -Value $env:CLOUD_ENVIRONMENT -DefaultValue 'Commercial'
$cloud = Get-CloudEnvironmentConfiguration -CloudEnvironment $cloudEnvironment
$tenantId       = $env:TENANT_ID
$dceUri         = $env:DCE_INGESTION_URI
$dcrId          = $env:DCR_IMMUTABLE_ID
$streamName     = $env:STREAM_NAME
$storageAccount = $env:STORAGE_ACCOUNT_NAME
$container      = Get-ConfiguredValue -Value $env:STORAGE_CONTAINER_NAME -DefaultValue 'copilot-logs'
$windowMinutes  = [int](Get-ConfiguredValue -Value $env:TIME_WINDOW_MINUTES -DefaultValue '16')
$maxChunkSize   = 500
$mgmtApiBase    = Get-ConfiguredValue -Value $env:MGMT_API_BASE -DefaultValue $cloud.ManagementApi
$monitorAudience = Get-ConfiguredValue -Value $env:MONITOR_AUDIENCE -DefaultValue $cloud.MonitorAudience
$storageAudience = Get-ConfiguredValue -Value $env:STORAGE_AUDIENCE -DefaultValue $cloud.StorageAudience
$storageSuffix  = Get-ConfiguredValue -Value $env:STORAGE_SUFFIX -DefaultValue $cloud.StorageSuffix

$startTime = (Get-Date).ToUniversalTime().AddMinutes(-$windowMinutes).ToString("yyyy-MM-ddTHH:mm:ss")
$endTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")

# --- Load last-processed timestamp from state blob ---
$stateBlob = "https://$storageAccount.$storageSuffix/$container/_state/lastProcessed.txt"
$stateToken = $null
try {
    $stateTokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$storageAudience&api-version=2019-08-01"
    $stateToken = (Invoke-RestMethod -Uri $stateTokenUri -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token
    $lastProcessed = Invoke-RestMethod -Uri $stateBlob -Headers @{ "Authorization" = "Bearer $stateToken"; "x-ms-version" = "2021-08-06" }
    if ($lastProcessed -and $lastProcessed.Trim().Length -gt 0) {
        $startTime = $lastProcessed.Trim()
        # Office 365 Management API rejects windows older than 24 hours
        $maxStart = (Get-Date).ToUniversalTime().AddHours(-23).ToString("yyyy-MM-ddTHH:mm:ss")
        if ([datetime]$startTime -lt [datetime]$maxStart) {
            Write-Warning "Last processed timestamp exceeds 24h limit. Capping to $maxStart"
            $startTime = $maxStart
        }
        Write-Host "Resuming from last processed: $startTime"
    }
} catch {
    Write-Host "No previous state found. Using default window."
}

Write-Host "Processing window: $startTime to $endTime"

function Get-ManagedToken {
    param([string]$Resource)
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    $response = Invoke-HttpWithRetry -Description 'Managed identity token' -Request {
        Invoke-RestMethod -Uri $tokenUri -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER } -Method GET
    }
    return $response.access_token
}

function Invoke-WithRetry {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Token,
        [object]$Body,
        [int]$MaxRetries = 5
    )
    $headers = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }
    $response = Invoke-HttpWithRetry -Description "$Method $(($Uri -split '\?')[0])" -MaxAttempts $MaxRetries -Request {
        $params = @{ Uri = $Uri; Method = $Method; Headers = $headers }
        if ($Body) { $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress } }
        Invoke-WebRequest @params -UseBasicParsing
    }
    return @{ Body = $response.Content | ConvertFrom-Json; Headers = $response.Headers; Status = $response.StatusCode }
}

$mgmtToken    = Get-ManagedToken -Resource $mgmtApiBase
$monitorToken = Get-ManagedToken -Resource $monitorAudience
$storageToken = Get-ManagedToken -Resource $storageAudience

$listUri = "$mgmtApiBase/api/v1.0/$tenantId/activity/feed/subscriptions/content?contentType=Audit.General&startTime=$startTime&endTime=$endTime"
$allContentBlobs = [System.Collections.Generic.List[object]]::new()

Write-Host "Listing content blobs..."
while ($listUri) {
    $result = Invoke-WithRetry -Uri $listUri -Token $mgmtToken
    if ($result.Body) { $allContentBlobs.AddRange(@($result.Body)) }
    $listUri = $result.Headers["NextPageUri"] | Select-Object -First 1
    if (-not $listUri) { $listUri = $null }
}
Write-Host "Found $($allContentBlobs.Count) content blob(s)"

if ($allContentBlobs.Count -eq 0) {
    Write-Host "No content blobs in this window. Done."
    return
}

$totalCopilotEvents = 0
$deliveryFailed = $false   # set when a storage/ingestion write fails in a way worth retrying next run

foreach ($blob in $allContentBlobs) {
    Write-Host "Fetching blob: $($blob.contentId)"
    $fetchResult = Invoke-WithRetry -Uri $blob.contentUri -Token $mgmtToken
    $events = @($fetchResult.Body)
    if ($events.Count -eq 0) { continue }

    $copilotEvents = @($events | Where-Object { $_.Workload -eq "Copilot" })
    if ($copilotEvents.Count -eq 0) {
        Write-Host "  No Copilot events in this blob. Skipping."
        continue
    }

    Write-Host "  Found $($copilotEvents.Count) Copilot event(s)"
    $totalCopilotEvents += $copilotEvents.Count

    # Deterministic name (hash of the content id) so re-reading a window after a failure overwrites
    # nothing and creates no duplicate blobs. If-None-Match makes an existing blob a no-op.
    $dateFolder = (Get-Date).ToUniversalTime().ToString("yyyy/MM/dd")
    $blobName = "$dateFolder/$(Get-StableId -Value $(if ($blob.contentId) { $blob.contentId } else { $blob.contentUri })).json"
    $blobUri = "https://$storageAccount.$storageSuffix/$container/$blobName"
    $storageHeaders = @{
        "Authorization"  = "Bearer $storageToken"
        "x-ms-blob-type" = "BlockBlob"
        "Content-Type"   = "application/json"
        "x-ms-version"   = "2021-08-06"
    }
    $storageHeaders["If-None-Match"] = "*"
    $blobBody = $copilotEvents | ConvertTo-Json -Depth 20
    if ($copilotEvents.Count -eq 1) { $blobBody = "[$blobBody]" }

    try {
        Invoke-HttpWithRetry -Description "Write blob $blobName" -Request {
            Invoke-RestMethod -Uri $blobUri -Method PUT -Headers $storageHeaders -Body $blobBody | Out-Null
        }
        Write-Host "  Written to storage: $blobName"
    }
    catch {
        $stCode = Get-HttpErrorStatus $_
        if ($stCode -eq 409 -or $stCode -eq 412) {
            Write-Host "  Already in storage (window re-read): $blobName"
        } else {
            Write-Warning "  Failed to write to storage: $($_.Exception.Message)"
            if ($stCode -notin 400, 413) { $deliveryFailed = $true }
        }
    }

    $ingestUri = "$dceUri/dataCollectionRules/$dcrId/streams/${streamName}?api-version=2023-01-01"
    if ([string]::IsNullOrWhiteSpace($dceUri) -or [string]::IsNullOrWhiteSpace($dcrId)) {
        Write-Host "  Log Analytics not configured - skipping ingestion (storage-only mode)."
    } else {
    for ($i = 0; $i -lt $copilotEvents.Count; $i += $maxChunkSize) {
        $chunk = @($copilotEvents[$i..([Math]::Min($i + $maxChunkSize - 1, $copilotEvents.Count - 1))])
        $chunkJson = $chunk | ConvertTo-Json -Depth 20 -Compress
        if ($chunk.Count -eq 1) { $chunkJson = "[$chunkJson]" }
        try {
            Invoke-WithRetry -Uri $ingestUri -Method "POST" -Token $monitorToken -Body $chunkJson
            Write-Host "  Sent chunk of $($chunk.Count) events to Log Analytics"
        }
        catch {
            Write-Warning "  Failed to send to Log Analytics: $($_.Exception.Message)"
            if ((Get-HttpErrorStatus $_) -notin 400, 413) { $deliveryFailed = $true }
        }
    }
    }
}

Write-Host "Complete. Total Copilot events processed: $totalCopilotEvents"

# Do not advance the processed-up-to timestamp after a failed delivery: the next run re-reads this window
# (storage writes are idempotent). Failing the run also surfaces it to the failed-run alert.
if ($deliveryFailed) {
    throw 'One or more storage/Log Analytics writes failed; processed-up-to timestamp not advanced. The window will be retried on the next run.'
}

try {
    Invoke-RestMethod -Uri $stateBlob -Method PUT -Headers @{
        "Authorization"  = "Bearer $storageToken"
        "x-ms-blob-type" = "BlockBlob"
        "Content-Type"   = "text/plain"
        "x-ms-version"   = "2021-08-06"
    } -Body $endTime
    Write-Host "State saved: $endTime"
} catch { Write-Warning "Failed to save state: $($_.Exception.Message)" }
