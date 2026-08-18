@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Your Microsoft Entra tenant ID')
param tenantId string

@description('Target cloud environment')
@allowed(['Commercial', 'GCC', 'GCCHigh', 'DoD'])
param cloudEnvironment string = 'Commercial'

@description('Name for the Log Analytics workspace')
param lawName string = 'law-copilot-adoption'

@description('Name for the Data Collection Endpoint')
param dceName string = 'dce-copilot-audit'

@description('Name for the ADLS Gen2 storage account (audit data archive)')
@minLength(3)
@maxLength(24)
param auditStorageName string

@description('Name for the Function App internal storage account')
@minLength(3)
@maxLength(24)
param funcStorageName string

@description('Name for the Function App')
param funcAppName string = 'func-copilot-audit-ingest'

@description('Name for the Virtual Network')
param vnetName string = 'vnet-copilot-adoption'

@description('Custom table name (without _CL suffix)')
param tableName string = 'CopilotAudit'

@description('SharePoint site URL for the Canvas Power App dashboard (e.g. https://contoso.sharepoint.com/sites/CopilotReporting). Leave empty to skip the metrics export function.')
param sharepointSiteUrl string = ''

@description('Number of days to scan for unprocessed dates on first run or manual backfill.')
param metricsLookbackDays int = 7

@description('Deploy Log Analytics workspace, DCE, DCR, and Application Insights. Set to false for a storage-only deployment that uses only the SharePoint Power App dashboard.')
param deployLogAnalytics bool = true

// Cloud-specific endpoint mappings
var cloudEndpoints = {
  Commercial: {
    managementApi: 'https://manage.office.com'
    monitorAudience: 'https://monitor.azure.com'
    storageAudience: 'https://storage.azure.com'
    storageSuffix: 'blob.core.windows.net'
  }
  GCC: {
    managementApi: 'https://manage-gcc.office.com'
    monitorAudience: 'https://monitor.azure.com'
    storageAudience: 'https://storage.azure.com'
    storageSuffix: 'blob.core.windows.net'
  }
  GCCHigh: {
    managementApi: 'https://manage.office365.us'
    monitorAudience: 'https://monitor.azure.us'
    storageAudience: 'https://storage.azure.com'
    storageSuffix: 'blob.core.usgovcloudapi.net'
  }
  DoD: {
    managementApi: 'https://manage.protection.apps.mil'
    monitorAudience: 'https://monitor.azure.us'
    storageAudience: 'https://storage.azure.com'
    storageSuffix: 'blob.core.usgovcloudapi.net'
  }
}

var selectedCloud = cloudEndpoints[cloudEnvironment]
var isAzureGovernment = contains(['GCCHigh', 'DoD'], cloudEnvironment)
var privateDnsZoneNames = isAzureGovernment ? [
  'privatelink.azurewebsites.us'
  'privatelink.blob.core.usgovcloudapi.net'
  'privatelink.dfs.core.usgovcloudapi.net'
  'privatelink.queue.core.usgovcloudapi.net'
  'privatelink.table.core.usgovcloudapi.net'
  'privatelink.monitor.azure.us'
  'privatelink.adx.monitor.azure.us'
  'privatelink.oms.opinsights.azure.us'
  'privatelink.ods.opinsights.azure.us'
  'privatelink.agentsvc.azure-automation.us'
] : [
  'privatelink.azurewebsites.net'
  'privatelink.blob.core.windows.net'
  'privatelink.dfs.core.windows.net'
  'privatelink.queue.core.windows.net'
  'privatelink.table.core.windows.net'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]
var monitorPrivateDnsZoneNames = skip(privateDnsZoneNames, 5)
// When Log Analytics is not deployed, only create the 5 storage/function DNS zones
var activeDnsZoneNames = deployLogAnalytics ? privateDnsZoneNames : take(privateDnsZoneNames, 5)

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-copilot-egress'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = {
  name: 'nat-copilot-egress'
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      { id: natPublicIp.id }
    ]
  }
}

