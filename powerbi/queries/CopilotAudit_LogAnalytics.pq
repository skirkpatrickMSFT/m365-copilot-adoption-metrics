// ============================================================
// CopilotAudit_LogAnalytics.pq
// Power Query (M) source — connects Power BI to the
// CopilotAudit_CL table in the Log Analytics workspace
// deployed by this solution.
//
// Usage:
//   1. In Power BI Desktop, open Power Query Editor.
//   2. New Source → Blank Query → Advanced Editor.
//   3. Paste this file and replace YOUR_WORKSPACE_URL.
//
// Workspace URL formats:
//   Commercial / GCC:
//     https://ade.loganalytics.io/v0/subscriptions/{subId}/resourcegroups/{rg}/providers/microsoft.operationalinsights/workspaces/law-copilot-adoption
//   GCC High / DoD:
//     https://ade.loganalytics.azure.us/v0/subscriptions/{subId}/resourcegroups/{rg}/providers/microsoft.operationalinsights/workspaces/law-copilot-adoption
// ============================================================

let
    WorkspaceUrl = "YOUR_WORKSPACE_URL",

    Source = AzureAnalytics.Contents(WorkspaceUrl),

    // Navigate to the custom table
    CopilotAudit_CL = Source{[Name = "CopilotAudit_CL"]}[Data],

    // Keep only Copilot workload rows (defensive filter; the table should only contain these)
    FilteredRows = Table.SelectRows(CopilotAudit_CL, each [Workload] = "Copilot"),

    // Project to the defined schema columns only
    SelectedColumns = Table.SelectColumns(FilteredRows, {
        "TimeGenerated",
        "CreationTime",
        "Operation",
        "UserId",
        "Workload",
        "AppHost",
        "LicenseType",
        "ConversationId",
        "TargetAgentName",
        "TargetPlatformAgentId",
        "DLPEvaluationDeferred",
        "MemoryUpdated",
        "CopilotLogVersion",
        "ClientIP",
        "OrganizationId",
        "RecordType",
        "Id"
    }),

    // Enforce column types for reliable DAX calculations
    TypedTable = Table.TransformColumnTypes(SelectedColumns, {
        {"TimeGenerated",            type datetimezone},
        {"CreationTime",             type datetimezone},
        {"Operation",                type text},
        {"UserId",                   type text},
        {"Workload",                 type text},
        {"AppHost",                  type text},
        {"LicenseType",              type text},
        {"ConversationId",           type text},
        {"TargetAgentName",          type text},
        {"TargetPlatformAgentId",    type text},
        {"DLPEvaluationDeferred",    Int64.Type},
        {"MemoryUpdated",            type logical},
        {"CopilotLogVersion",        type text},
        {"ClientIP",                 type text},
        {"OrganizationId",           type text},
        {"RecordType",               Int64.Type},
        {"Id",                       type text}
    }),

    // Add a local-date column for time intelligence (strips timezone for DAX date tables)
    AddedDate = Table.AddColumn(TypedTable, "Date",
        each Date.From(DateTimeZone.ToLocal([CreationTime])), type date),

    AddedHour = Table.AddColumn(AddedDate, "HourOfDay",
        each Time.Hour(DateTime.Time(DateTimeZone.RemoveZone(
            DateTimeZone.ToLocal([CreationTime])))), Int64.Type)

in
    AddedHour
