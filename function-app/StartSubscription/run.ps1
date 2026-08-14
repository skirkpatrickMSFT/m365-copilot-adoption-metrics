param($Timer)

$tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=https://manage.office.com&api-version=2019-08-01"
$token = (Invoke-RestMethod -Uri $tokenUri -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }).access_token

$tenantId = $env:TENANT_ID
$result = Invoke-RestMethod -Method POST -Uri "https://manage.office.com/api/v1.0/$tenantId/activity/feed/subscriptions/start?contentType=Audit.General" -Headers @{ Authorization = "Bearer $token"; "Content-Length" = "0" }

Write-Host ($result | ConvertTo-Json)