// VNet
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'snet-func-in'
        properties: {
          addressPrefix: '10.0.1.0/24'
          privateEndpointNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-func-out'
        properties: {
          addressPrefix: '10.0.2.0/24'
          delegations: [
            {
              name: 'delegation-web'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          natGateway: { id: natGateway.id }
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-storage-pe'
        properties: {
          addressPrefix: '10.0.3.0/24'
          privateEndpointNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zoneName in activeDnsZoneNames: {
  name: zoneName
  location: 'global'
}]

resource privateDnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zoneName, index) in activeDnsZoneNames: {
  parent: privateDnsZones[index]
  name: 'vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

// Log Analytics Workspace
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (deployLogAnalytics) {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
  }
}

// Data Collection Endpoint
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = if (deployLogAnalytics) {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Disabled'
    }
  }
}

// Custom table
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (deployLogAnalytics) {
  parent: law
  name: '${tableName}_CL'
  properties: {
    schema: {
      name: '${tableName}_CL'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'CreationTime', type: 'dateTime' }
        { name: 'Operation', type: 'string' }
        { name: 'UserId', type: 'string' }
        { name: 'Workload', type: 'string' }
        { name: 'RecordType', type: 'int' }
        { name: 'OrganizationId', type: 'string' }
        { name: 'ClientIP', type: 'string' }
        { name: 'Id', type: 'string' }
        { name: 'AppHost', type: 'string' }
        { name: 'LicenseType', type: 'string' }
        { name: 'ConversationId', type: 'string' }
        { name: 'TargetAgentName', type: 'string' }
        { name: 'TargetPlatformAgentId', type: 'string' }
        { name: 'DLPEvaluationDeferred', type: 'int' }
        { name: 'MemoryUpdated', type: 'boolean' }
        { name: 'CopilotLogVersion', type: 'string' }
      ]
    }
    plan: 'Analytics'
  }
}

// Data Collection Rule
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = if (deployLogAnalytics) {
  name: 'dcr-copilot-audit'
  location: location
  dependsOn: [customTable]
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-${tableName}_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'CreationTime', type: 'datetime' }
          { name: 'Operation', type: 'string' }
          { name: 'UserId', type: 'string' }
          { name: 'Workload', type: 'string' }
          { name: 'RecordType', type: 'int' }
          { name: 'OrganizationId', type: 'string' }
          { name: 'ClientIP', type: 'string' }
          { name: 'Id', type: 'string' }
          { name: 'AppHost', type: 'string' }
          { name: 'LicenseType', type: 'string' }
          { name: 'ConversationId', type: 'string' }
          { name: 'TargetAgentName', type: 'string' }
          { name: 'TargetPlatformAgentId', type: 'string' }
          { name: 'DLPEvaluationDeferred', type: 'int' }
          { name: 'MemoryUpdated', type: 'boolean' }
          { name: 'CopilotLogVersion', type: 'string' }
          { name: 'CopilotEventData', type: 'dynamic' }
        ]
      }
    }
    dataSources: {}
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'lawDest'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-${tableName}_CL']
        destinations: ['lawDest']
        transformKql: 'source | extend TimeGenerated = todatetime(CreationTime), AppHost = tostring(parse_json(CopilotEventData).AppHost), LicenseType = tostring(parse_json(CopilotEventData).LicenseType), ConversationId = tostring(parse_json(CopilotEventData).ConversationId), TargetAgentName = tostring(parse_json(CopilotEventData).TargetAgentName), TargetPlatformAgentId = tostring(parse_json(CopilotEventData).TargetPlatformAgentId) | project-away CopilotEventData'
        outputStream: 'Custom-${tableName}_CL'
      }
    ]
  }
}

// ADLS Gen2 Storage (audit data)
resource auditStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: auditStorageName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    isHnsEnabled: true
    publicNetworkAccess: 'Disabled'
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${auditStorage.name}/default/copilot-logs'
}

