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
Azure Function App (Premium EP1, PowerShell 7.4)
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
SharePoint Lists ──▶ Canvas Power App Dashboard
(CopilotDailyMetrics,    (long-term adoption reporting)
 CopilotAppMetrics,
 CopilotWeeklyMetrics,
 CopilotWeeklyAppMetrics)
```

## Prerequisites

| Requirement | Details |
|------------|---------|
| Azure Subscription | Contributor role, Elastic Premium VM quota ≥ 1 |
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

Run **locally** — Cloud Shell cannot acquire tokens for manage.office.com:

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

A browser sign-in popup will appear — check your taskbar if it opens behind other windows.

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

This deploys all three functions: `PullCopilotAudit`, `ExportAdoptionMetrics`, and `StartSubscription`.

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

Create these four lists at your SharePoint site. Column names must match exactly.

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

### 8. Add Function App Environment Variables

Portal → Function App → **Settings → Environment variables** → + Add each:

| Name | Value |
|------|-------|
| `SHAREPOINT_SITE_URL` | `https://contoso.sharepoint.com/sites/CopilotReporting` |
| `SHAREPOINT_DAILY_LIST` | `CopilotDailyMetrics` |
| `SHAREPOINT_APP_LIST` | `CopilotAppMetrics` |
| `SHAREPOINT_WEEKLY_LIST` | `CopilotWeeklyMetrics` |
| `SHAREPOINT_WEEKLY_APP_LIST` | `CopilotWeeklyAppMetrics` |
| `METRICS_LOOKBACK_DAYS` | `7` (set to a larger number for initial backfill) |
| `METRICS_EXPORT_SCHEDULE` | `0 0 */4 * * *` (every 4 hours; adjust as needed) |

Click **Apply → Confirm** to restart the app.

### 9. Seed the SharePoint Lists

Trigger the initial export manually. Portal → **ExportAdoptionMetrics** → **Code + Test** → **Test/Run** → Run.

For a historical backfill, first temporarily set `METRICS_LOOKBACK_DAYS` to cover your full data range (e.g. `90`), run once, then reset to `7`.

### 10. Build the Canvas Power App

1. Go to https://make.powerapps.com → **+ Create → Start with data → SharePoint**
2. Connect to your SharePoint site, pick `CopilotDailyMetrics`
3. Add all four lists as data sources (**Data** pane → Add data)
4. Build screens using the M queries and DAX measures in the `powerbi/` folder as reference
5. **File → Save → Publish**

**Embed in SharePoint:** Edit page → **+** → search **Power Apps** web part → select your app → Republish.

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
| Delete-then-create (not upsert) | Avoids OData filter reliability issues; one bulk list read per export run |

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
├── infra/
│   ├── main.bicep                   # All Azure infrastructure
│   ├── main.bicepparam              # Parameter defaults
│   └── azuredeploy.json             # Compiled ARM template (Deploy to Azure button)
├── function-app/
│   ├── host.json
│   ├── profile.ps1
│   ├── CloudEnvironment.ps1         # Cloud endpoint helper
│   ├── PullCopilotAudit/            # Timer — pulls Office 365 audit → ADLS + Log Analytics
│   │   ├── function.json            # schedule: every 15 min
│   │   └── run.ps1
│   ├── ExportAdoptionMetrics/       # Timer — aggregates ADLS data → SharePoint lists
│   │   ├── function.json            # schedule: configurable via METRICS_EXPORT_SCHEDULE
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
│   ├── Post-Deploy.ps1              # Grants ActivityFeed.Read + SharePoint Sites.Selected
│   └── Test-Repository.ps1
└── workbook/
    └── copilot-adoption-workbook.json
```


Automated collection and visualization of Microsoft 365 Copilot usage metrics from the Unified Audit Log. 

There are 2 paths for deployment.

Follow the readme and Select the Deploy to Azure button below to deploy "The Easy Button" or deploy step-by-step with the .docx instructions above.

## Architecture

```
Office 365 Management Activity API (manage.office.com)
        │ every 15 min (timer trigger)
        ▼
