<#
.SYNOPSIS
    Turn an Azure Support Requests hand-off (produced by Create-AzureSupportRequests.ps1)
    into an MSX ingestion PLAN: one opportunity, one Blocked engagement milestone per
    support request, and a Non-AI Capacity UAT for each capacity request.

.DESCRIPTION
    This is the Microsoft account-team side of the workflow. The customer runs
    Create-AzureSupportRequests.ps1, opens the Azure support requests, and sends the
    generated results file. This script reads that file and builds a deterministic
    plan describing exactly what should be created in MSX:

        Opportunity (1)
          |- Milestone  (SR 2601...0001)   <- Blocked, capacity, SR# isolated
          |    \- Non-AI UAT               <- submit_non_ai, references the milestone
          |- Milestone  (SR 2601...0002)
          |    \- Non-AI UAT
          |- Milestone  (SR 2601...0003)   <- technical SR: milestone only, no UAT
          ...

    By default it runs as a DRY RUN: it writes nothing and prints the full plan plus a
    machine-readable ingestion-plan-*.json. The actual MSX writes (opportunity,
    milestones, UATs) go through the msx-mcp tools, which require an approval prompt for
    every write - so they are driven by Copilot from this plan, not by this script.

    ACR / consumption figures are never emitted (msp_monthlyuse is intentionally left
    for the account team to set separately).

.PARAMETER InputFile
    Path to the hand-off file. Preferred: the machine-readable
    azure-support-results-*.json. The matching *.email.txt is also accepted (the script
    will use its sibling .json when present, otherwise it parses the email text).

.PARAMETER OpportunityName
    Optional. Name for the single opportunity all milestones hang under. If omitted a
    name is proposed from the customer + region.

.PARAMETER OpportunityId
    Optional. If the account team already has an opportunity, pass its GUID to attach the
    milestones to it instead of creating a new one.

.PARAMETER OutputPlan
    Path for the ingestion plan JSON. Defaults next to the input file.

.EXAMPLE
    .\Ingest-SupportEmail.ps1 -InputFile .\azure-support-results-20260101-120000.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,
    [string]$OpportunityName,
    [string]$OpportunityId,
    [string]$OutputPlan
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------------
# Small console logger (mirrors the engine's real-time, colour-coded output).
# ---------------------------------------------------------------------------------
function Write-Ing {
    param([string]$Message, [ValidateSet("INFO","OK","WARN","ERROR","STEP","PLAN")] [string]$Level = "INFO")
    $ts = (Get-Date).ToString("HH:mm:ss")
    $color = switch ($Level) {
        "OK"    { "Green" }   "WARN" { "Yellow" }  "ERROR" { "Red" }
        "STEP"  { "Cyan" }    "PLAN" { "Magenta" } default  { "Gray" }
    }
    Write-Host ("[{0}] {1,-5} {2}" -f $ts, $Level, $Message) -ForegroundColor $color
}

# ---------------------------------------------------------------------------------
# MSX OptionSet codes (see create-milestone / quota skills). Kept as constants so the
# plan shows exactly what Copilot will write.
# ---------------------------------------------------------------------------------
$MS = @{
    StatusBlocked            = 861980002   # msp_milestonestatus = Blocked
    CategoryProduction       = 861980002   # msp_milestonecategory = Production
    CategoryPocPilot         = 861980000   # msp_milestonecategory = POC/Pilot
    HelpAzureCapacity        = 861980001   # msp_helpneeded = Azure Capacity
    HelpServiceAvailability  = 606820000   # msp_helpneeded = Azure Service/Product Availability
    ReasonCapacity           = 861980009   # msp_milestonestatusreason = Capacity/Service Availability
    ReasonProductFeature     = 861980000   # msp_milestonestatusreason = App compat/product feature
}

