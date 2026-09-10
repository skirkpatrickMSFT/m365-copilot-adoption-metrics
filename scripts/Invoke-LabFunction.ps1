<#
.SYNOPSIS
  Manually trigger a function in the lab app and follow its logs in near real time.

.EXAMPLE
  ./Invoke-LabFunction.ps1 -Function StartSubscription
  ./Invoke-LabFunction.ps1 -Function PullCopilotAudit -Follow
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('StartSubscription','PullCopilotAudit','PullCopilotStudioAgents','PullSharePointAgents','ExportAdoptionMetrics')]
    [string]$Function,

    [string]$ResourceGroup = 'rg-copilot-flexlab2',
    [string]$AppName       = 'func-copilot-audit-flex-lab2',
    [string]$AppInsightsId = '5871cfcd-2358-4eea-93f5-22a93758398d',

    # Poll App Insights traces after triggering (until Ctrl+C).
    [switch]$Follow
)

$ErrorActionPreference = 'Stop'

Write-Host "Ensuring public network access is enabled (needed for admin trigger)..." -ForegroundColor Cyan
az functionapp update -g $ResourceGroup -n $AppName --set publicNetworkAccess=Enabled -o none

$key = az functionapp keys list -g $ResourceGroup -n $AppName --query masterKey -o tsv
$uri = "https://$AppName.azurewebsites.net/admin/functions/$Function"

Write-Host "Triggering $Function ..." -ForegroundColor Cyan
$resp = Invoke-WebRequest -Method POST -Uri $uri -Headers @{ 'x-functions-key' = $key } `
    -ContentType 'application/json' -Body '{}' -UseBasicParsing
Write-Host "  HTTP $($resp.StatusCode) (202 = queued OK)" -ForegroundColor Green

if (-not $Follow) {
    Write-Host "Done. Re-run with -Follow to stream logs, or watch Live Metrics in the portal." -ForegroundColor Yellow
    return
}

Write-Host "Following traces for '$Function' (Ctrl+C to stop). ~1-2 min ingestion lag..." -ForegroundColor Cyan
$seen = New-Object System.Collections.Generic.HashSet[string]
while ($true) {
    $q = "union traces,exceptions " +
         "| where timestamp > ago(10m) and operation_Name == '$Function' " +
         "| project timestamp, sev=coalesce(tostring(severityLevel),'EXC'), " +
         "msg=coalesce(message, outerMessage) | order by timestamp asc"
    $json = az monitor app-insights query --app $AppInsightsId --analytics-query $q -o json 2>$null
    if ($json) {
        $rows = ($json | ConvertFrom-Json).tables[0].rows
        foreach ($r in $rows) {
            $id = "$($r[0])|$($r[2])"
            if ($seen.Add($id)) { Write-Host "[$($r[0])] $($r[2])" }
        }
    }
    Start-Sleep -Seconds 15
}