Azure Function App (Premium EP1, PowerShell 7.4)
  • Managed Identity auth (no secrets)
  • Pagination, chunking (500/batch), 429 retry
  • State tracking (no duplicate processing)
  • VNet integrated + private endpoints
        │
   ┌────┴────┐
   ▼         ▼
ADLS Gen2   Log Analytics ──▶ Azure Monitor Workbook
(archive)   (CopilotAudit_CL)  (near-real-time dashboard)
```

## Prerequisites

| Requirement | Details |
|------------|---------|
| Azure Subscription | Contributor role, Elastic Premium VM quota ≥ 1 |
| Microsoft 365 | E5 or Copilot add-on with Unified Audit Log enabled |
| Copilot Licenses | Assigned to users who actively use Copilot |
| Local PowerShell | Microsoft.Graph module (for post-deployment permissions) |
| Admin Role | Global Admin or Security Admin |

## Deploy

### 1. Deploy Infrastructure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FskirkpatrickMSFT%2Fm365-copilot-adoption-metrics%2Fmain%2Finfra%2Fazuredeploy.json)

Or via CLI:

```bash
az group create --name rg-copilot-adoption --location <region>

az deployment group create \
  --resource-group rg-copilot-adoption \
  --template-file infra/main.bicep \
  --parameters tenantId=<your-tenant-id> \
               auditStorageName=<globally-unique-name> \
               funcStorageName=<globally-unique-name>
```

### 2. Grant API Permissions (post-deployment)

Run locally (NOT in Cloud Shell — it cannot get tokens for manage.office.com):

```powershell
.\scripts\Post-Deploy.ps1 -TenantId <your-tenant-id> -FunctionAppPrincipalId <from-deployment-output> -CloudEnvironment Commercial
```

The Function App principal ID is in the deployment output as `functionAppPrincipalId`.

### 3. Enable Auditing in Purview

1. Go to https://purview.microsoft.com
2. Left nav → Audit (under Solutions)
3. If auditing is not enabled, click "Start recording user and admin activity"

### 4. Deploy Function Code

**Option A — Portal (Premium plan supports in-portal editing):**

1. Function App → Functions → + Create → Timer trigger → Name: `PullCopilotAudit` → Schedule: `0 */15 * * * *`
2. Code + Test → paste contents of `function-app/PullCopilotAudit/run.ps1` → Save

**Option B — ZIP deploy:**

```bash
cd function-app
zip -r ../func-deploy.zip .
az functionapp deployment source config-zip \
  --resource-group rg-copilot-adoption \
  --name <func-app-name> \
  --src ../func-deploy.zip
