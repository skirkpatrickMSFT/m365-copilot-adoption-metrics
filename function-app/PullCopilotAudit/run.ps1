param($Timer)

$ErrorActionPreference = 'Stop'

# --- Configuration ---
$tenantId       = $env:TENANT_ID
$dceUri         = $env:DCE_INGESTION_URI
$dcrId          = $env:DCR_IMMUTABLE_ID
$streamName     = $env:STREAM_NAME
$storageAccount = $env:STORAGE_ACCOUNT_NAME
$container      = $env:STORAGE_CONTAINER_NAME ?? "copilot-logs"
$windowMinutes  = [int]($env:TIME_WINDOW_MINUTES ?? "16")
$maxChunkSize   = 500
$mgmtApiBase    = $env:MGMT_API_BASE ?? "https://manage.office.com"
$monitorAudience = $env:MONITOR_AUDIENCE ?? "https://monitor.azure.com"
$storageAudience = $env:STORAGE_AUDIENCE ?? "https://storage.azure.com"
$storageSuffix  = $env:STORAGE_SUFFIX ?? "blob.core.windows.net"

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
        Write-Host "Resuming from last processed: $startTime"
    }
} catch {
    Write-Host "No previous state found. Using default window."
}

Write-Host "Processing window: $startTime to $endTime"

function Get-ManagedToken {
    param([string]$Resource)
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
    $response = Invoke-RestMethod -Uri $tokenUri -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER } -Method GET
    return $response.access_token
}

function Invoke-WithRetry {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Token,
        [object]$Body,
        [int]$MaxRetries = 3
    )
    $headers = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $params = @{ Uri = $Uri; Method = $Method; Headers = $headers }
            if ($Body) { $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress } }
            $response = Invoke-WebRequest @params -UseBasicParsing
            return @{ Body = $response.Content | ConvertFrom-Json; Headers = $response.Headers; Status = $response.StatusCode }
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 429 -and $attempt -lt $MaxRetries) {
                $retryAfter = 30
                if ($_.Exception.Response.Headers["Retry-After"]) { $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"] }
                Write-Warning "Throttled (429). Waiting $retryAfter seconds (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds $retryAfter
            }
            else { throw }
        }
    }
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

    $dateFolder = (Get-Date).ToUniversalTime().ToString("yyyy/MM/dd")
    $blobName = "$dateFolder/$((Get-Date).ToUniversalTime().ToString('HHmmss'))-$([guid]::NewGuid().ToString()).json"
    $blobUri = "https://$storageAccount.$storageSuffix/$container/$blobName"
    $storageHeaders = @{
        "Authorization"  = "Bearer $storageToken"
        "x-ms-blob-type" = "BlockBlob"
        "Content-Type"   = "application/json"
        "x-ms-version"   = "2021-08-06"
    }
    $blobBody = $copilotEvents | ConvertTo-Json -Depth 20
    if ($copilotEvents.Count -eq 1) { $blobBody = "[$blobBody]" }

    try {
        Invoke-RestMethod -Uri $blobUri -Method PUT -Headers $storageHeaders -Body $blobBody
        Write-Host "  Written to storage: $blobName"
    }
    catch {
        $stCode = $_.Exception.Response.StatusCode.value__
        if ($stCode -eq 429) {
            Write-Warning "  Storage throttled (429). Retrying in 30s..."
            Start-Sleep -Seconds 30
            try {
                Invoke-RestMethod -Uri $blobUri -Method PUT -Headers $storageHeaders -Body $blobBody
                Write-Host "  Written to storage on retry: $blobName"
            } catch { Write-Warning "  Failed on retry: $($_.Exception.Message)" }
        } else { Write-Warning "  Failed to write to storage: $($_.Exception.Message)" }
    }

    $ingestUri = "$dceUri/dataCollectionRules/$dcrId/streams/${streamName}?api-version=2023-01-01"
    for ($i = 0; $i -lt $copilotEvents.Count; $i += $maxChunkSize) {
        $chunk = @($copilotEvents[$i..([Math]::Min($i + $maxChunkSize - 1, $copilotEvents.Count - 1))])
        $chunkJson = $chunk | ConvertTo-Json -Depth 20 -Compress
        if ($chunk.Count -eq 1) { $chunkJson = "[$chunkJson]" }
        try {
            Invoke-WithRetry -Uri $ingestUri -Method "POST" -Token $monitorToken -Body $chunkJson
            Write-Host "  Sent chunk of $($chunk.Count) events to Log Analytics"
        }
        catch { Write-Warning "  Failed to send to Log Analytics: $($_.Exception.Message)" }
    }
}

Write-Host "Complete. Total Copilot events processed: $totalCopilotEvents"

try {
    Invoke-RestMethod -Uri $stateBlob -Method PUT -Headers @{
        "Authorization"  = "Bearer $storageToken"
        "x-ms-blob-type" = "BlockBlob"
        "Content-Type"   = "text/plain"
        "x-ms-version"   = "2021-08-06"
    } -Body $endTime
    Write-Host "State saved: $endTime"
} catch { Write-Warning "Failed to save state: $($_.Exception.Message)" }
