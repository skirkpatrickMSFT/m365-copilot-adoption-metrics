using './main.bicep'

param tenantId = ''
// Replace these globally unique placeholder names before deployment.
param auditStorageName = 'replaceauditstorage'
param funcStorageName = 'replacefuncstorage'
param cloudEnvironment = 'Commercial'
param funcAppName = 'func-copilot-audit-ingest'
param lawName = 'law-copilot-adoption'
param dceName = 'dce-copilot-audit'
param vnetName = 'vnet-copilot-adoption'
param tableName = 'CopilotAudit'
// Blob container Flex Consumption uses to stage the deployment package (identity-based access).
param deploymentContainerName = 'app-package'
// Flex Consumption scale settings.
param instanceMemoryMB = 2048
param maximumInstanceCount = 40
// Production: keep AMPLS ingestion PrivateOnly. Use 'Open' only for lab validation.
param amplsIngestionAccessMode = 'PrivateOnly'
// Optional: set to your SharePoint site URL to enable the Canvas Power App dashboard.
// Example: https://contoso.sharepoint.com/sites/CopilotReporting
param sharepointSiteUrl = ''
param metricsLookbackDays = 7
// Set to false to skip Log Analytics, DCE, DCR, and Application Insights (storage + SharePoint only)
param deployLogAnalytics = true
