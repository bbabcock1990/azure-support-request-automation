# MSX Ingestion Runbook (Copilot executes this)

You are the Microsoft account-team assistant. A customer opened Azure support
requests with `Create-AzureSupportRequests.ps1` and sent the hand-off. An
**ingestion plan JSON** (`ingestion-plan-*.json`) has already been built from it.
Your job: create the MSX records the plan describes, using the **msx-mcp** tools,
**confirming every write** with the user.

> Hard rules
> - **Never set ACR** (`msp_monthlyuse`). The account team sets consumption separately.
> - **Never fabricate** figures, names, or IDs. Everything comes from the plan or a live lookup.
> - **One support request → exactly one milestone.** Write the exact SR number into the
>   milestone Risk/Blocker details (`msp_milestonecomments`) so it is isolated.
> - Every `dataverse_write` / `uat_request` write **must** go through its confirmation prompt.

## 0. Pre-flight
1. `msx_auth_status` — confirm Dataverse is connected. If not, tell the user to run `msx_login`.
2. Read the plan JSON path you were given. It has: `customer`, `subscriptions`,
   `regions`, `opportunity`, and `milestones[]` (each with optional `uat`).

## 1. Opportunity (create once, or attach)
- If `opportunity.action == "attach"`: use `opportunity.opportunityId` for all milestones.
- If `opportunity.action == "create"`:
  1. Resolve the account: `dataverse_query(entity_set="accounts",
     filter="contains(name,'<customer>')", select="accountid,name")`.
     The `customer` value is derived from the customer's own contact email
     domain (e.g. `contoso.com` → "Contoso"), so it should match the company
     name closely. Pick the correct account with the user if ambiguous.
  2. Create the opportunity via `dataverse_write(entity_set="opportunities",
     operation="create", primary_key_field="opportunityid")` with at least:
     `name` (= `opportunity.name`), `parentaccountid@odata.bind` → `/accounts(<id>)`,
     `msp_eststartdate` (= `opportunity.estStartDate`; **required** or milestones fail).
  3. Keep the new `opportunityid` (GUID) for the milestones.

## 2. Milestones (one per `milestones[]` entry)
For each milestone `m`:
1. **Resolve the workload GUID** from the deployment/service context:
   `dataverse_query(entity_set="msp_workloads", filter="contains(msp_name,'<keyword>')",
   select="msp_workloadid,msp_name", top=20)`. Pick the exact match with the user.
   Bind with the **case-sensitive** `msp_WorkloadlkId@odata.bind` → `/msp_workloads(<guid>)`.
2. **Create the milestone** — `dataverse_write(entity_set="msp_engagementmilestones",
   operation="create", primary_key_field="msp_engagementmilestoneid")`:
   ```
   msp_name                     = m.name
   msp_milestonedate            = m.milestoneDate
   msp_milestonecategory        = m.categoryCode          # int
   msp_milestonestatus          = m.statusCode            # 861980002 Blocked
   msp_milestonestatusreason    = m.statusReasonCode      # int
   msp_helpneeded               = m.helpNeededCode        # int (required for Blocked)
   msp_forecastcomments         = m.forecastComments      # visible "Milestone Comments"
   msp_milestonecomments        = m.riskBlockerComments   # Risk/Blocker — carries the SR#
   msp_OpportunityId@odata.bind = /opportunities(<opp-guid>)
   msp_WorkloadlkId@odata.bind  = /msp_workloads(<workload-guid>)
   # capacity milestones only (m.uat present):
   msp_milestonepreferredazureregion = <region OptionSet int for m.preferredRegion>
   msp_milestoneazurecapacitytype    = "<STRING code>"    # STRING, not int (multi-select trap)
   # DO NOT set msp_monthlyuse (ACR).
   ```
   Region + capacity-type codes: use the `quota`/`msx-write` skill catalogs
   (`references/regions.json`, `references/optionsets.json`). Confirm the mapping with the user.
3. **Auto-join the milestone team** — add the current user (UserId
   `11111111-1111-1111-1111-111111111111`) via `AddUserToRecordTeam`, team template
   `316e4735-9e83-eb11-a812-0022481e1be0` (see create-milestone skill Step 7).
4. Fetch the milestone's **MSX number** (`7-XXXXXXXXX`) for the UAT — read it back with
   `dataverse_query` on the new record (`msp_name`, the auto-number field) or from the
   create response.

## 3. Non-AI UATs (only for milestones with `m.uat`)
`submit_non_ai` pulls account, TPID, opportunity, region, and EOU **from the milestone**,
so file it against the milestone you just created:
```
uat_request(
  mode="submit_non_ai",
  milestone_id       = "<the 7-XXXXXXXXX number>",
  subscription_id    = m.uat.subscription_id,
  support_request_ids= m.uat.support_request_ids,     # 16-digit
  workload_environment = m.uat.workload_environment,  # Prod / Dev / Test
  regional_zonal     = m.uat.regional_zonal,          # "Regional" / "3 Zones" / "AZ1"
  sku                = <m.uat.skus[n].sku>,            # one UAT per SKU slot
  uom                = "Cores",
  quantity           = <m.uat.skus[n].quantity>,
  customer_scenario  = m.uat.customer_scenario,
  customer_impact    = m.uat.customer_impact
)
```
- If a milestone lists **more than 3 SKUs** (see `m.uat.note`), file the extra SKUs as an
  additional Non-AI UAT (or use `replay` with SKU_1..3 slots). Never drop SKUs silently.
- Technical milestones (no `m.uat`) get **no UAT** — milestone only.
- Accept the elicitation prompt to file each UAT.

## 4. Wrap up
- After each UAT, add a short forecast comment to the milestone/opportunity noting what was
  filed (SR# + UAT action ID). **No ACR.**
- Summarize to the user: opportunity link, each milestone link
  (`open_msx_record type=msp_engagementmilestone`), and the UAT action IDs.