```

### 5. Clear profile.ps1

Function App → App files → select `profile.ps1` → replace with:

```powershell
# Azure Functions profile - no Az modules needed
```

### 6. Start the Audit Subscription

Create a temporary timer function to activate the Management Activity API subscription:

1. Function App → Functions → + Create → Timer trigger → Name: `StartSubscription` → Schedule: `0 */15 * * * *`
2. Paste contents of `function-app/StartSubscription/run.ps1` → Save
3. Wait 2 minutes → check Application Insights logs for `"status":"enabled"`
4. Delete the `StartSubscription` function after confirmation

> This is a one-time activation. The portal Test/Run button won't work due to private endpoints — the timer trigger runs internally.

### 7. Import the Workbook

1. Azure Monitor → Workbooks → + New → Edit
2. Click the `</>` Advanced Editor button
3. Paste the contents of `workbook/copilot-adoption-workbook.json`
4. Click Apply → Save as "Copilot Adoption Dashboard" (Shared reports)
5. Set auto-refresh to 5 minutes

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Premium EP1 (not Consumption/Flex) | Only plan supporting VNet + PowerShell function discovery |
| Managed Identity (not secrets) | NIST SP 800-53 compliance; no shared key access |
| `parse_json(CopilotEventData).AppHost` | AppHost is nested inside CopilotEventData, not top-level |
| `Workload == "Copilot"` filter | More reliable than `Operation == "CopilotInteraction"` |
| `project-away CopilotEventData` in DCR | Prevents dynamic vs string type mismatch at ingestion |
| State blob for deduplication | Eliminates overlap; each run picks up where the last ended |
| 16-minute default window | Just over the 15-min interval; state tracking overrides after first run |

## Cloud Environment Support

The solution supports all Azure/M365 cloud environments via a single parameter:

| Environment | `cloudEnvironment` value | Management API | Microsoft Graph environment |
|------------|-------------------------|----------------|-----------------------------|
| Commercial | `Commercial` | manage.office.com | Global |
| GCC | `GCC` | manage-gcc.office.com | Global |
| GCC High | `GCCHigh` | manage.office365.us | USGov |
| DoD | `DoD` | manage.protection.apps.mil | USGovDoD |

Set the `cloudEnvironment` parameter during deployment. The Bicep template automatically configures:
- Function App environment variables for the correct API endpoints
- Storage suffixes and private DNS zones for the target cloud
- Monitor audience for the Logs Ingestion API
- NAT Gateway egress for the public Management Activity API

No manual code changes needed — the function code reads endpoints from environment variables.

The function scripts and deployment scripts use syntax supported by Windows PowerShell 5.1 and PowerShell 7. Azure Functions v4 hosts the function worker on PowerShell 7.4; PowerShell 5.1 compatibility applies to local parsing, validation, and deployment scripts.

For GCC High or DoD, select the Azure Government cloud before deployment:

```powershell
az cloud set --name AzureUSGovernment
az login
```

Pass the same `cloudEnvironment` value to the infrastructure deployment and `Post-Deploy.ps1`. The Deploy to Azure portal button targets commercial Azure; use the Azure CLI deployment path for GCC High and DoD.

### CLI deployment for GCC High:

```bash
az deployment group create \
  --resource-group rg-copilot-adoption \
  --template-file infra/main.bicep \
  --parameters tenantId=<your-tenant-id> \
               cloudEnvironment=GCCHigh \
               auditStorageName=<name> \
               funcStorageName=<name>
```

Then run the sovereign-cloud post-deployment step:

```powershell
.\scripts\Post-Deploy.ps1 `
  -TenantId <your-tenant-id> `
  -FunctionAppPrincipalId <from-deployment-output> `
  -CloudEnvironment GCCHigh
```

For DoD, use `cloudEnvironment=DoD` and `-CloudEnvironment DoD`.

## Repo Structure

```
copilot-adoption-dashboard/
├── infra/
│   ├── main.bicep              # All Azure infrastructure
│   ├── main.bicepparam         # Parameter defaults
│   └── azuredeploy.json        # Compiled ARM template (for Deploy button)
├── function-app/
│   ├── host.json               # Function App runtime config
│   ├── profile.ps1             # Empty profile (no Az modules)
│   ├── PullCopilotAudit/       # Main timer function (every 15 min)
│   │   ├── function.json
│   │   └── run.ps1
│   └── StartSubscription/      # One-time subscription activator
│       ├── function.json
│       └── run.ps1
├── workbook/
│   └── copilot-adoption-workbook.json
├── scripts/
│   └── Post-Deploy.ps1         # Grants ActivityFeed.Read permission
└── README.md
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| 0 functions loaded | Flex Consumption plan | Use Premium EP1 |
| Cloud Shell token error | MSI doesn't support manage.office.com audience | Use local PowerShell or Function App MI |
| Container name 400 error | Uppercase container name | Use lowercase only (copilot-logs) |
| AppHost always empty | Nested inside CopilotEventData | DCR transform extracts it via parse_json |
| DCR type mismatch error | CopilotEventData: dynamic vs string | Add project-away CopilotEventData to transform |
| Test/Run fails in portal | Private endpoint blocks inbound | Use timer trigger (runs internally) |
| No Elastic Premium quota | CDX/sandbox limitation | Request increase or use a production subscription |
| profile.ps1 Connect-AzAccount error | Default template references Az modules | Clear profile.ps1 contents |