# Best-effort map from az VM family -> UAT SKU catalog label. The exact label is
# verified live against the UAT catalog at submission; this is the starting point.
$SkuMap = @{
    "standardESv5Family"      = "Esv5 Series"
    "standardDSv5Family"      = "Dsv5 Series"
    "standardEDSv5Family"     = "Edsv5 Series"
    "standardDDSv5Family"     = "Ddsv5 Series"
    "standardDDSv4Family"     = "Ddsv4 Series"
    "standardNCASv3_T4Family" = "NCasT4_v3 Series"
    "lowPriorityCores"        = "Spot / Low-Priority Cores"
}
function Resolve-Sku {
    param([string]$Family)
    if ($SkuMap.ContainsKey($Family)) { return $SkuMap[$Family] }
    return "$Family  [verify against UAT catalog]"
}

# Recompute the workload environment the same way the email generator does, from the
# free-text Deployment value. Customer never fills this in explicitly.
function Get-WorkloadEnvironment {
    param([string]$Deployment)
    $d = "$Deployment".ToLower()
    if ($d -match 'prod|production')          { return "Prod" }
    if ($d -match 'dev[\s/_-]*test|devtest')  { return "Dev/Test" }
    if ($d -match 'stag')                     { return "Staging" }
    if ($d -match '\bdev\b|develop')          { return "Dev" }
    if ($d -match 'test|\bqa\b|\buat\b')      { return "Test" }
    return "Prod"
}

