# Shared helpers dot-sourced by the pull/export functions:
#  - Invoke-HttpWithRetry: retry/backoff for throttling (429) and transient failures
#  - Get-Watermark / Set-Watermark: a "processed up to" timestamp kept in blob storage

# Short, stable, filename-safe id for a string (first 32 hex chars of its SHA-256).
function Get-StableId {
    param([Parameter(Mandatory)][string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value)) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()).Substring(0, 32)
}

# HTTP status code from a failed web request, or $null when there was no HTTP response (network error).
function Get-HttpErrorStatus {
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($response -and $null -ne $response.StatusCode) { return [int]$response.StatusCode }
    return $null
}

# Seconds the server asked us to wait (Retry-After header), or $null.
function Get-RetryAfterSeconds {
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if (-not $response) { return $null }
    try {
        $retryAfter = $response.Headers.RetryAfter   # HttpResponseMessage (PowerShell 7)
        if ($retryAfter) {
            if ($retryAfter.Delta) { return [int][Math]::Ceiling($retryAfter.Delta.TotalSeconds) }
            if ($retryAfter.Date)  { return [int][Math]::Ceiling(($retryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
        }
    } catch { }
    try {
        $raw = $response.Headers['Retry-After']      # HttpWebResponse (Windows PowerShell)
        $seconds = 0
        if ($raw -and [int]::TryParse([string]($raw | Select-Object -First 1), [ref]$seconds)) { return $seconds }
    } catch { }
    return $null
}

# Runs a request script block, retrying 408/429/5xx and network errors with backoff (honouring Retry-After).
# Anything else (400, 401, 403, 404, ...) is rethrown immediately, as is the last failure once attempts run out.
function Invoke-HttpWithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Request,
        [string]$Description = 'HTTP request',
        [int]$MaxAttempts = 5,
        [int]$BaseDelaySeconds = 5,
        [int]$MaxDelaySeconds = 60
    )
    for ($retryAttempt = 1; ; $retryAttempt++) {
        try { return (& $Request) }
        catch {
            $retryStatus = Get-HttpErrorStatus $_
            $isTransient = if ($null -ne $retryStatus) {
                $retryStatus -in 408, 429, 500, 502, 503, 504
            } else {
                $_.Exception -is [System.Net.Http.HttpRequestException] -or
                $_.Exception -is [System.Net.WebException] -or
                $_.Exception -is [System.TimeoutException] -or
                $_.Exception -is [System.Threading.Tasks.TaskCanceledException]
            }
            if (-not $isTransient -or $retryAttempt -ge $MaxAttempts) { throw }

            $retryDelay = Get-RetryAfterSeconds $_
            if ($null -eq $retryDelay -or $retryDelay -lt 1) {
                $retryDelay = $BaseDelaySeconds * [Math]::Pow(2, $retryAttempt - 1)
            }
            $retryDelay = [int][Math]::Min($MaxDelaySeconds, $retryDelay) + (Get-Random -Minimum 0 -Maximum 3)
            $statusText = if ($null -ne $retryStatus) { "HTTP $retryStatus" } else { $_.Exception.GetType().Name }
            Write-Warning "$Description failed ($statusText). Retrying in ${retryDelay}s (attempt $retryAttempt/$MaxAttempts)."
            Start-Sleep -Seconds $retryDelay
        }
    }
}

# Reads a "processed up to" timestamp from a text blob. Returns a UTC DateTime, or $null if missing/unreadable.
function Get-Watermark {
    param([string]$Uri, [string]$Token)
    try {
        $value = Invoke-HttpWithRetry -Description 'Read watermark' -Request {
            Invoke-RestMethod -Uri $Uri -Headers @{ Authorization = "Bearer $Token"; 'x-ms-version' = '2021-08-06' }
        }
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        if ($value -and [datetime]::TryParse(([string]$value).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $parsed
        }
    } catch {
        if ((Get-HttpErrorStatus $_) -ne 404) { Write-Warning "Could not read watermark: $($_.Exception.Message)" }
    }
    return $null
}

# Writes a "processed up to" timestamp. Returns $true on success.
function Set-Watermark {
    param([string]$Uri, [string]$Token, [datetime]$Value)
    try {
        Invoke-HttpWithRetry -Description 'Save watermark' -Request {
            Invoke-RestMethod -Uri $Uri -Method PUT -Body $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') -Headers @{
                Authorization    = "Bearer $Token"
                'x-ms-blob-type' = 'BlockBlob'
                'Content-Type'   = 'text/plain'
                'x-ms-version'   = '2021-08-06'
            } | Out-Null
        }
        return $true
    } catch {
        Write-Warning "Failed to save watermark: $($_.Exception.Message)"
        return $false
    }
}
