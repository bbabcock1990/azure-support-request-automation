# Azure Support Request (SR) automation

A common complaint from large Azure customers is having to open a separate support
ticket for
everything (quota, spot, zonal whitelisting, allocation blocks, ...). This tool
turns that into **one file to fill out + one command to run**.

The whole tool is really just **two files**: the settings file you edit and the
engine that reads it. The engine holds **no customer-specific values** — every
target quota, zone, and VM family comes from your settings file, so the same
engine works for any customer, subscription, or use case. The only thing built
into the engine is a generic Azure lookup (which Azure service/classification each
request type maps to), which is identical for everyone.

## Folder layout

The tool is split by audience — **customers** who open the support requests, and the
**Microsoft account team** who turn the hand-off into MSX records:

```
azure-support-srs\
├─ README.md            <- this guide (covers both sides)
├─ customer\            <- give this folder to the customer
│  ├─ azure-support-settings.txt        (the only file the customer edits)
│  ├─ Create-AzureSupportRequests.ps1   (the engine)
│  └─ run-azure-support-requests.cmd    (double-click to run)
├─ account-team\        <- Microsoft account team / CSAM only
│  ├─ Ingest-SupportEmail.ps1           (builds the dry-run MSX plan)
│  ├─ Ingest-DropUI.ps1 / .cmd          (drag-and-drop window)
│  ├─ INGEST-RUNBOOK.md                 (procedure Copilot follows)
│  └─ launchers\                        (auto-created; safe to clear out)
└─ samples\             <- example hand-off + plan for testing the UI
```