# ---------------------------------------------------------------------------------
# Load the hand-off. Prefer the structured results JSON; fall back to the email text.
# ---------------------------------------------------------------------------------
function Import-Handoff {
    param([string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $ext = [System.IO.Path]::GetExtension($resolved).ToLower()

    if ($ext -eq ".json") {
        Write-Ing "Reading structured results JSON: $resolved" "INFO"
        return (Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json)
    }

    # It's the .email.txt - look for the sibling results JSON first (same timestamp).
    $dir  = [System.IO.Path]::GetDirectoryName($resolved)
    $base = [System.IO.Path]::GetFileName($resolved) -replace '\.email\.txt$', '.json'
    $sibling = Join-Path $dir $base
    if (Test-Path -LiteralPath $sibling) {
        Write-Ing "Using structured sibling JSON: $sibling" "INFO"
        return (Get-Content -Raw -LiteralPath $sibling | ConvertFrom-Json)
    }

    throw "Only the email text was supplied and no sibling '$base' was found. Send the azure-support-results-*.json (it is generated next to the email)."
}

# ---------------------------------------------------------------------------------
# Build the per-SR narrative (scenario + outcome) - same rules the email uses.
# ---------------------------------------------------------------------------------
function Get-Narrative {
    param($R, [string]$Env)
    $region = if ($R.region) { $R.region } else { "the requested region" }
    $dep    = if ($R.deployment -and ("$($R.deployment)".Trim() -ne $Env)) { "$($R.deployment) ($Env)" } else { $Env }
    $isTech = ("$($R.ticketType)" -eq "technical")
    $t = ("$($R.need) $($R.title)").ToLower()
    if ($isTech) {
        $svc = if ($R.serviceDisplayName) { "$($R.serviceDisplayName) - $($R.problemClassificationDisplayName)" } else { "the requested capability" }
        $scenario = "The customer needs $svc for their $dep workload in $region."
        $outcome  = "Azure actions the request so the capability is enabled for the customer in $region."
    } elseif ($t -match 'zonal|availability zone') {
        $scenario = "The customer needs Availability Zone access for zone-restricted VM families in $region so their $dep workload can deploy across the requested zones."
        $outcome  = "Azure whitelists the requested VM families in the restricted Availability Zones so the customer can deploy zonally in $region."
    } elseif ($t -match 'spot|low[\s-]*priority') {
        $scenario = "The customer needs additional Spot (low-priority) vCPU capacity in $region for their $dep workload."
        $outcome  = "Azure approves the requested Spot quota so the customer can run the required low-priority capacity in $region."
    } elseif ($t -match 'gpu') {
        $scenario = "The customer needs additional GPU (vCPU) capacity in $region for their $dep workload."
        $outcome  = "Azure approves the requested GPU quota so the customer can deploy the required accelerated capacity in $region."
    } else {
        $scenario = "The customer needs additional compute (vCPU) capacity in $region for their $dep workload."
        $outcome  = "Azure approves the requested quota/limit increase so the customer can deploy the required capacity in $region."
    }
    return [pscustomobject]@{ Scenario = $scenario; Outcome = $outcome }
}

# =================================================================================
# Main
# =================================================================================
Write-Ing "Azure Support -> MSX ingestion planner (DRY RUN - no MSX writes)" "STEP"

$handoff = Import-Handoff -Path $InputFile

# Actionable requests = those that were (or would be) opened as real SRs.
$all = @($handoff.results)
$requests = @($all | Where-Object { $_.status -in @("Created","WouldCreate") })
if ($requests.Count -eq 0) {
    throw "No actionable requests (Created / WouldCreate) found in the hand-off. Nothing to ingest."
}

$isPreview = @($requests | Where-Object { $_.status -eq "WouldCreate" }).Count -gt 0
$customer  = @($requests | ForEach-Object { $_.customer } | Where-Object { $_ } | Select-Object -First 1)
if (-not $customer) { $customer = "the customer" }
$regions   = @($requests | ForEach-Object { $_.region } | Where-Object { $_ } | Select-Object -Unique)
$subs      = @($requests | ForEach-Object { $_.subscriptionId } | Where-Object { $_ } | Select-Object -Unique)
$regionTag = ($regions -join ", ")

if ($isPreview) {
    Write-Ing "Hand-off is a PREVIEW (WhatIf) - support requests are not yet open. Real SR numbers will be blank until the customer submits." "WARN"
}

# ---- Opportunity plan -----------------------------------------------------------
if ($OpportunityId) {
    $oppPlan = [pscustomobject]@{
        action        = "attach"
        opportunityId = $OpportunityId
        note          = "Milestones will be attached to this existing opportunity."
    }
} else {
    if (-not $OpportunityName) {
        $OpportunityName = "$customer - Azure Capacity & Support Escalation ($regionTag) - $(Get-Date -Format 'MMM yyyy')"
    }
    $oppPlan = [pscustomobject]@{
        action          = "create"
        name            = $OpportunityName
        accountNameHint = $customer
        estStartDate    = (Get-Date -Format 'yyyy-MM-dd')
        resolve         = "Account (parentaccountid) + TPID resolved live from customer name at execution; msp_eststartdate is required and set to today."
    }
}

# ---- Milestone + UAT plan per SR ------------------------------------------------
$milestones = @()
$i = 0
foreach ($r in $requests) {
    $i++
    $sr16   = if ("$($r.supportTicketId)" -match '(\d{16})') { $Matches[1] } else { $null }
    $srDisp = if ($r.supportTicketId) { "$($r.supportTicketId)" } else { "(not yet submitted)" }
    $env    = Get-WorkloadEnvironment $r.deployment
    $narr   = Get-Narrative -R $r -Env $env
    $isTech = ("$($r.ticketType)" -eq "technical")
    $payload = @($r.payload)
    $isZonal = @($payload | Where-Object { $_.Type -eq "Zonal" }).Count -gt 0

    # Milestone name: customer + short intent + region.
    $intent = ($r.title -replace "^\s*$customer\s*", "").Trim()
    $msName = "$customer - $intent"
    if ($msName.Length -gt 190) { $msName = $msName.Substring(0,190) }

    # Risk/Blocker details (msp_milestonecomments) MUST carry the exact SR# for
    # request-to-milestone isolation.
    $risk = "Azure support request: $srDisp." +
            $(if ($sr16) { " (16-digit ID: $sr16.)" } else { "" }) +
            " $($narr.Scenario)"
    if ($r.businessImpact) { $risk += " Business impact: $($r.businessImpact)" }

    # Forecast comments (visible Milestone Comments) - no ACR.
    $forecast = "$($narr.Scenario) $($narr.Outcome) Requested via Azure support request $srDisp."

    # UAT plan (capacity only; technical SRs get a milestone but no Non-AI UAT).
    $uat = $null
    if (-not $isTech) {
        if ($isZonal) {
            $zoneCount = @($payload | Select-Object -ExpandProperty ZoneNum -Unique).Count
            $regionalZonal = if ($zoneCount -le 1) { "AZ1" } else { "$zoneCount Zones" }
        } else {
            $regionalZonal = "Regional"
        }
        # Aggregate cores per family (sum across zones for zonal).
        $skuLines = @()
        foreach ($fam in (@($payload | Select-Object -ExpandProperty Family -Unique))) {
            $qty = (@($payload | Where-Object { $_.Family -eq $fam }) | Measure-Object -Property Limit -Sum).Sum
            $skuLines += [pscustomobject]@{
                sku      = (Resolve-Sku $fam)
                family   = $fam
                uom      = "Cores"
                quantity = [int]$qty
            }
        }
        $uat = [pscustomobject]@{
            mode                = "submit_non_ai"
            milestone           = "(the milestone above, referenced by its 7-XXXXXXXXX number)"
            subscription_id     = $r.subscriptionId
            support_request_ids = @($sr16 | Where-Object { $_ })
            workload_environment = $env
            regional_zonal      = $regionalZonal
            region              = $r.region
            skus                = $skuLines
            customer_scenario   = "$($narr.Scenario) $($narr.Outcome)"
            customer_impact     = "$($r.businessImpact) Timing: as soon as possible - the Azure support request is already open."
            note                = if ($skuLines.Count -gt 3) { "More than 3 SKUs - the Non-AI UAT payload holds 3 SKU slots; this milestone needs the extra SKUs filed as a second UAT (or via replay payload)." } else { $null }
        }
    }

    $milestones += [pscustomobject]@{
        index               = $i
        supportRequest      = $srDisp
        supportRequest16    = $sr16
        need                = $r.need
        ticketType          = $r.ticketType
        name                = $msName
        milestoneDate       = (Get-Date -Format 'yyyy-MM-dd')
        region              = $r.region
        deployment          = $r.deployment
        workloadEnvironment = $env
        status              = "Blocked"
        statusCode          = $MS.StatusBlocked
        category            = if ($env -eq "Prod") { "Production" } else { "POC/Pilot" }
        categoryCode        = if ($env -eq "Prod") { $MS.CategoryProduction } else { $MS.CategoryPocPilot }
        helpNeeded          = if ($isTech) { "Azure Service/Product Availability" } else { "Azure Capacity" }
        helpNeededCode      = if ($isTech) { $MS.HelpServiceAvailability } else { $MS.HelpAzureCapacity }
        statusReason        = if ($isTech) { "App compat/product feature" } else { "Capacity/Service Availability" }
        statusReasonCode    = if ($isTech) { $MS.ReasonProductFeature } else { $MS.ReasonCapacity }
        preferredRegion     = $r.region
        forecastComments    = $forecast
        riskBlockerComments = $risk
        workloadResolve     = "msp_WorkloadlkId resolved live from deployment/service keywords at execution."
        acr                 = "OMITTED (msp_monthlyuse not set by ingest)"
        uat                 = $uat
    }
}

# ---- Assemble + persist the plan ------------------------------------------------
$plan = [pscustomobject]@{
    generatedAt     = (Get-Date).ToUniversalTime().ToString("o")
    source          = (Resolve-Path -LiteralPath $InputFile).Path
    sourceMode      = if ($isPreview) { "preview" } else { "live" }
    customer        = $customer
    subscriptions   = $subs
    regions         = $regions
    autoJoinTeam    = "Add current user (UserId 11111111-1111-1111-1111-111111111111) to each milestone team."
    opportunity     = $oppPlan
    milestones      = $milestones
}

if (-not $OutputPlan) {
    $inDir = [System.IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $InputFile).Path)
    $OutputPlan = Join-Path $inDir ("ingestion-plan-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$plan | ConvertTo-Json -Depth 50 | Set-Content -Path $OutputPlan -Encoding UTF8

# ---------------------------------------------------------------------------------
# Human-readable dry-run summary
# ---------------------------------------------------------------------------------
Write-Host ""
Write-Ing "=============================================================" "PLAN"
Write-Ing " MSX INGESTION PLAN (DRY RUN)  -  customer: $customer" "PLAN"
Write-Ing "=============================================================" "PLAN"
Write-Ing "Source        : $((Resolve-Path -LiteralPath $InputFile).Path)" "INFO"
Write-Ing "Subscriptions : $($subs -join ', ')" "INFO"
Write-Ing "Regions       : $($regions -join ', ')" "INFO"
$capCount  = @($milestones | Where-Object { $_.uat }).Count
$techCount = $milestones.Count - $capCount
Write-Ing "Would create  : 1 opportunity, $($milestones.Count) milestone(s), $capCount Non-AI UAT(s)  ($techCount technical milestone(s) with no UAT)" "INFO"
Write-Host ""

Write-Ing "OPPORTUNITY" "STEP"
if ($oppPlan.action -eq "create") {
    Write-Host "  Action : CREATE new opportunity"
    Write-Host "  Name   : $($oppPlan.name)"
    Write-Host "  Account: $($oppPlan.accountNameHint)   (parentaccountid + TPID resolved live)"
    Write-Host "  Start  : $($oppPlan.estStartDate)   (msp_eststartdate - required)"
} else {
    Write-Host "  Action : ATTACH to existing opportunity $($oppPlan.opportunityId)"
}
Write-Host ""

foreach ($m in $milestones) {
    Write-Ing ("MILESTONE {0}/{1}  -  SR {2}" -f $m.index, $milestones.Count, $m.supportRequest) "STEP"
    Write-Host "  Name            : $($m.name)"
    Write-Host "  Status          : Blocked ($($m.statusCode))   Category: $($m.category) ($($m.categoryCode))"
    Write-Host "  Help needed     : $($m.helpNeeded) ($($m.helpNeededCode))"
    Write-Host "  Status reason   : $($m.statusReason) ($($m.statusReasonCode))"
    Write-Host "  Region / env    : $($m.region)  /  $($m.workloadEnvironment)"
    Write-Host "  Milestone date  : $($m.milestoneDate)"
    Write-Host "  ACR             : $($m.acr)"
    Write-Host "  Risk/Blocker    : $($m.riskBlockerComments)"
    Write-Host "  Milestone Cmts  : $($m.forecastComments)"
    if ($m.uat) {
        Write-Host "  -> Non-AI UAT (submit_non_ai):" -ForegroundColor DarkCyan
        Write-Host "       Subscription : $($m.uat.subscription_id)"
        Write-Host "       SR (16-digit): $((@($m.uat.support_request_ids) -join ', '))"
        Write-Host "       Scope        : $($m.uat.regional_zonal)   Env: $($m.uat.workload_environment)   Region: $($m.uat.region)"
        foreach ($s in $m.uat.skus) {
            Write-Host ("       SKU          : {0}  =  {1} {2}   (family {3})" -f $s.sku, $s.quantity, $s.uom, $s.family)
        }
        Write-Host "       Scenario     : $($m.uat.customer_scenario)"
        Write-Host "       Impact       : $($m.uat.customer_impact)"
        if ($m.uat.note) { Write-Host "       NOTE         : $($m.uat.note)" -ForegroundColor Yellow }
    } else {
        Write-Host "  -> No Non-AI UAT (technical request - milestone only)." -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Ing "Plan written to: $OutputPlan" "OK"
Write-Ing "DRY RUN complete - nothing was written to MSX." "OK"
Write-Ing "To execute: hand this plan to Copilot, which creates the opportunity, milestones, and UATs via the msx-mcp tools (each write asks for confirmation)." "INFO"
