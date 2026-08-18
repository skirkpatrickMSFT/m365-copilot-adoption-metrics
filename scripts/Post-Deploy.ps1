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
    [string]$CloudEnvironment = 'Commercial',

    # Set this to grant the Function App managed identity write access to SharePoint
    # so that ExportAdoptionMetrics can push data to the Canvas Power App lists.
    # Example: https://contoso.sharepoint.com/sites/CopilotReporting
    [string]$SharePointSiteUrl = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path (Join-Path $repoRoot 'function-app') 'CloudEnvironment.ps1')
$cloud = Get-CloudEnvironmentConfiguration -CloudEnvironment $CloudEnvironment

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Import-Module Microsoft.Graph.Applications -ErrorAction SilentlyContinue
$scopes = @('AppRoleAssignment.ReadWrite.All')
if ($SharePointSiteUrl) { $scopes += 'Sites.FullControl.All' }
Connect-MgGraph -Scopes $scopes -TenantId $TenantId -Environment $cloud.GraphEnvironment

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
    if (("$($_.Exception.Message) $($_.ErrorDetails.Message)") -match "already exists") {
        Write-Host "ActivityFeed.Read already assigned." -ForegroundColor Green
    } else { throw }
}

Write-Host "`nPost-deployment complete." -ForegroundColor Green

# --- SharePoint: grant Sites.ReadWrite.All so ExportAdoptionMetrics can write list items ---
if ($SharePointSiteUrl) {
    # Sites.Selected limits the MSI to only the named site rather than all sites in the tenant.
    Write-Host "`nGranting SharePoint Sites.Selected to Function App identity..." -ForegroundColor Cyan

    $spResult = Invoke-MgGraphRequest -Method GET `
        -Uri "$($cloud.GraphBaseUri)/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0ff1-ce00-000000000000'"
    $sharePointSp = $spResult.value | Select-Object -First 1

    if (-not $sharePointSp) {
        Write-Warning "SharePoint service principal not found. Ensure SharePoint Online is provisioned in this tenant."
    } else {
        $spRole = $sharePointSp.appRoles | Where-Object { $_.value -eq 'Sites.Selected' }
        if (-not $spRole) {
            Write-Warning "Sites.Selected app role not found on SharePoint service principal."
        } else {
            $spBody = @{
                principalId = $FunctionAppPrincipalId
                resourceId  = $sharePointSp.id
                appRoleId   = $spRole.id
            }
            try {
                Invoke-MgGraphRequest -Method POST `
                    -Uri "$($cloud.GraphBaseUri)/v1.0/servicePrincipals/$FunctionAppPrincipalId/appRoleAssignments" `
                    -Body $spBody
                Write-Host "Sites.Selected assigned successfully." -ForegroundColor Green
            } catch {
                if (("$($_.Exception.Message) $($_.ErrorDetails.Message)") -match "already exists") {
                    Write-Host "Sites.Selected already assigned." -ForegroundColor Green
                } else { throw }
            }

            # Resolve the site ID from the URL and grant write access to just that site.
            Write-Host "Granting write access to $SharePointSiteUrl ..." -ForegroundColor Cyan
            $msiSp    = Invoke-MgGraphRequest -Method GET `
                            -Uri "$($cloud.GraphBaseUri)/v1.0/servicePrincipals/$FunctionAppPrincipalId"
            $siteUri  = [System.Uri]$SharePointSiteUrl
            $siteInfo = Invoke-MgGraphRequest -Method GET `
                            -Uri "$($cloud.GraphBaseUri)/v1.0/sites/$($siteUri.Host):$($siteUri.AbsolutePath)"
            $permBody = @{
                roles               = @('write')
                grantedToIdentities = @(@{
                    application = @{
                        id          = $msiSp.appId
                        displayName = $msiSp.displayName
                    }
                })
            }
            Invoke-MgGraphRequest -Method POST `
                -Uri "$($cloud.GraphBaseUri)/v1.0/sites/$($siteInfo.id)/permissions" `
                -Body $permBody | Out-Null
            Write-Host "Site-level write permission granted." -ForegroundColor Green
        }
    }

    Write-Host @"

SharePoint Lists to create at: $SharePointSiteUrl

  List: CopilotDailyMetrics
    Columns (add as Number unless noted):
      Title          (built-in, Single line of text)
      DAU            (Number)
      TotalInteractions (Number)
      NewUsers       (Number)

  List: CopilotAppMetrics
    Columns:
      Title          (built-in, Single line of text)
      MetricDate     (Date only)
      AppHost        (Single line of text)
      Users          (Number)
      Interactions   (Number)

Then set SHAREPOINT_SITE_URL = $SharePointSiteUrl in the Function App configuration.
"@ -ForegroundColor Yellow
}

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Deploy function code: cd function-app && func azure functionapp publish <func-app-name>"
Write-Host "  2. Or paste code via portal: Function App > Functions > PullCopilotAudit > Code + Test"
Write-Host "  3. Start the audit subscription by creating the StartSubscription timer function (see README)"
Write-Host "  4. Clear profile.ps1 in the Function App (replace with: # no Az modules needed)"
Write-Host "  5. Import the workbook from workbook/copilot-adoption-workbook.json"