> Customers only need the **`customer\`** folder. Everything in **`account-team\`**
> is internal to Microsoft and requires the `msx-mcp` tooling.

### `customer\` — what the customer runs

| File | Who edits it | Purpose |
|------|--------------|---------|
| `azure-support-settings.txt` | **You (customer)** | The only file you edit. Plain-text `Key: value` contact info + one block per environment listing the needs and their target numbers. |
| `Create-AzureSupportRequests.ps1` | Rarely | The engine. Reads your settings, delta-checks quotas, and opens the SRs. Contains only the generic Azure service/classification catalog (no customer values). |
| `run-azure-support-requests.cmd` | — | Convenience wrapper — double-click / run to launch the engine against the settings file. |
| `azure-support-results-*.json` | — | Structured results (incl. created ticket IDs) written into `customer\` on every run. |
| `azure-support-results-*.email.txt` | — | Escalation-ready email (per-SR detail for a Microsoft CSAM / account team), written on every run. Send this to your account team. |
| `azure-support-log-*.log` | — | Full timestamped run log written on every run. |

### `account-team\` — Microsoft account team only

| File | Purpose |
|------|---------|
| `Ingest-SupportEmail.ps1` | Reads a hand-off file and builds a dry-run MSX **ingestion plan** (1 opportunity + 1 Blocked milestone per SR + a Non-AI UAT per capacity SR). Writes nothing to MSX. |
| `Ingest-DropUI.ps1` / `Ingest-DropUI.cmd` | Drag-and-drop window: drop the hand-off file, it builds the plan and offers to launch an interactive Copilot session that creates the milestones/UATs (with a confirmation prompt per write). Double-click the `.cmd`. |
| `INGEST-RUNBOOK.md` | The step-by-step procedure the launched Copilot session follows to create the opportunity, milestones, and UATs via the msx-mcp tools. |
| `launchers\` | Auto-created. Holds the tiny generated `_run-ingest-*.cmd` launchers the drop UI writes to start the interactive Copilot session. Safe to clear out. |

> **Advanced / override:** the built-in Azure catalog can be overridden without
> touching the engine — drop a `azure-support-catalog.json` next to
> `Create-AzureSupportRequests.ps1` (or pass `-CatalogFile`) and it will be used
> instead of the built-in copy.

## How it works

1. In `azure-support-settings.txt`, for each **environment** (a subscription +
   region) list the needs you want and their target numbers — e.g.
   `computeQuota: standardDSv5Family=2500`. Needs that take no numbers (like
   `haPostgres`) just go on a `Needs:` line.
   Prefer not to edit a file? Run with `-Interactive` and answer a few questions
   instead (see below).
2. Run the tool **once**. For each **quota** need it first runs a live
   **delta check** (`az vm list-usage`) against the subscription, compares the
   current limit to **the target you specified**, and **only requests the
   shortfall** — VM families already at/above target are dropped (and logged), and
   if every target on an SR is already met, that whole SR is skipped. It then
   opens **one SR per remaining need** across every enabled environment, in a
   single pass.
3. By default the console shows a **clean, friendly summary** (numbered steps +
   a final results block + a short escalation list). Add `-Verbose` to stream
   the full per-step detail (service/classification resolution, delta math, exact
   payloads). Either way, the **full detail is always written** to a
   `azure-support-log-*.log` file, and structured results (including created support
   ticket IDs and anything skipped) to a `azure-support-results-*.json` file, with an
   **escalation-ready** `azure-support-results-*.email.txt` alongside.

You never need to know Azure service names or problem-classification names — the
built-in catalog handles that.

## Handing off to the Microsoft account team (MSX ingestion)

There are two sides to this workflow:

- **Customer side** (`customer\Create-AzureSupportRequests.ps1`): opens the Azure support
  requests and produces the hand-off (`azure-support-results-*.json` +
  `*.email.txt`). Send both files to your Microsoft account team.
- **Account-team side** (`account-team\Ingest-DropUI.cmd` / `Ingest-SupportEmail.ps1`): turns the
  hand-off into MSX records — **one opportunity, one Blocked engagement milestone per
  support request** (with the exact SR number recorded for traceability), and a
  **Non-AI Capacity UAT** for each capacity request. Technical requests (e.g.
  PostgreSQL HA) get a milestone but no UAT. **ACR/consumption is never written.**

### How the account team runs it

1. **Double-click `account-team\Ingest-DropUI.cmd`** and drop the customer's
   `azure-support-results-*.json` (or `*.email.txt`) onto the window.
2. The tool builds a **dry-run ingestion plan** (`ingestion-plan-*.json`), shows it,
   and opens it for review. **Nothing is written to MSX yet.**
3. Choose **Yes** to launch an interactive Copilot session (`copilot -i`). Copilot
   follows `INGEST-RUNBOOK.md` and creates the opportunity, milestones, and UATs via
   the **msx-mcp** tools — **prompting you to confirm every single write.**

> The msx-mcp write tools and their confirmation prompts only exist inside the Copilot
> agent runtime, so the drop window itself never writes to MSX — it launches Copilot to
> do the writes under your confirmation. You can also run the planner directly:
> `account-team\Ingest-SupportEmail.ps1 -InputFile <hand-off>` (add `-OpportunityId <guid>` to attach
> to an existing opportunity instead of creating a new one).

**Prerequisites (account-team side):** the `msx-mcp` MCP server (corporate VPN + MSX
auth) and the GitHub Copilot CLI (`copilot`) on PATH.



Every quota need you list is **delta-checked** before a ticket is opened:

- The engine reads the subscription's **current** per-family limits with
  `az vm list-usage`, compares each to **the target you put in the settings file**,
  and only asks for the difference. Families already at/above target are skipped
  (and logged); if an entire SR is already satisfied, it's skipped.
- VM family matching is tolerant of spacing/underscores, so you can write the
  normal payload name (e.g. `standardNCASv3_T4Family`) and it still matches the
  usage row (`Standard NCASv3_T4 Family`).
- The delta check is **on by default**. Pass `-SkipDeltaCheck` to request the full
  target regardless of current limits.
- **Zone-access** requests are exempt from the vCPU delta check (per-zone
  whitelisting isn't exposed by the usage API). Instead they get their own
  **restriction check** — see *Zonal (Availability Zone) access* below.

> **Safe by default (won't ask for what you already have).** The engine validates
> **both** existing quota **and** existing zonal access before it opens anything, so
> re-running it is safe and idempotent — a target already satisfied is skipped, and
> an entire SR whose targets are all met is skipped.
>
> **Fail-safe, not fail-silent.** If a check can't read its data (e.g. you lack read
> access, or an API call fails), the engine **includes** that request rather than
> silently dropping it: a current quota it can't read is kept (with a `WARN`), and
> missing restriction data means all listed zones are submitted. Better to ask than
> to miss a real need — but it means the checks only *save* you tickets when the
> read permissions below are in place.

## Zonal (Availability Zone) access

`zonalWhitelisting` reproduces the portal's **"Zone access"** submission exactly:

- The engine queries `az vm list-skus --all` for the region and, like the portal
  picker, **only requests the SKU × zone combinations that are actually restricted**
  for the subscription (`NotAvailableForSubscription`). Zones a family is already
  available in are skipped (and logged). If nothing is restricted, the SR is skipped.
  > `--all` is required: without it the CLI hides subscription-restricted SKUs, which
  > are exactly the ones a zone-access request is for.
- Pass `-SkipRestrictionCheck` to submit every zone you listed regardless.
- The payload matches the portal: `Type:Zonal`, `DeploymentStack:ARM`, region in
  UPPERCASE, and both the **logical** zone (`Zone N`) and the subscription-specific
  **physical** AZ (`Physical AZ0N`). The logical→physical map is read live per
  subscription (it is not always 1:1).
- Every quota/zonal ticket's description ends with a **Payload Details** section
  listing the requested new limit (vCPUs) grouped **per Availability Zone**, plus the
  raw `quota-change-requests` array that was submitted — so the exact ask is visible
  right in the portal's Issue details.

## Easiest path: the interactive wizard

If filling out JSON is confusing, let the wizard build it for you:
```powershell
.\Create-AzureSupportRequests.ps1 -Interactive
```

It asks plain-language questions (your name/email, customer, subscription ID,
region, which needs, and — for quota/zonal needs — "Add another VM family / SKU?"
with the new limit, plus which zones), writes the settings file, then offers to
open the SRs immediately. Combine with `-WhatIf` to preview first:

```powershell
.\Create-AzureSupportRequests.ps1 -Interactive -WhatIf
```

## Supported needs (Compute scope, to start)

| Flag | Opens an SR for | Ticket type |
|------|-----------------|-------------|
| `computeQuota` | Dedicated vCPU / cores quota increase (**multiple VM families/SKUs in one SR**) | Quota |
| `spotQuota` | Spot / low-priority vCPU quota increase | Quota |
| `gpuQuota` | GPU vCPU / cores quota increase (e.g. NCasv3_T4) | Quota |
| `zonalWhitelisting` | Availability Zone access / zonal whitelisting for zones 1/2/3 | Quota (**"Zone access"** request under *Service and subscription limits (quotas)* → *Compute-VM (cores-vCPUs)*) |
| `haPostgres` | Enable High Availability on Azure Database for PostgreSQL flexible server | Technical |
| `allocationBlock` | Allocation failure investigation & mitigation | Technical |

> **Note:** `zonalWhitelisting` is filed as a **quota "Zone access"** request (not a
> technical VM ticket). The engine builds one quota entry per **SKU × zone**.

## Settings file format

Settings live in a simple **text file** (`azure-support-settings.txt`) — no
braces, quotes, or commas to get wrong. You write `Key: value` lines, organised
into three sections: **(1) who to contact**, **(2) which subscription/region**,
and **(3) what you need**. Each **quota need** is its own line listing the VM
families and the target vCPU limit; needs that take no numbers go on the `Needs:`
line. Delete any need line you don't want.

```text
# --- SECTION 1:  WHO TO CONTACT ---
Contact name:    Jane Doe
Contact email:   jane@contoso.com
Country:         USA
Contact method:  email                # email or phone
Language:        en-US
Time zone:       Central Standard Time
Severity:        moderate             # minimal, moderate, or critical

