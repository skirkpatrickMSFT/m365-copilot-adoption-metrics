# Copilot Adoption Dashboard

Automated collection and visualization of Microsoft 365 Copilot usage metrics from the Unified Audit Log.

Two deployment paths are available:

- **Deploy to Azure button** — one-click ARM deployment for Azure infrastructure, then follow the steps below
- **Step-by-step guide** — see `Full_Implementation_Guide_No_Bicep.docx` for a complete walkthrough without Bicep

## Deployment Modes

The `deployLogAnalytics` parameter controls whether Log Analytics, Application Insights, and the AMPLS private endpoint are deployed. Both modes include the Function App, VNet, private endpoints, ADLS Gen2 audit storage, and the SharePoint Power App pipeline.

| Component | Full (default) | Storage + SharePoint only |
|-----------|:--------------:|:-------------------------:|
| `deployLogAnalytics` | `true` | `false` |
| ADLS Gen2 audit archive | ✓ | ✓ |
| SharePoint Power App dashboard | ✓ | ✓ |
| Log Analytics workspace | ✓ | — |
| Data Collection Endpoint + Rule | ✓ | — |
| Application Insights | ✓ | — |
| AMPLS private endpoint | ✓ | — |
| Azure Monitor Workbook | ✓ | — |

Steps marked **(Log Analytics only)** below apply only to the full deployment.

## Architecture

```
Office 365 Management Activity API (manage.office.com)
        │ every 15 min (PullCopilotAudit timer)
        ▼
Azure Function App (Flex Consumption FC1, PowerShell 7.4)
  • Managed Identity auth — no secrets, no shared keys
  • Pagination, 500-event chunking, 429 throttle retry
  • State-tracked processing — no duplicate events
  • VNet integrated + private endpoints throughout
        │
   ┌────┴──────────────────────────────┐
   ▼                                   ▼
ADLS Gen2                    [Log Analytics only]
(copilot-logs archive)        Log Analytics (CopilotAudit_CL)
   │                               │
   ▼                               ▼
ExportAdoptionMetrics      Azure Monitor Workbook
(every 4 h, incremental)   (near-real-time KQL dashboard)
   │
   ▼
SharePoint Lists ──▶ Optional - Canvas Power App Dashboard
(CopilotDailyMetrics,    (long-term adoption reporting)
 CopilotAppMetrics,
 CopilotWeeklyMetrics,
 CopilotWeeklyAppMetrics)
```

## Prerequisites

| Requirement | Details |
|------------|---------|
| Azure Subscription | Contributor role; `Microsoft.App` resource provider registered (Flex Consumption) |
| Microsoft 365 | E5 or Copilot add-on with Unified Audit Log enabled |
| Copilot Licenses | Assigned to users who actively use Copilot |
| Local PowerShell | Microsoft.Graph module (`Install-Module Microsoft.Graph`) |
| Admin Role | Global Admin or Security Admin |
| SharePoint Online | Site for the Canvas Power App dashboard |

## Deploy

### 1. Deploy Infrastructure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FskirkpatrickMSFT%2Fm365-copilot-adoption-metrics%2Fmain%2Finfra%2Fazuredeploy.json)

> The Deploy to Azure button targets Commercial Azure. For GCC High / DoD, use the CLI path below.

**Full deployment (Log Analytics + SharePoint Power App):**

```bash
az group create --name rg-copilot-adoption --location <region>

az deployment group create \
  --resource-group rg-copilot-adoption \
  --template-file infra/main.bicep \
  --parameters tenantId=<your-tenant-id> \
               auditStorageName=<globally-unique-name> \
               funcStorageName=<globally-unique-name> \
               sharepointSiteUrl=https://contoso.sharepoint.com/sites/CopilotReporting
```

**Storage + SharePoint only (skip Log Analytics):**

```bash
az deployment group create \
  --resource-group rg-copilot-adoption \
  --template-file infra/main.bicep \
  --parameters tenantId=<your-tenant-id> \
               auditStorageName=<globally-unique-name> \
               funcStorageName=<globally-unique-name> \
               sharepointSiteUrl=https://contoso.sharepoint.com/sites/CopilotReporting \
               deployLogAnalytics=false
```

