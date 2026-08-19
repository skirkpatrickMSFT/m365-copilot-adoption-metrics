# Copilot Adoption Dashboard

Automated collection and visualization of Microsoft 365 Copilot usage metrics from the Unified Audit Log. The visualizations are built in SharePoint.

Two deployment paths are available:

- **Deploy to Azure button** â€” one-click ARM deployment for Azure infrastructure, then follow the steps below
- **Step-by-step guide** â€” see `Full_Implementation_Guide_No_Bicep.docx` for a complete walkthrough without Bicep

## Deployment Modes

The `deployLogAnalytics` parameter controls whether Log Analytics, Application Insights, and the AMPLS private endpoint are deployed. Both modes include the Function App, VNet, private endpoints, ADLS Gen2 audit storage, and the SharePoint Power App pipeline (Power App optional).  Full deployment will give you logs in log analytics and the visualizations in Azure Monitor as well as SharePoint. The SharePoint only path places the logs into storage then updates SharePoint with the metrics.

| Component | Full (default) | Storage + SharePoint only |
|-----------|:--------------:|:-------------------------:|
| `deployLogAnalytics` | `true` | `false` |
| ADLS Gen2 audit archive | âœ“ | âœ“ |
| SharePoint Power App dashboard | âœ“ | âœ“ |
| Log Analytics workspace | âœ“ | â€” |
| Data Collection Endpoint + Rule | âœ“ | â€” |
| Application Insights | âœ“ | â€” |
| AMPLS private endpoint | âœ“ | â€” |
| Azure Monitor Workbook | âœ“ | â€” |

Steps marked **(Log Analytics only)** below apply only to the full deployment.

## Architecture

```
Office 365 Management Activity API (manage.office.com)
        â”‚ every 15 min (PullCopilotAudit timer)
        â–¼
Azure Function App (Premium EP1, PowerShell 7.4)
  â€¢ Managed Identity auth â€” no secrets, no shared keys
  â€¢ Pagination, 500-event chunking, 429 throttle retry
  â€¢ State-tracked processing â€” no duplicate events
  â€¢ VNet integrated + private endpoints throughout
        â”‚
   â”Œâ”€â”€â”€â”€â”´â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
   â–¼                                   â–¼
ADLS Gen2                    [Log Analytics only]
(copilot-logs archive)        Log Analytics (CopilotAudit_CL)
   â”‚                               â”‚
   â–¼                               â–¼
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
| Azure Subscription | Contributor role, Elastic Premium VM quota â‰¥ 1 |
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

### 2. Grant API Permissions (post-deployment)

Run **locally** â€” Cloud Shell cannot acquire tokens for manage.office.com:

```powershell
.\scripts\Post-Deploy.ps1 `
  -TenantId <your-tenant-id> `
  -FunctionAppPrincipalId <from-deployment-output> `
  -CloudEnvironment Commercial `
  -SharePointSiteUrl https://contoso.sharepoint.com/sites/CopilotReporting
