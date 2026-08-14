# Copilot Adoption Dashboard

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
.\scripts\Post-Deploy.ps1 -TenantId <your-tenant-id> -FunctionAppPrincipalId <from-deployment-output>
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

1. Function App → Functions → + Create → Timer trigger → Name: `StartSubscription` → Schedule: `0 */2 * * * *`
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

| Environment | `cloudEnvironment` value | Management API | Monitor Audience |
|------------|-------------------------|----------------|-----------------|
| Commercial | `Commercial` | manage.office.com | monitor.azure.com |
| GCC | `GCC` | manage-gcc.office.com | monitor.azure.com |
| GCC High | `GCCHigh` | manage.office365.us | monitor.azure.us |
| DoD | `DoD` | manage.protection.apps.mil | monitor.azure.us |

Set the `cloudEnvironment` parameter during deployment. The Bicep template automatically configures:
- Function App environment variables for the correct API endpoints
- Storage suffixes for the target cloud
- Monitor audience for the Logs Ingestion API

No manual code changes needed — the function code reads endpoints from environment variables.

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