# --- SECTION 2:  WHICH SUBSCRIPTION & REGION ---
Environment:     Prod
Subscription:    00000000-0000-0000-0000-000000000000
Region:          East US
Deployment:      Prod
Business impact: This is holding up a customer deployment and impacting revenue.
# Customer name is auto-derived from your Contact email domain.
# Uncomment to override:
# Customer:      Contoso

# --- SECTION 3:  WHAT YOU NEED (one support request per line) ---
computeQuota:      standardESv5Family=2500, standardDSv5Family=2500, standardEDSv5Family=2500, standardDDSv5Family=2500
spotQuota:         lowPriorityCores=5000
gpuQuota:          standardNCASv3_T4Family=256
# Zonal access: just list families + a Zones: line (vCPUs inherited from above)
zonalWhitelisting: standardESv5Family, standardDSv5Family, standardEDSv5Family, standardDDSv5Family, standardNCASv3_T4Family
Zones:             1, 2, 3
# Needs with no numbers:
Needs:             haPostgres
```

You can add an inline `# comment` after any value, and attach a note to a specific
request with `<need> notes: <text>` (e.g. `computeQuota notes: ...`). To open
tickets for a **second** subscription/region, add another `Environment:` block
below the first (a ready-to-copy template is at the bottom of the settings file).
The engine has no built-in numbers, so whatever you type here is exactly what's
requested (minus anything the delta check finds is already satisfied).