```

The `FunctionAppPrincipalId` is in the deployment output as `functionAppPrincipalId`.

This script:
- Grants `ActivityFeed.Read` to the Function App managed identity (for the Office 365 Audit API)
- Grants `Sites.Selected` + site-scoped write to the managed identity (for SharePoint export)
- Prints the exact SharePoint list column schema to create

A browser sign-in popup will appear â€” check your taskbar if it opens behind other windows.

### 3. Enable Auditing in Microsoft Purview

1. Go to https://purview.microsoft.com
2. Left nav â†’ **Audit** (under Solutions)
3. If not enabled, click **Start recording user and admin activity**

### 4. Deploy Function Code

The function app has `publicNetworkAccess: Disabled` with private endpoints â€” the portal editor is read-only. Use the Core Tools publish path, temporarily opening public access:

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

Function App â†’ **App files** â†’ select `profile.ps1` â†’ replace with:

```powershell
# Azure Functions profile - no Az modules needed
```

Save. This prevents unnecessary module load on every cold start.

### 6. Start the Audit Subscription (one-time)

The `StartSubscription` function activates the Management Activity API subscription automatically on its next timer tick (every 15 min). You can also trigger it manually:

Function App â†’ Functions â†’ **StartSubscription** â†’ **Code + Test** â†’ **Test/Run** â†’ Run

Check Application Insights logs for `"status":"enabled"`. Once confirmed, you can leave `StartSubscription` in place â€” it is idempotent and exits immediately if the subscription is already active.

### 7. Set Up SharePoint Lists

Create these four lists at your SharePoint site. Column names must match exactly.

**CopilotDailyMetrics**
| Column | Type |
|--------|------|
| Title | Single line of text (built-in â€” hide from view) |
| MetricDate | Date and time â†’ Date only |
| DAU | Number |
| TotalInteractions | Number |
| NewUsers | Number |

**CopilotAppMetrics**
| Column | Type |
|--------|------|
| Title | Single line of text (built-in â€” hide from view) |
| MetricDate | Date and time â†’ Date only |
| AppHost | Single line of text |
| Users | Number |
| Interactions | Number |

**CopilotWeeklyMetrics**
| Column | Type |
|--------|------|
| Title | Single line of text (built-in â€” hide from view) |
| WeekStart | Date and time â†’ Date only |
| WeekEnd | Date and time â†’ Date only |
| TotalInteractions | Number |
| UniqueUsers | Number |
| NewUsers | Number |
| AppsUsed | Single line of text |

**CopilotWeeklyAppMetrics**
| Column | Type |
|--------|------|
| Title | Single line of text (built-in â€” hide from view) |
| WeekStart | Date and time â†’ Date only |
| AppHost | Single line of text |
| Interactions | Number |
| Users | Number |

> To hide the Title column from view: column header â†’ **Column settings â†’ Hide in view**.

**SharePointCopilotAgentRegistry** â€” running log of every Copilot agent created, updated automatically by `PullSharePointAgents`.

| Column | Type |
|--------|------|
| Title | Single line of text (built-in â€” hide from view) |
| AgentName | Single line of text |
| SiteUrl | Single line of text |
| AgentFileUrl | Single line of text |
| CreatedBy | Single line of text |
| CreatedDate | Date and time |

### 8. Add Function App Environment Variables

Portal â†’ Function App â†’ **Settings â†’ Environment variables** â†’ + Add each:

| Name | Value |
|------|-------|
| `SHAREPOINT_SITE_URL` | `https://contoso.sharepoint.com/sites/CopilotReporting` |
| `SHAREPOINT_DAILY_LIST` | `CopilotDailyMetrics` |
| `SHAREPOINT_APP_LIST` | `CopilotAppMetrics` |
| `SHAREPOINT_WEEKLY_LIST` | `CopilotWeeklyMetrics` |
| `SHAREPOINT_WEEKLY_APP_LIST` | `CopilotWeeklyAppMetrics` |
| `SHAREPOINT_AGENT_LIST` | `SharePointCopilotAgentRegistry` |
| `METRICS_LOOKBACK_DAYS` | `7` (set to a larger number for initial backfill) |
| `METRICS_EXPORT_SCHEDULE` | `0 0 */4 * * *` (every 4 hours; adjust as needed) |

Click **Apply â†’ Confirm** to restart the app.

### 9. Seed the SharePoint Lists

Trigger the initial export manually. Portal â†’ **ExportAdoptionMetrics** â†’ **Code + Test** â†’ **Test/Run** â†’ Run.

For a historical backfill, first temporarily set `METRICS_LOOKBACK_DAYS` to cover your full data range (e.g. `90`), run once, then reset to `7`.

**Agent registry (`SharePointCopilotAgentRegistry`):** Run `PullSharePointAgents` manually from Code + Test â†’ Test/Run to trigger the initial `Audit.SharePoint` subscription and backfill any agents already created. If agents were created before deployment, temporarily set `TIME_WINDOW_MINUTES` to a large value (e.g. `500`) to cover the gap, then reset to `16`. Going forward, the registry updates automatically every 15 minutes â€” the function is append-only and will never overwrite existing entries.

### 10. Build the Canvas Power App (optional)

