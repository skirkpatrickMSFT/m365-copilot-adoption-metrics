// ============================================================
// CopilotAudit_ADLS.pq
// Power Query (M) source — connects Power BI directly to the
// ADLS Gen2 audit storage account (copilot-logs container).
//
// ⚠️  NETWORKING REQUIREMENT:
//     The storage account has publicNetworkAccess = Disabled and
//     uses private endpoints. This query requires an On-Premises
//     Data Gateway installed on a machine that can reach the
//     storage private endpoint.
//     See: https://learn.microsoft.com/power-bi/connect-data/service-gateway-onprem
//
// Usage:
//   1. Replace YOUR_AUDIT_STORAGE_NAME with your storage account name
//      (the auditStorageName parameter from your Bicep deployment).
//   2. For GCC High / DoD, change StorageSuffix to:
//      dfs.core.usgovcloudapi.net
// ============================================================

let
    StorageAccountName = "YOUR_AUDIT_STORAGE_NAME",
    StorageSuffix      = "dfs.core.windows.net", // GCC High/DoD: dfs.core.usgovcloudapi.net
    ContainerName      = "copilot-logs",
    AccountUrl         = "https://" & StorageAccountName & "." & StorageSuffix,

    // List all files from the storage account (non-hierarchical for easier filtering)
    Source = AzureDataLakeStorage.Files(AccountUrl, [HierarchicalNavigation = false]),

    // Keep only .json files inside the container, excluding the _state folder
    FilteredFiles = Table.SelectRows(Source, each
        Text.StartsWith([Folder Path], AccountUrl & "/" & ContainerName & "/") and
        [Extension] = ".json" and
        not Text.Contains([Folder Path], "/_state/")),

    // Read binary content as text
    AddedText = Table.AddColumn(FilteredFiles, "RawJson",
        each Text.FromBinary([Content]), type text),

    // Parse each file as a JSON array of events
    ParsedJson = Table.AddColumn(AddedText, "Events",
        each try Json.Document([RawJson]) otherwise null),

    // Drop any files that failed to parse
    ValidFiles = Table.SelectRows(ParsedJson, each [Events] <> null and [Events] is list),

    // Expand the list of events per file into individual rows
    ExpandedList = Table.ExpandListColumn(ValidFiles, "Events"),

    // Expand all event fields
    ExpandedEvents = Table.ExpandRecordColumn(ExpandedList, "Events", {
        "CreationTime",
        "Id",
        "Operation",
        "Workload",
        "UserId",
        "RecordType",
        "OrganizationId",
        "ClientIP",
        "AppHost",
        "LicenseType",
        "ConversationId",
        "TargetAgentName",
        "TargetPlatformAgentId",
        "DLPEvaluationDeferred",
        "MemoryUpdated",
        "CopilotLogVersion"
    }),

    // Remove file-level columns no longer needed
    SelectedColumns = Table.SelectColumns(ExpandedEvents, {
        "CreationTime",
        "Id",
        "Operation",
        "Workload",
        "UserId",
        "RecordType",
        "OrganizationId",
        "ClientIP",
        "AppHost",
        "LicenseType",
        "ConversationId",
        "TargetAgentName",
        "TargetPlatformAgentId",
        "DLPEvaluationDeferred",
        "MemoryUpdated",
        "CopilotLogVersion"
    }),

    // Set column types
    TypedTable = Table.TransformColumnTypes(SelectedColumns, {
        {"CreationTime",          type datetimezone},
        {"Id",                    type text},
        {"Operation",             type text},
        {"Workload",              type text},
        {"UserId",                type text},
        {"RecordType",            Int64.Type},
        {"OrganizationId",        type text},
        {"ClientIP",              type text},
        {"AppHost",               type text},
        {"LicenseType",           type text},
        {"ConversationId",        type text},
        {"TargetAgentName",       type text},
        {"TargetPlatformAgentId", type text},
        {"DLPEvaluationDeferred", Int64.Type},
        {"MemoryUpdated",         type logical},
        {"CopilotLogVersion",     type text}
    }),

    // Add computed columns for time intelligence
    AddedDate = Table.AddColumn(TypedTable, "Date",
        each Date.From(DateTimeZone.ToLocal([CreationTime])), type date),

    AddedHour = Table.AddColumn(AddedDate, "HourOfDay",
        each Time.Hour(DateTime.Time(DateTimeZone.RemoveZone(
            DateTimeZone.ToLocal([CreationTime])))), Int64.Type)

in
    AddedHour