// Function App internal storage
resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: funcStorageName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    publicNetworkAccess: 'Disabled'
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// App Service Plan (Elastic Premium)
resource asp 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-copilot-adoption'
  location: location
  kind: 'elastic'
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
  }
  properties: {
    maximumElasticWorkerCount: 20
  }
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (deployLogAnalytics) {
  name: funcAppName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// Function App
resource funcApp 'Microsoft.Web/sites@2023-12-01' = {
  name: funcAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: asp.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: vnet.properties.subnets[1].id
    vnetRouteAllEnabled: true
    siteConfig: {
      powerShellVersion: '7.4'
      netFrameworkVersion: 'v8.0'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'AzureWebJobsStorage__accountName', value: funcStorage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: deployLogAnalytics ? appInsights.properties.ConnectionString : '' }
        { name: 'TENANT_ID', value: tenantId }
        { name: 'DCE_INGESTION_URI', value: deployLogAnalytics ? dce.properties.logsIngestion.endpoint : '' }
        { name: 'DCR_IMMUTABLE_ID', value: deployLogAnalytics ? dcr.properties.immutableId : '' }
        { name: 'STREAM_NAME', value: deployLogAnalytics ? 'Custom-${tableName}_CL' : '' }
        { name: 'STORAGE_ACCOUNT_NAME', value: auditStorage.name }
        { name: 'STORAGE_CONTAINER_NAME', value: 'copilot-logs' }
        { name: 'TIME_WINDOW_MINUTES', value: '16' }
        { name: 'CLOUD_ENVIRONMENT', value: cloudEnvironment }
        { name: 'MGMT_API_BASE', value: selectedCloud.managementApi }
        { name: 'MONITOR_AUDIENCE', value: selectedCloud.monitorAudience }
        { name: 'STORAGE_AUDIENCE', value: selectedCloud.storageAudience }
        { name: 'STORAGE_SUFFIX', value: selectedCloud.storageSuffix }
        { name: 'SHAREPOINT_SITE_URL', value: sharepointSiteUrl }
        { name: 'SHAREPOINT_DAILY_LIST', value: 'CopilotDailyMetrics' }
        { name: 'SHAREPOINT_APP_LIST', value: 'CopilotAppMetrics' }
        { name: 'SHAREPOINT_WEEKLY_LIST', value: 'CopilotWeeklyMetrics' }
        { name: 'SHAREPOINT_WEEKLY_APP_LIST', value: 'CopilotWeeklyAppMetrics' }
        { name: 'METRICS_LOOKBACK_DAYS', value: string(metricsLookbackDays) }
        { name: 'METRICS_EXPORT_SCHEDULE', value: '0 0 */4 * * *' }
      ]
    }
  }
}

// Private Endpoints

// Function App inbound PE
resource peFuncInbound 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-func-copilot-inbound'
  location: location
  properties: {
    subnet: { id: vnet.properties.subnets[0].id }
    privateLinkServiceConnections: [
      {
        name: 'pe-func-copilot-inbound'
        properties: {
          privateLinkServiceId: funcApp.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

resource peFuncInboundDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peFuncInbound
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: { privateDnsZoneId: privateDnsZones[0].id }
      }
    ]
  }
}

// Audit storage blob PE
resource peAuditBlob 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-storage-copilot-blob'
  location: location
  properties: {
    subnet: { id: vnet.properties.subnets[2].id }
    privateLinkServiceConnections: [
      {
        name: 'pe-storage-copilot-blob'
        properties: {
          privateLinkServiceId: auditStorage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource peAuditBlobDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peAuditBlob
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: { privateDnsZoneId: privateDnsZones[1].id }
      }
    ]
  }
}

// Audit storage DFS PE (for Power BI)
resource peAuditDfs 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-storage-copilot-dfs'
  location: location
  properties: {
    subnet: { id: vnet.properties.subnets[2].id }
    privateLinkServiceConnections: [
      {
        name: 'pe-storage-copilot-dfs'
        properties: {
          privateLinkServiceId: auditStorage.id
          groupIds: ['dfs']
        }
      }
    ]
  }
}

resource peAuditDfsDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peAuditDfs
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'dfs'
        properties: { privateDnsZoneId: privateDnsZones[2].id }
      }
    ]
  }
}

// Function storage blob PE
resource peFuncBlob 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-func-storage-blob'
  location: location
  properties: {
    subnet: { id: vnet.properties.subnets[2].id }
    privateLinkServiceConnections: [
      {
        name: 'pe-func-storage-blob'
        properties: {
          privateLinkServiceId: funcStorage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource peFuncBlobDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peFuncBlob
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: { privateDnsZoneId: privateDnsZones[1].id }
      }
    ]
  }
}