> The SharePoint lists work fully without the Power App â€” you can share list views directly or embed them as SharePoint list web parts. Build the Power App at any time later.

1. Go to https://make.powerapps.com â†’ **+ Create â†’ Start with data â†’ SharePoint**
2. Connect to your SharePoint site, pick `CopilotDailyMetrics`
3. Add all four lists as data sources (**Data** pane â†’ Add data)
4. Build screens using the M queries and DAX measures in the `powerbi/` folder as reference
5. **File â†’ Save â†’ Publish**

**Embed in SharePoint:** Edit page â†’ **+** â†’ search **Power Apps** web part â†’ select your app â†’ Republish.

### 11. Import the Azure Monitor Workbook (Log Analytics only, optional)

> Skip this step if you deployed with `deployLogAnalytics=false`.

For the near-real-time Log Analytics dashboard:

1. Azure Monitor â†’ Workbooks â†’ **+ New** â†’ Edit
2. Click `</>` **Advanced Editor**
3. Paste contents of `workbook/copilot-adoption-workbook.json`
4. Click **Apply** â†’ Save as "Copilot Adoption Dashboard" (Shared reports)
5. Set auto-refresh to 5 minutes

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Premium EP1 (not Consumption/Flex) | Only plan supporting VNet integration + private endpoints for PowerShell functions |
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
  -CloudEnvironment GCCHigh `
  -SharePointSiteUrl https://contoso.sharepoint.us/sites/CopilotReporting
```

## Repo Structure

```
m365-copilot-adoption-metrics/
â”œâ”€â”€ infra/
â”‚   â”œâ”€â”€ main.bicep                   # All Azure infrastructure
â”‚   â”œâ”€â”€ main.bicepparam              # Parameter defaults
â”‚   â””â”€â”€ azuredeploy.json             # Compiled ARM template (Deploy to Azure button)
â”œâ”€â”€ function-app/
â”‚   â”œâ”€â”€ host.json
â”‚   â”œâ”€â”€ profile.ps1
â”‚   â”œâ”€â”€ CloudEnvironment.ps1         # Cloud endpoint helper
â”‚   â”œâ”€â”€ PullCopilotAudit/            # Timer â€” pulls Office 365 audit â†’ ADLS + Log Analytics
â”‚   â”‚   â”œâ”€â”€ function.json            # schedule: every 15 min
â”‚   â”‚   â””â”€â”€ run.ps1
â”‚   â”œâ”€â”€ ExportAdoptionMetrics/       # Timer â€” aggregates ADLS data â†’ SharePoint lists
â”‚   â”‚   â”œâ”€â”€ function.json            # schedule: configurable via METRICS_EXPORT_SCHEDULE
â”‚   â”‚   â””â”€â”€ run.ps1
â”‚   â”œâ”€â”€ PullSharePointAgents/        # Timer â€” tracks .agent file uploads â†’ SharePointCopilotAgentRegistry
â”‚   â”‚   â”œâ”€â”€ function.json            # schedule: every 15 min
â”‚   â”‚   â””â”€â”€ run.ps1
â”‚   â””â”€â”€ StartSubscription/           # One-time audit subscription activator
â”‚       â”œâ”€â”€ function.json
â”‚       â””â”€â”€ run.ps1
â”œâ”€â”€ powerbi/
â”‚   â”œâ”€â”€ README.md                    # Power BI Desktop setup guide (Log Analytics connector)
â”‚   â”œâ”€â”€ queries/
â”‚   â”‚   â”œâ”€â”€ CopilotAudit_LogAnalytics.pq
â”‚   â”‚   â””â”€â”€ CopilotAudit_ADLS.pq
â”‚   â””â”€â”€ measures/
â”‚       â””â”€â”€ DAX_Measures.dax
â”œâ”€â”€ scripts/
â”‚   â”œâ”€â”€ Post-Deploy.ps1              # Grants ActivityFeed.Read + SharePoint Sites.Selected
â”‚   â””â”€â”€ Test-Repository.ps1
â””â”€â”€ workbook/
    â””â”€â”€ copilot-adoption-workbook.json
```