**Failure alerts (optional):** when Log Analytics / Application Insights is deployed, a log-search alert named `alert-<funcAppName>-failed-runs` is created. It fires when a 15-minute function fails twice within an hour, or when `ExportAdoptionMetrics` fails once. Add `alertEmailAddress=you@contoso.com` to the deployment to create an action group that emails you; with it empty the rule is still created and shows under Azure Monitor → Alerts.
### 2. Grant API Permissions (post-deployment)

Run **locally** — Cloud Shell cannot acquire tokens for manage.office.com:

```powershell
.\scripts\Post-Deploy.ps1 `
  -TenantId <your-tenant-id> `
  -FunctionAppPrincipalId <from-deployment-output> `
  -CloudEnvironment Commercial
```

The `FunctionAppPrincipalId` is in the deployment output as `functionAppPrincipalId`.

This script grants `ActivityFeed.Read` to the Function App managed identity (for the Office 365 Audit API). It does **not** grant SharePoint access — see the next section.

A browser sign-in popup will appear — check your taskbar if it opens behind other windows.

#### 2b. Grant SharePoint site access (required for the SharePoint lists)

The Function App identity needs two things before it can write to the reporting site. Without them, SharePoint calls fail with `401 Unauthorized`.

1. **App role:** assign `Sites.Selected` on *Office 365 SharePoint Online* to the identity. This can be done with an account that can manage app role assignments:

   ```powershell
   Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All" -TenantId <your-tenant-id>
   $spo  = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0ff1-ce00-000000000000'").value[0]
   $role = $spo.appRoles | Where-Object value -eq 'Sites.Selected'
   Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/<functionAppPrincipalId>/appRoleAssignments" `
     -Body (@{ principalId = '<functionAppPrincipalId>'; resourceId = $spo.id; appRoleId = $role.id } | ConvertTo-Json) -ContentType 'application/json'
   ```

2. **Site grant:** give that identity `write` on the reporting site. This needs a sign-in with `Sites.FullControl.All` (admin consent):

   ```powershell
   Connect-MgGraph -Scopes "Sites.FullControl.All" -TenantId <your-tenant-id>
   $site = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/sites/<tenant>.sharepoint.com:/sites/CopilotReporting"
   $body = @{ roles = @('write'); grantedToIdentities = @(@{ application = @{ id = '<identity-client-id>'; displayName = '<function-app-name>' } }) } | ConvertTo-Json -Depth 5
   Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/permissions" -Body $body -ContentType 'application/json'
   ```

   `<identity-client-id>` is the identity's application (client) ID, not its object ID. To confirm the grant, list `https://graph.microsoft.com/v1.0/sites/<site-id>/permissions` and check the app has `write`.

> **Notes**
> - If your tenant requires passkey sign-in, run `Set-MgGraphOption -EnableLoginByWAM $true` before `Connect-MgGraph` so the Windows broker handles the sign-in.
> - Managed-identity tokens are cached for up to about 24 hours. After granting a new role, the app may keep returning `401` until the cached token expires.

### 3. Enable Auditing in Microsoft Purview

1. Go to https://purview.microsoft.com
2. Left nav → **Audit** (under Solutions)
3. If not enabled, click **Start recording user and admin activity**

### 4. Deploy Function Code

The function app has `publicNetworkAccess: Disabled` with private endpoints — the portal editor is read-only. Use the Core Tools publish path, temporarily opening public access:

```powershell
az functionapp update --resource-group rg-copilot-adoption --name <func-app-name> --set publicNetworkAccess=Enabled
Start-Sleep -Seconds 45
cd function-app
func azure functionapp publish <func-app-name> --powershell
cd ..
az functionapp update --resource-group rg-copilot-adoption --name <func-app-name> --set publicNetworkAccess=Disabled
```

This deploys all four functions: `PullCopilotAudit`, `ExportAdoptionMetrics`, `PullSharePointAgents`, and `StartSubscription`.

### 5. Clear profile.ps1

Function App → **App files** → select `profile.ps1` → replace with:

```powershell
# Azure Functions profile - no Az modules needed
```

Save. This prevents unnecessary module load on every cold start.

### 6. Start the Audit Subscription (one-time)

The `StartSubscription` function activates the Management Activity API subscription automatically on its next timer tick (every 15 min). You can also trigger it manually:

