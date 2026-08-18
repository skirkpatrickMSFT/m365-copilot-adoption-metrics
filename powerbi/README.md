# Power BI Dashboard — Copilot Audit

This directory contains Power Query (M) sources and DAX measures to build a Power BI
dashboard on top of the data collected by the Copilot Audit Function App.

---

## Data Sources

The Function App writes audit data to **two locations**:

| Source | Location | Access from Power BI |
|--------|----------|-----------------------|
| **Log Analytics** `CopilotAudit_CL` | Azure Monitor workspace | ✅ Direct — AAD auth, no gateway needed |
| **ADLS Gen2** `copilot-logs` container | Storage account | ⚠️ Requires on-premises data gateway (storage is private-endpoint only) |

**Recommended connection: Log Analytics.** The data is already structured, typed, and identical
to what the ADLS blobs contain. If you need the raw JSON archives for deeper analysis, see the
ADLS section below.

---

## Connection A — Log Analytics (Recommended)

### Prerequisites
- Power BI Desktop (latest)
- Azure AD account with **Log Analytics Reader** role on `law-copilot-adoption`
- Your **Subscription ID**, **Resource Group**, and **Log Analytics Workspace ID**
  (Overview blade of the workspace in the Azure portal)

### Step 1 — Get your workspace URL

Build the URL for your cloud:

| Cloud | URL Pattern |
|-------|-------------|
| Commercial | `https://ade.loganalytics.io/v0/subscriptions/{subId}/resourcegroups/{rg}/providers/microsoft.operationalinsights/workspaces/law-copilot-adoption` |
| GCC | `https://ade.loganalytics.io/v0/subscriptions/{subId}/resourcegroups/{rg}/providers/microsoft.operationalinsights/workspaces/law-copilot-adoption` |
| GCC High / DoD | `https://ade.loganalytics.azure.us/v0/subscriptions/{subId}/resourcegroups/{rg}/providers/microsoft.operationalinsights/workspaces/law-copilot-adoption` |

### Step 2 — Load the query in Power BI Desktop

1. Open **Power BI Desktop**.
2. Click **Get Data → Azure → Azure Monitor Logs** (or **More… → Azure → Azure Monitor Logs**).
3. Enter your workspace URL from Step 1 and sign in with your Azure AD account.
4. In the **Navigator**, select the workspace and click **Transform Data**.
5. In **Power Query Editor**, click **New Source → Blank Query**.
6. Open **Advanced Editor**, clear the default text, and paste the contents of
   [`queries/CopilotAudit_LogAnalytics.pq`](queries/CopilotAudit_LogAnalytics.pq).
7. Replace `YOUR_WORKSPACE_URL` with your URL from Step 1.
8. Click **Done**, then **Close & Apply**.

---

## Connection B — ADLS Gen2 (requires On-Premises Data Gateway)

The audit storage account (`auditStorageName` parameter in your Bicep deployment) uses
**private endpoints only** (`publicNetworkAccess: Disabled`). Power BI cloud services and
Power BI Desktop on a public internet machine cannot reach it without a gateway.

**To use this connection:**
1. Install [On-Premises Data Gateway](https://learn.microsoft.com/en-us/power-bi/connect-data/service-gateway-onprem)
   on a machine that has network access to the storage private endpoint.
2. Register the gateway in Power BI Service.
3. In Power BI Desktop, load [`queries/CopilotAudit_ADLS.pq`](queries/CopilotAudit_ADLS.pq)
   and replace `YOUR_AUDIT_STORAGE_NAME` with your storage account name.
4. After publishing, configure the dataset in Power BI Service to use the gateway.

---

## Step 3 — Add DAX Measures

After closing Power Query, add these calculated measures to your table:

1. Select your table in the **Data** pane.
2. Click **New Measure** on the ribbon.
3. Copy each measure from [`measures/DAX_Measures.dax`](measures/DAX_Measures.dax).

---

## Step 4 — Build the Report Pages

### Page 1: Adoption Overview

| Visual | Type | X-Axis / Legend | Values |
|--------|------|-----------------|--------|
| Total Interactions | Card | — | `[Total Interactions]` |
| Total Users | Card | — | `[Total Users]` |
| Daily Active Users | Line chart | `Date` | `[DAU]` |
| Weekly Active Users | Line chart | `Date` | `[WAU]` |

### Page 2: App Usage

| Visual | Type | Legend/Axis | Values |
|--------|------|-------------|--------|
| Usage by App | Donut chart | `AppHost` | `[Total Interactions]` |
| Users by App | Stacked bar | `AppHost` | `[Total Users]` |
| Cumulative Unique Users | Area chart | `Date` | `[Cumulative Users]` |

### Page 3: User Engagement

| Visual | Type | Axis | Values |
|--------|------|------|--------|
| Top 25 Power Users | Bar chart | `UserId` | `[Total Interactions]` (Top N filter = 25) |
| Engagement Distribution | Clustered bar | `[Engagement Bucket]` | `[Total Users]` |
| Activity by Hour of Day | Column chart | `[Hour of Day]` | `[Total Interactions]` |

### Page 4: Agent Usage (if agents are in use)

| Visual | Type | Axis | Values |
|--------|------|------|--------|
| Agent Interactions | Bar chart | `TargetAgentName` | `[Total Interactions]` |
| Users per Agent | Bar chart | `TargetAgentName` | `[Total Users]` |

---

## Step 5 — Publish and Schedule Refresh

1. In Power BI Desktop, click **Publish** → select your Power BI workspace.
2. In **Power BI Service**, go to your dataset → **Settings → Scheduled Refresh**.
3. Set refresh frequency to match your Function App timer trigger interval
   (default: every 15–16 minutes). The Log Analytics connector supports up to 8
   refreshes per day on shared capacity; use Premium capacity for sub-hourly refresh.
4. Under **Data Source Credentials**, re-authenticate with an account that has
   Log Analytics Reader on the workspace.

---

## Government Cloud Notes

For GCC High / DoD accounts in Power BI Desktop:
- **File → Options and Settings → Options → Security**
- Enable **Allow Microsoft Cloud for US Government** before signing in.
- Use the `.azure.us` workspace URL shown in Step 1.

---

## Schema Reference

The `CopilotAudit_CL` table (and ADLS JSON blobs) contain these fields:

| Column | Type | Description |
|--------|------|-------------|
| `TimeGenerated` | DateTime | Ingestion timestamp |
| `CreationTime` | DateTime | When the audit event was created |
| `Operation` | String | Audit operation name |
| `UserId` | String | UPN of the user |
| `Workload` | String | Always `Copilot` |
| `AppHost` | String | App where Copilot was used (e.g., `Word`, `Teams`) |
| `LicenseType` | String | License assigned to the user |
| `ConversationId` | String | Conversation thread identifier |
| `TargetAgentName` | String | Name of the agent used (if any) |
| `TargetPlatformAgentId` | String | Platform identifier of the agent |
| `DLPEvaluationDeferred` | Int | Whether DLP evaluation was deferred |
| `MemoryUpdated` | Boolean | Whether Copilot memory was updated |
| `CopilotLogVersion` | String | Log schema version |
| `ClientIP` | String | Client IP address |
| `OrganizationId` | String | Tenant/organization GUID |
| `RecordType` | Int | Office 365 audit record type |
| `Id` | String | Unique event GUID |
