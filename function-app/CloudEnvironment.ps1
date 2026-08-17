function Get-CloudEnvironmentConfiguration {
    param(
        [ValidateSet('Commercial', 'GCC', 'GCCHigh', 'DoD')]
        [string]$CloudEnvironment = 'Commercial'
    )

    $configurations = @{
        Commercial = @{
            ManagementApi = 'https://manage.office.com'
            MonitorAudience = 'https://monitor.azure.com'
            StorageAudience = 'https://storage.azure.com'
            StorageSuffix = 'blob.core.windows.net'
            GraphEnvironment = 'Global'
            GraphBaseUri = 'https://graph.microsoft.com'
        }
        GCC = @{
            ManagementApi = 'https://manage-gcc.office.com'
            MonitorAudience = 'https://monitor.azure.com'
            StorageAudience = 'https://storage.azure.com'
            StorageSuffix = 'blob.core.windows.net'
            GraphEnvironment = 'Global'
            GraphBaseUri = 'https://graph.microsoft.com'
        }
        GCCHigh = @{
            ManagementApi = 'https://manage.office365.us'
            MonitorAudience = 'https://monitor.azure.us'
            StorageAudience = 'https://storage.azure.com'
            StorageSuffix = 'blob.core.usgovcloudapi.net'
            GraphEnvironment = 'USGov'
            GraphBaseUri = 'https://graph.microsoft.us'
        }
        DoD = @{
            ManagementApi = 'https://manage.protection.apps.mil'
            MonitorAudience = 'https://monitor.azure.us'
            StorageAudience = 'https://storage.azure.com'
            StorageSuffix = 'blob.core.usgovcloudapi.net'
            GraphEnvironment = 'USGovDoD'
            GraphBaseUri = 'https://dod-graph.microsoft.us'
        }
    }

    return $configurations[$CloudEnvironment]
}

function Get-ConfiguredValue {
    param(
        [string]$Value,
        [Parameter(Mandatory)]
        [string]$DefaultValue
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    return $Value
}