Function App → Functions → **StartSubscription** → **Code + Test** → **Test/Run** → Run

Check Application Insights logs for `"status":"enabled"`. Once confirmed, you can leave `StartSubscription` in place — it is idempotent and exits immediately if the subscription is already active.

### 7. Set Up SharePoint Lists

Create these lists at your SharePoint site (the six below, including the agent registry and inactive-agents lists). Column names must match exactly.

**CopilotDailyMetrics**
| Column | Type |
|--------|------|
| Title | Single line of text (built-in — hide from view) |
| MetricDate | Date and time → Date only |
| DAU | Number |
| TotalInteractions | Number |
| NewUsers | Number |

**CopilotAppMetrics**
| Column | Type |
|--------|------|
| Title | Single line of text (built-in — hide from view) |
| MetricDate | Date and time → Date only |
| AppHost | Single line of text |
| Users | Number |
| Interactions | Number |

**CopilotWeeklyMetrics**
| Column | Type |
|--------|------|
| Title | Single line of text (built-in — hide from view) |
| WeekStart | Date and time → Date only |
| WeekEnd | Date and time → Date only |
| TotalInteractions | Number |
| UniqueUsers | Number |
| NewUsers | Number |
| AppsUsed | Single line of text |

**CopilotWeeklyAppMetrics**
| Column | Type |
|--------|------|
| Title | Single line of text (built-in — hide from view) |
| WeekStart | Date and time → Date only |
| AppHost | Single line of text |
| Interactions | Number |
| Users | Number |

> To hide the Title column from view: column header → **Column settings → Hide in view**.

**SharePointCopilotAgentRegistry** — running log of every Copilot agent created, updated automatically by `PullSharePointAgents`. `ExportAdoptionMetrics` also maintains the last three columns from Copilot interaction audit events.

| Column | Type |
|--------|------|
| Title | Single line of text (built-in — hide from view) |
| AgentName | Single line of text |
| SiteUrl | Single line of text |
| AgentFileUrl | Single line of text |
| CreatedBy | Single line of text |
| CreatedDate | Date and time |
| LastUsedDate | Date and time |
| UseCount | Number |
| AgentPlatformID | Single line of text |

**CopilotInactiveAgents** — rewritten on every `ExportAdoptionMetrics` run. One `Summary` row plus one row per agent not used in `AGENT_INACTIVE_DAYS` (default 60) or more days. Agents never used are measured from `CreatedDate`.

| Column | Type |
|--------|------|
| Title | Single line of text (built-in — `Summary` or the agent name) |
| RowType | Single line of text (`Summary` or `InactiveAgent`) |
| AgentName | Single line of text |
| SiteUrl | Single line of text |
| CreatedDate | Date and time |
| LastUsedDate | Date and time |
| UseCount | Number |
| DaysInactive | Number |
| TotalAgents | Number (Summary row) |
| InactiveCount | Number (Summary row) |
| ThresholdDays | Number (Summary row) |
| RunDate | Date and time (Summary row) |

> Agent usage is read from `TargetAgentName` / `TargetPlatformAgentId` on Copilot interaction events. Registry rows are matched to usage by `AgentPlatformID` first (filled in automatically on the first match), then by agent name (case-insensitive; site-qualified if several rows share a name). Usage that matches no registry row (for example built-in or site-default agents) is listed in the function log under "Usage not matched to a registry row". `UseCount` and `LastUsedDate` never decrease. They reflect usage seen by this pipeline, so agents used before it started may show as unused until the optional rebuild (step 9) is run.

### 8. Add Function App Environment Variables

Portal → Function App → **Settings → Environment variables** → + Add each:

| Name | Value |
|------|-------|
| `SHAREPOINT_SITE_URL` | `https://contoso.sharepoint.com/sites/CopilotReporting` |
| `SHAREPOINT_DAILY_LIST` | `CopilotDailyMetrics` |
| `SHAREPOINT_APP_LIST` | `CopilotAppMetrics` |
| `SHAREPOINT_WEEKLY_LIST` | `CopilotWeeklyMetrics` |
| `SHAREPOINT_WEEKLY_APP_LIST` | `CopilotWeeklyAppMetrics` |
| `SHAREPOINT_AGENT_LIST` | `SharePointCopilotAgentRegistry` |
| `SHAREPOINT_INACTIVE_AGENT_LIST` | `CopilotInactiveAgents` |
| `AGENT_INACTIVE_DAYS` | `60` (days without use before an agent is listed as inactive) |
| `AGENT_USAGE_REBUILD_DAYS` | `0` (optional; set to e.g. `90` for a one-time usage rebuild, then reset to `0`) |
| `METRICS_LOOKBACK_DAYS` | `7` (set to a larger number for initial backfill) |
| `METRICS_EXPORT_SCHEDULE` | `0 0 */4 * * *` (every 4 hours; adjust as needed) |