### Fields

| Line | Meaning |
|------|---------|
| `Contact name:` / `Contact email:` | Who Support contacts (put these once, at the top). The **Customer name is auto-derived from the Contact email domain** (e.g. `jane@contoso.com` → "Contoso") unless you set an explicit `Customer:` line. |
| `Country:` / `Contact method:` / `Language:` / `Time zone:` | Optional contact details (sensible defaults applied). |
| `Severity:` | Optional default severity for every ticket (`minimal`/`moderate`/`critical`). |
| `Environment:` | Starts a new block; the text after it is just a label for your logs. |
| `Subscription:` | The customer's subscription ID (GUID). |
| `Region:` | e.g. `Central US`. |
| `Customer:` | **Optional.** Shown in the ticket titles. Omit it and it's derived from your Contact email domain; set it only to override (e.g. a lab using a `microsoft.com` email that represents another company). |
| `Deployment:` | Optional label shown in the ticket titles. |
| `Business impact:` | Free text added to the ticket description. |
| `<quotaNeed>:` | A quota need + its targets, e.g. `computeQuota: standardDSv5Family=2500, standardDDSv5Family=2000`. `vmFamily` is the Azure family name; the limit is the total vCPUs you want. |
| `Zones:` | Comma list of zones for `zonalWhitelisting` (e.g. `1, 2, 3`). |
| `Needs:` | Comma list of needs that take **no** numbers (e.g. `haPostgres`, `allocationBlock`). |

> Prefer to be prompted instead of editing the file? Run `-Interactive` and the
> wizard asks for each need/limit/zone and writes the file for you.

## Usage

> Run these from inside the **`customer\`** folder (that's where the engine, the
> settings file, and the `.cmd` wrapper live). e.g. `cd customer` first, or
> double-click `customer\run-azure-support-requests.cmd`.

Preview first (recommended) — resolves everything and shows what **would** be
created without opening any tickets:

```powershell
.\Create-AzureSupportRequests.ps1 -WhatIf
```

Just validate that every service/classification resolves:

```powershell
.\Create-AzureSupportRequests.ps1 -DiscoverOnly
```

Actually open the SRs:

```powershell
.\Create-AzureSupportRequests.ps1
```

### Smoke testing in a lab (`-TestMode`)

When you just want to confirm the tool can open a ticket end-to-end, add
`-TestMode`. Every SR it creates is clearly marked as a test so Support can close
it without investigating:

- Title is prefixed with `[TEST - PLEASE IGNORE AND CLOSE]`.
- Description starts with a bold "THIS IS A TEST SUPPORT REQUEST - NO ACTION
  REQUIRED" banner explaining it came from a lab smoke test.
- Severity is forced to `minimal` so nobody gets paged.

```powershell
# Preview the test ticket first
.\Create-AzureSupportRequests.ps1 -TestMode -WhatIf

