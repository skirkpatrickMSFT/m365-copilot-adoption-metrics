<#
.SYNOPSIS
    Post-deployment script: grants ActivityFeed.Read to the Function App identity and starts the audit subscription.
.DESCRIPTION
    Run this locally (not in Cloud Shell) after the Bicep deployment completes.
    Requires: Microsoft.Graph PowerShell module
.PARAMETER TenantId
    Your Entra tenant ID
.PARAMETER FunctionAppPrincipalId
    The system-assigned managed identity Object ID from the Function App (output of Bicep deployment)
.PARAMETER CloudEnvironment
    Target Microsoft 365 cloud environment.
#>
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$FunctionAppPrincipalId,

    [ValidateSet('Commercial', 'GCC', 'GCCHigh', 'DoD')]
    [string]$CloudEnvironment = 'Commercial'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path (Join-Path $repoRoot 'function-app') 'CloudEnvironment.ps1')
$cloud = Get-CloudEnvironmentConfiguration -CloudEnvironment $CloudEnvironment

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Import-Module Microsoft.Graph.Applications -ErrorAction SilentlyContinue
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All" -TenantId $TenantId -Environment $cloud.GraphEnvironment

Write-Host "Finding Office 365 Management APIs service principal..." -ForegroundColor Cyan
$result = Invoke-MgGraphRequest -Method GET -Uri "$($cloud.GraphBaseUri)/v1.0/servicePrincipals?`$filter=displayName eq 'Office 365 Management APIs'"
$managementApi = $result.value[0]

if (-not $managementApi) {
    throw "Office 365 Management APIs service principal was not found in $CloudEnvironment. Add the Office 365 Management APIs enterprise application in this tenant, then rerun this script."
}

$role = $managementApi.appRoles | Where-Object { $_.value -eq "ActivityFeed.Read" }
if (-not $role) {
    throw "ActivityFeed.Read is not exposed by the Office 365 Management APIs service principal in $CloudEnvironment."
}

Write-Host "Assigning ActivityFeed.Read to Function App identity..." -ForegroundColor Cyan
$body = @{
    principalId = $FunctionAppPrincipalId
    resourceId  = $managementApi.id
    appRoleId   = $role.id
}

try {
    Invoke-MgGraphRequest -Method POST -Uri "$($cloud.GraphBaseUri)/v1.0/servicePrincipals/$FunctionAppPrincipalId/appRoleAssignments" -Body $body
    Write-Host "ActivityFeed.Read assigned successfully." -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "already exists") {
        Write-Host "ActivityFeed.Read already assigned." -ForegroundColor Green
    } else { throw }
}

Write-Host "`nPost-deployment complete." -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Deploy function code: cd function-app && func azure functionapp publish <func-app-name>"
Write-Host "  2. Or paste code via portal: Function App > Functions > PullCopilotAudit > Code + Test"
Write-Host "  3. Start the audit subscription by creating the StartSubscription timer function (see README)"
Write-Host "  4. Clear profile.ps1 in the Function App (replace with: # no Az modules needed)"
Write-Host "  5. Import the workbook from workbook/copilot-adoption-workbook.json"