Click **Apply → Confirm** to restart the app.

### 9. Seed the SharePoint Lists

Trigger the initial export manually. Portal → **ExportAdoptionMetrics** → **Code + Test** → **Test/Run** → Run.

For a historical backfill, first temporarily set `METRICS_LOOKBACK_DAYS` to cover your full data range (e.g. `90`), run once, then reset to `7`.

**Agent registry (`SharePointCopilotAgentRegistry`):** Run `PullSharePointAgents` manually from Code + Test → Test/Run to trigger the initial `Audit.SharePoint` subscription and backfill any agents already created. If agents were created before deployment, temporarily set `TIME_WINDOW_MINUTES` to a large value (e.g. `500`) to cover the gap, then reset to `16`. Going forward, the registry updates automatically every 15 minutes — `PullSharePointAgents` is append-only and never overwrites existing entries (only `ExportAdoptionMetrics` updates the `LastUsedDate`, `UseCount` and `AgentPlatformID` columns).

**Agent usage history (optional):** `LastUsedDate`, `UseCount` and `CopilotInactiveAgents` are built from blobs processed after this feature is deployed. To include earlier history already in ADLS, temporarily set `AGENT_USAGE_REBUILD_DAYS` (e.g. `90`), run `ExportAdoptionMetrics` once, then set it back to `0`. The rebuild rescans every blob in that window, so keep it to a range the function timeout can handle.

**Complete baseline scan (recommended for existing tenants):** The audit-log approach above is limited by Unified Audit Log retention (typically 90–180 days) and only captures events from when the `Audit.SharePoint` subscription was active. To inventory **every** `.agent` file currently in SharePoint — regardless of when it was created — run the standalone baseline script instead:

```powershell
.\scripts\Backfill-AgentRegistry.ps1 `
  -TenantId "<your-tenant-id>" `
  -SharePointSiteUrl "https://contoso.sharepoint.com/sites/CopilotReporting"
```

This uses the Microsoft Search API to find `.agent` files tenant-wide and inserts any not already in the registry (deduplicated by file URL, safe to re-run). Requires the `SharePointCopilotAgentRegistry` list to already exist (Step 7). Run this once as your initial baseline — `PullSharePointAgents` handles all agent creations going forward.

### 10. Build the Canvas Power App (optional)

> The SharePoint lists work fully without the Power App — you can share list views directly or embed them as SharePoint list web parts. Build the Power App at any time later.

#### 10.1 Create and connect the app

1. Go to https://make.powerapps.com → **+ Create → Start with data → SharePoint**
2. Connect to your SharePoint site, pick `CopilotDailyMetrics` as the starting table
3. Delete the auto-generated screens — start from a blank screen
4. **Data** pane → **Add data** → SharePoint → same site → add all five lists:
   - `CopilotDailyMetrics`
   - `CopilotAppMetrics`
   - `CopilotWeeklyMetrics`
   - `CopilotWeeklyAppMetrics`
   - `SharePointCopilotAgentRegistry`
   - `CopilotInactiveAgents` (optional — summary and 60+ day inactive agents)
#### 10.2 Build Screen 1 — Daily Overview

- Insert → **Line chart** for DAU over time:
  - `Items`: `Sort(CopilotDailyMetrics, MetricDate, Ascending)`
  - `Series`: `"DAU"` · `XLabelColumn`: `"MetricDate"`
- Insert a second **Line chart** for TotalInteractions (same Items, `Series`: `"TotalInteractions"`)
- Insert a third **Line chart** for NewUsers
- Optional date filter — Insert → **Dropdown**:
  - `Items`: `["Last 7 days","Last 30 days","Last 90 days","All time"]`
  - Wrap each chart's Items: `Filter(Sort(CopilotDailyMetrics, MetricDate, Ascending), MetricDate >= DateAdd(Today(), If(Dropdown1.Selected.Value="Last 7 days",-7,If(Dropdown1.Selected.Value="Last 30 days",-30,-90)), Days))`

