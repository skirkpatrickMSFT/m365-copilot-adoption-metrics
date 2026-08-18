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
// Optional: set to your SharePoint site URL to enable the Canvas Power App dashboard.
// Example: https://contoso.sharepoint.com/sites/CopilotReporting
param sharepointSiteUrl = ''
param metricsLookbackDays = 7
// Set to false to skip Log Analytics, DCE, DCR, and Application Insights (storage + SharePoint only)
param deployLogAnalytics = true
