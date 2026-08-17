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