#### 10.3 Build Screen 2 — App Breakdown

- Insert → **Bar chart**:
  - `Items`: `AddColumns(GroupBy(CopilotAppMetrics,"AppHost","rows"),"TotalInteractions",Sum(rows,Interactions),"TotalUsers",Sum(rows,Users))`
  - `Series`: `"TotalInteractions"` · `Labels`: `"AppHost"`
- Insert a **Pie chart** for share by app (same Items, `Series`: `"TotalInteractions"`)

#### 10.4 Build Screen 3 — Weekly Summary

- Insert → **Gallery** (vertical):
  - `Items`: `Sort(CopilotWeeklyMetrics, WeekStart, Descending)`
  - Labels: WeekStart, WeekEnd, TotalInteractions, UniqueUsers, NewUsers, AppsUsed
- Insert → **Bar chart** for weekly app breakdown:
  - `Items`: `Filter(CopilotWeeklyAppMetrics, WeekStart = Gallery1.Selected.WeekStart)`
  - `Series`: `"Interactions"` · `Labels`: `"AppHost"`

#### 10.5 Build Screen 4 — Agent Registry

- Insert → **Gallery** (vertical):
  - `Items`: `Sort(SharePointCopilotAgentRegistry, CreatedDate, Descending)`
  - Labels: AgentName, SiteUrl, CreatedBy, CreatedDate
- This screen shows all Copilot agents created in SharePoint in chronological order

#### 10.6 Publish and embed

1. **File → Save → Publish**
2. SharePoint site → **Edit page** → **+** → search **Power Apps** web part → select your app → resize → **Republish**

### 11. Import the Azure Monitor Workbook (Log Analytics only, optional)

> Skip this step if you deployed with `deployLogAnalytics=false`.

For the near-real-time Log Analytics dashboard:

1. Azure Monitor → Workbooks → **+ New** → Edit
2. Click `</>` **Advanced Editor**
3. Paste contents of `workbook/copilot-adoption-workbook.json`
4. Click **Apply** → Save as "Copilot Adoption Dashboard" (Shared reports)
5. Set auto-refresh to 5 minutes

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Flex Consumption (FC1) | Serverless PowerShell 7.4 host with VNet integration + private endpoints; pay-per-execution with no always-on Premium plan cost |
| Managed Identity (no secrets) | NIST SP 800-53 compliance; `allowSharedKeyAccess: false` on all storage |
| `Sites.Selected` (not `Sites.ReadWrite.All`) | Least-privilege SharePoint access scoped to a single site |
| `parse_json(CopilotEventData).AppHost` | AppHost is nested inside `CopilotEventData` in raw audit events, not top-level |
| `Workload == "Copilot"` filter | More reliable than `Operation == "CopilotInteraction"` |
| `project-away CopilotEventData` in DCR | Prevents dynamic vs string type mismatch at ingestion |
| State blob for dedup | Eliminates overlap; each run resumes from where the last ended |
| 16-minute default window | Just over the 15-min interval; state tracking overrides after first run |
| 24-hour cap on lookback | Office 365 Management API rejects windows > 24 h; auto-capped |
| Incremental export design | `ExportAdoptionMetrics` only reads new blobs; SharePoint always receives a full historical snapshot from cache |
| Clear-all before rewrite | Eliminates duplicates unconditionally; title-based OData filters are unreliable on SharePoint REST |
| Agent tracking via `Audit.SharePoint` | `FileUploaded` + `SourceFileExtension == agent` is the only reliable signal for agent creation; `TargetAgentName` only appears in `Audit.General` once a user actually interacts with the agent |
| Shared retry helper (`SharedHelpers.ps1`) | Every Management API, storage and SharePoint call retries HTTP 408/429/5xx and network errors with exponential backoff (honouring `Retry-After`, 5 attempts); 400/401/403/404 fail immediately |
| Progress only advances on success | `PullCopilotAudit` keeps its processed-up-to timestamp unchanged when a storage or Log Analytics write fails, and fails the run so the window is re-read; storage blobs are named from a hash of the Management API content id with `If-None-Match: *`, so a re-read never duplicates blobs (Log Analytics can receive a re-sent event; events carry a unique `Id` for de-duplication in KQL) |
| Watermark for the agent pollers | `PullSharePointAgents` and `PullCopilotStudioAgents` keep a processed-up-to blob (`_state/lastProcessed-spagents.txt`, `_state/lastProcessed-studio.txt`) and re-read from it after a failed run; registry writes are de-duplicated. The window is never shorter than the configured window and never longer than 23 hours |
| Fail loudly, never assume "empty" | A failed read of state or of a SharePoint list stops the run instead of being treated as "nothing there", which would overwrite good state or create duplicate rows. `ExportAdoptionMetrics` leaves an unreadable blob unseen (retried next run) and does not finalize that date |

