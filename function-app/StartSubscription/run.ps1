param($Timer)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'CloudEnvironment.ps1')

$cloudEnvironment = Get-ConfiguredValue -Value $env:CLOUD_ENVIRONMENT -DefaultValue 'Commercial'
$cloud = Get-CloudEnvironmentConfiguration -CloudEnvironment $cloudEnvironment
$mgmtApiBase = Get-ConfiguredValue -Value $env:MGMT_API_BASE -DefaultValue $cloud.ManagementApi
$tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$mgmtApiBase&api-version=2019-08-01"
$token = (Invoke-RestMethod -Uri $tokenUri -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token

$tenantId = $env:TENANT_ID
$headers = @{ Authorization = "Bearer $token" }
$subscriptionsUri = "$mgmtApiBase/api/v1.0/$tenantId/activity/feed/subscriptions/list"
$subscriptions = @(Invoke-RestMethod -Method GET -Uri $subscriptionsUri -Headers $headers)
$auditSubscription = $subscriptions | Where-Object { $_.contentType -eq 'Audit.General' -and $_.status -eq 'enabled' }
if ($auditSubscription) {
	Write-Host 'Audit.General subscription is already enabled.'
	return
}

$result = Invoke-RestMethod -Method POST -Uri "$mgmtApiBase/api/v1.0/$tenantId/activity/feed/subscriptions/start?contentType=Audit.General" -Headers @{ Authorization = "Bearer $token"; "Content-Length" = "0" }

Write-Host ($result | ConvertTo-Json)