# Actually open the (clearly-marked) test ticket in your lab subscription
.\Create-AzureSupportRequests.ps1 -TestMode
```

Or double-click / run the wrapper (append `-WhatIf` or `-Interactive` to it):

```cmd
run-azure-support-requests.cmd -Interactive
```

### Parameters

| Parameter | Purpose |
|-----------|---------|
| `-SettingsFile <path>` | Settings text file to use (default `.\azure-support-settings.txt`; a `.json` file is still accepted). |
| `-CatalogFile <path>` | Optional external catalog to override the built-in Azure catalog (default `.\azure-support-catalog.json` if present). |
| `-SkipDeltaCheck` | Skip the live `az vm list-usage` delta check; request the full target you specified regardless of current limits. |
| `-SkipRestrictionCheck` | Skip the zonal `az vm list-skus` restriction check; submit every zone you listed for `zonalWhitelisting` regardless of whether it's restricted. |
| `-Interactive` | Launch the setup wizard to build the settings file, then run. |
| `-TestMode` | Mark every SR as a test (title prefix + banner + `minimal` severity). |
| `-Verbose` | Stream the full per-step detail to the console (resolution, delta math, payloads). Without it the console shows a clean summary; the log file always has full detail. |
| `-WhatIf` | Resolve everything and show what **would** be created; submit nothing. |
| `-DiscoverOnly` | Verify every service/classification resolves; submit nothing. |
| `-ValidateSubscriptionAccess` | Also run `az account set` per ticket so missing access fails fast. |
| `-OutputFile <path>` | Override the results JSON path (default timestamped). |
| `-LogFile <path>` | Override the log path (default timestamped). |

> If you run **without** `-SettingsFile`, the engine prints the default settings-file
> path it's about to use and asks you to confirm before doing anything.

### Output files (written on every run)
- `azure-support-log-<timestamp>.log` — full timestamped run log (all detail,
  regardless of `-Verbose`). Override with `-LogFile <path>`.
- `azure-support-results-<timestamp>.json` — structured results including
  created support ticket IDs. Override with `-OutputFile <path>`.
- `azure-support-results-<timestamp>.email.txt` — an **escalation-ready email** you
  can hand to a Microsoft CSAM / account team to open a UAT or raise an escalation.
  It includes a header (prepared by, customer, cloud, subscription), a numbered
  summary, and a per-SR detail block (SR number, environment, subscription, region,
  category, request type, severity, business impact, and the exact requested new
  limits per VM family / Availability Zone).

## Prerequisites & required permissions

### Tooling
- **Azure CLI (`az`)** installed, and `az login` completed.
- You must be logged into the **tenant that owns the subscription(s)** in **Azure
  Commercial** (`AzureCloud`). Azure US Government and other national clouds are not
  supported.
- **PowerShell** (Windows PowerShell 5.1 or PowerShell 7+).
- The Azure CLI `support` extension — the engine installs it automatically the first
  time it opens a ticket if it isn't already present.

### Azure permissions (RBAC)

The signed-in user (or service principal) needs two capabilities on **each
subscription** you target: permission to **open support requests**, and read access
so the **quota / zonal validation** can run.

| Capability | Built-in role that grants it | Underlying action(s) |
|------------|------------------------------|----------------------|
| **Open & manage support requests** (required to create the SR) | **Support Request Contributor** | `Microsoft.Support/*` |
| **Quota check** (`az vm list-usage`) | **Reader** | `Microsoft.Compute/locations/usages/read` |
| **Zonal restriction check** (`az vm list-skus --all`) | **Reader** | `Microsoft.Compute/skus/read`, `Microsoft.Compute/locations/*/read` |
| **Logical→physical AZ mapping** (per-sub zone map) | **Reader** | `Microsoft.Resources/subscriptions/locations/read` |
| **Service / classification lookup** | any authenticated user | `Microsoft.Support/services/read`, `Microsoft.Support/services/problemClassifications/read` |

**Simplest setup:** grant the user **Reader + Support Request Contributor** on the
subscription. **Contributor** or **Owner** already include everything above, so if the
customer has either of those, no extra role is needed.

- If the user has **Support Request Contributor but not Reader**, tickets still open,
  but the validation runs in fail-safe mode (it can't read current quota/restrictions,
  so it submits everything you listed — see *Safe by default* above).
- If the user has **Reader but not Support Request Contributor**, the checks run and
  `-WhatIf` previews work, but the actual `create` fails with an authorization error.

### Support plan

- **Quota** and **zone-access** requests (`computeQuota`, `spotQuota`, `gpuQuota`,
  `zonalWhitelisting`) do **not** require a paid support plan.
- **Technical** requests (`haPostgres`, `allocationBlock`) require an eligible
  **support plan** (Developer, Standard, Professional Direct, or a Unified/Premier
  contract) on the subscription; without one, Azure rejects the technical ticket.

### Quick permission self-check

```powershell
# Am I logged in, and to the right subscription?
az account show --output table

# Can I read quota (Reader)? Should list rows, not an auth error:
az vm list-usage --location "eastus" --output table

# Can I open support requests? Preview without creating anything:
.\Create-AzureSupportRequests.ps1 -WhatIf
```

## Adding a new need later (e.g. GPU quota, PostgreSQL HA, AOAI)

1. Add a block under `needs` in the `$EmbeddedCatalogJson` section near the top of
   `Create-AzureSupportRequests.ps1` (or in an external `azure-support-catalog.json`
   override) with its `serviceDisplayName`, `problemClassificationDisplayName`,
   title/summary templates, and `ticketType` (`technical` or `quota`). Quota needs
   also set `quotaChangeType` (`Dedicated`/`LowPriority`) and list `fields` (e.g.
   `quotas`, `zones`, `vmSkus`, `notes`).
2. Add the need's key to the `Needs:` line of an environment block in the settings file.

No other engine changes required.
