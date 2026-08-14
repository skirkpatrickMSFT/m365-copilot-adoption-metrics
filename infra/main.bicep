@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Your Microsoft Entra tenant ID')
param tenantId string

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

// Log Analytics Workspace
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
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
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Disabled'
    }
  }
}

// Custom table
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
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
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
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
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
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
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'TENANT_ID', value: tenantId }
        { name: 'DCE_INGESTION_URI', value: dce.properties.logsIngestion.endpoint }
        { name: 'DCR_IMMUTABLE_ID', value: dcr.properties.immutableId }
        { name: 'STREAM_NAME', value: 'Custom-${tableName}_CL' }
        { name: 'STORAGE_ACCOUNT_NAME', value: auditStorage.name }
        { name: 'STORAGE_CONTAINER_NAME', value: 'copilot-logs' }
        { name: 'TIME_WINDOW_MINUTES', value: '16' }
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

// DCE PE
resource peDce 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: 'pe-dce-copilot'
  location: location
  properties: {
    subnet: { id: vnet.properties.subnets[2].id }
    privateLinkServiceConnections: [
      {
        name: 'pe-dce-copilot'
        properties: {
          privateLinkServiceId: dce.id
          groupIds: ['log']
        }
      }
    ]
  }
}

// AMPLS
resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: 'ampls-copilot-adoption'
  location: 'global'
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'Open'
    }
  }
}

resource amplsLaw 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'scoped-law'
  properties: {
    linkedResourceId: law.id
  }
}

resource amplsDce 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'scoped-dce'
  properties: {
    linkedResourceId: dce.id
  }
}

resource peAmpls 'Microsoft.Network/privateEndpoints@2024-01-01' = {
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

// Role assignments

// Monitoring Metrics Publisher on DCR for Function App
resource roleMonitorPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
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
output dceIngestionUri string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output streamName string = 'Custom-${tableName}_CL'
output lawWorkspaceId string = law.properties.customerId
output auditStorageName string = auditStorage.name
output postDeployMessage string = 'After deployment: 1) Grant ActivityFeed.Read to the Function App identity (${funcApp.identity.principalId}) via PowerShell. 2) Start the Audit.General subscription. 3) Deploy the function code. 4) Clear profile.ps1. See README.md for details.'