// Function storage queue PE
resource peFuncQueue 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-func-storage-queue'
  location: location
  properties: {
    subnet: { id: vnet.properties.subnets[2].id }
    privateLinkServiceConnections: [
      {
        name: 'pe-func-storage-queue'
        properties: {
          privateLinkServiceId: funcStorage.id
          groupIds: ['queue']
        }
      }
    ]
  }
}

resource peFuncQueueDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peFuncQueue
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'queue'
        properties: { privateDnsZoneId: privateDnsZones[3].id }
      }
    ]
  }
}

// Function storage table PE
resource peFuncTable 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-func-storage-table'
  location: location
  properties: {
    subnet: { id: vnet.properties.subnets[2].id }
    privateLinkServiceConnections: [
      {
        name: 'pe-func-storage-table'
        properties: {
          privateLinkServiceId: funcStorage.id
          groupIds: ['table']
        }
      }
    ]
  }
}

resource peFuncTableDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peFuncTable
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'table'
        properties: { privateDnsZoneId: privateDnsZones[4].id }
      }
    ]
  }
}

// AMPLS
resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = if (deployLogAnalytics) {
  name: 'ampls-copilot-adoption'
  location: 'global'
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'Open'
    }
  }
}

resource amplsLaw 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = if (deployLogAnalytics) {
  parent: ampls
  name: 'scoped-law'
  properties: {
    linkedResourceId: law.id
  }
}

resource amplsDce 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = if (deployLogAnalytics) {
  parent: ampls
  name: 'scoped-dce'
  properties: {
    linkedResourceId: dce.id
  }
}

resource amplsAppInsights 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = if (deployLogAnalytics) {
  parent: ampls
  name: 'scoped-app-insights'
  properties: {
    linkedResourceId: appInsights.id
  }
}

resource peAmpls 'Microsoft.Network/privateEndpoints@2024-01-01' = if (deployLogAnalytics) {
  name: 'pe-ampls-copilot'
  location: location
  properties: {
    subnet: { id: vnet.properties.subnets[2].id }
    privateLinkServiceConnections: [
      {
        name: 'pe-ampls-copilot'
        properties: {
          privateLinkServiceId: ampls.id
          groupIds: ['azuremonitor']
        }
      }
    ]
  }
}

resource peAmplsDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (deployLogAnalytics) {
  parent: peAmpls
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zoneName, index) in monitorPrivateDnsZoneNames: {
      name: 'monitor-${index + 5}'
      properties: { privateDnsZoneId: privateDnsZones[index + 5].id }
    }]
  }
}

// Role assignments

// Monitoring Metrics Publisher on DCR for Function App
resource roleMonitorPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployLogAnalytics) {
  name: guid(dcr.id, funcApp.id, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Contributor on audit storage for Function App
resource roleBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(auditStorage.id, funcApp.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: auditStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Owner on func storage for Function App
resource roleFuncBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcStorage.id, funcApp.id, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  scope: funcStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor on func storage
resource roleFuncQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcStorage.id, funcApp.id, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  scope: funcStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor on func storage
resource roleFuncTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcStorage.id, funcApp.id, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  scope: funcStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Outputs
output functionAppName string = funcApp.name
output functionAppPrincipalId string = funcApp.identity.principalId
output dceIngestionUri string = deployLogAnalytics ? dce.properties.logsIngestion.endpoint : ''
output dcrImmutableId string = deployLogAnalytics ? dcr.properties.immutableId : ''
output streamName string = deployLogAnalytics ? 'Custom-${tableName}_CL' : ''
output lawWorkspaceId string = deployLogAnalytics ? law.properties.customerId : ''
output auditStorageName string = auditStorage.name
output postDeployMessage string = 'After deployment: 1) Grant ActivityFeed.Read to the Function App identity (${funcApp.identity.principalId}) via PowerShell. 2) Start the Audit.General subscription. 3) Deploy the function code. 4) Clear profile.ps1. See README.md for details.'