## Cloud Environment Support

| Environment | `cloudEnvironment` value | Management API | Graph Environment |
|------------|-------------------------|----------------|-------------------|
| Commercial | `Commercial` | manage.office.com | Global |
| GCC | `GCC` | manage-gcc.office.com | Global |
| GCC High | `GCCHigh` | manage.office365.us | USGov |
| DoD | `DoD` | manage.protection.apps.mil | USGovDoD |

Set `cloudEnvironment` during deployment. The template automatically configures API endpoints, storage suffixes, private DNS zones, and Monitor audience for the target cloud.

For GCC High or DoD:

```powershell
az cloud set --name AzureUSGovernment
az login
```

```bash
az deployment group create \
  --resource-group rg-copilot-adoption \
  --template-file infra/main.bicep \
  --parameters tenantId=<tenant-id> \
               cloudEnvironment=GCCHigh \
               auditStorageName=<name> \
               funcStorageName=<name>
```

```powershell
.\scripts\Post-Deploy.ps1 `
  -TenantId <tenant-id> `
  -FunctionAppPrincipalId <from-output> `
  -CloudEnvironment GCCHigh
```

Then grant SharePoint site access as described in [2b](#2b-grant-sharepoint-site-access-required-for-the-sharepoint-lists), using your `.sharepoint.us` site and the Graph endpoint for your cloud.

## Repo Structure

```
m365-copilot-adoption-metrics/
├── infra/
│   ├── main.bicep                   # All Azure infrastructure
│   ├── main.bicepparam              # Parameter defaults
│   └── azuredeploy.json             # Compiled ARM template (Deploy to Azure button)
├── function-app/
│   ├── host.json
│   ├── profile.ps1
│   ├── CloudEnvironment.ps1         # Cloud endpoint helper
│   ├── SharedHelpers.ps1            # HTTP retry/backoff and processed-up-to watermark helpers
│   ├── PullCopilotAudit/            # Timer — pulls Office 365 audit → ADLS + Log Analytics
│   │   ├── function.json            # schedule: every 15 min
│   │   └── run.ps1
│   ├── ExportAdoptionMetrics/       # Timer — aggregates ADLS data → SharePoint lists
│   │   ├── function.json            # schedule: configurable via METRICS_EXPORT_SCHEDULE
│   │   └── run.ps1
│   ├── PullSharePointAgents/        # Timer — tracks .agent file uploads → SharePointCopilotAgentRegistry
│   │   ├── function.json            # schedule: every 15 min
│   │   └── run.ps1
│   └── StartSubscription/           # One-time audit subscription activator
│       ├── function.json
│       └── run.ps1
├── powerbi/
│   ├── README.md                    # Power BI Desktop setup guide (Log Analytics connector)
│   ├── queries/
│   │   ├── CopilotAudit_LogAnalytics.pq
│   │   └── CopilotAudit_ADLS.pq
│   └── measures/
│       └── DAX_Measures.dax
├── scripts/
│   ├── Post-Deploy.ps1              # Grants ActivityFeed.Read (SharePoint access: see step 2b)
│   ├── Backfill-AgentRegistry.ps1   # One-time inventory of existing .agent files
│   ├── Invoke-LabFunction.ps1       # Manually trigger a function and follow its logs
│   └── Test-Repository.ps1
└── workbook/
    └── copilot-adoption-workbook.json
```


Automated collection and visualization of Microsoft 365 Copilot usage metrics from the Unified Audit Log. 

