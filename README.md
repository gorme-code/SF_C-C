# HOPE Calendars & Closures — Salesforce Metadata

Salesforce DX project containing all custom metadata for the HOPE Calendars & Closures module. Deployed to the `scde-sandbox` org (scratch-org alias `devmemberc`). The Python API (`python-API/cc_api`) is the only external system that writes to this org — the React frontend never calls Salesforce directly.

## Data model

### Case (two record types)

| Record Type | Business Process | Purpose |
|---|---|---|
| `Closure_Submission` | `Closure_Submission_Process` | One per district closure report. Triggers `Create_Closure_Events` Flow on insert. |
| `Closure_Waiver_Request` | `Closure_Waiver_Process` | Waiver request for excess missed days. Routes through tier-based approval. |

### Custom objects

| Object | Purpose |
|---|---|
| `Closure_Event__c` | One row per school × date, created by the `Create_Closure_Events` Flow from a `Closure_Submission` Case. |
| `Makeup_Day__c` | A proposed or approved makeup day, linked to events via `Closure_Makeup_Link__c`. |
| `Closure_Makeup_Link__c` | Junction: `Closure_Event__c` ↔ `Makeup_Day__c` (holds `Hours_Covered__c`). |
| `Waiver_Closure_Link__c` | Junction: waiver `Case` ↔ `Closure_Event__c`. |

### Account extension

`Account` (RecordType: `District`) has `Total_Missed_Days_YTD__c` — a rollup updated by `RollupMissedDays.cls` whenever a `Closure_Event__c` is created, updated, or deleted.

### Custom metadata types

| Type | Purpose |
|---|---|
| `Closure_Reason__mdt` | Active closure reasons surfaced in the React form. `Requires_Makeup_Default__c` flags reasons that typically need a makeup plan. |
| `Compliance_Rules__mdt` | Tier thresholds (3 / 6 / 9 missed days) and hours-per-instructional-day (6.5). Single `Default` record. |

## Flows

| Flow | Status | Purpose |
|---|---|---|
| `Create_Closure_Events` | Active | Expands a `Closure_Submission` Case into `Closure_Event__c` rows (one per school × date). Entry: Record-Triggered on Case insert. |
| `Calculate_YTD_Missed_Days` | Active | Recalculates district YTD after event changes. |
| `Set_Make_Up_Required` | Active | Sets `Make_Up_Required__c` on new events based on `Closure_Reason__mdt.Requires_Makeup_Default__c`. |
| `Set_Event_Make_Up_Pending` | Active | Moves event to `Make_Up_Pending` status when a makeup is logged. |
| `Close_Events_On_Makeup_Approval` | Active | Marks linked events `Closed` when a `Makeup_Day__c` is approved. |
| `Route_Waiver_By_Tier` | Active | Routes a waiver Case to the correct approval process based on `Tier__c`. |
| `Populate_District_On_Event` | Active | Stamps `District__c` on `Closure_Event__c` from the parent school's Account. |
| `Tier_Boundary_Check` | **Deactivated** | Was intended to auto-draft a waiver Case when a submission crossed a tier boundary. Currently inactive in the org. |

## Apex

| Class / Trigger | Purpose |
|---|---|
| `ExpandClosureSubmission.cls` | Called by `Create_Closure_Events`; builds the `Closure_Event__c` records. |
| `RollupMissedDays.cls` | Rolls up `Hours_Missed__c` across events to `Account.Total_Missed_Days_YTD__c`. |
| `ClosureEventTrigger.trigger` | After-insert/update/delete on `Closure_Event__c` — calls `RollupMissedDays`. |
| `WaiverCaseTrigger.trigger` | After-update on `Case` (Waiver record type) — handles status transitions. |

Tests: `ExpandClosureSubmission_Test`, `RollupMissedDays_Test`, `ClosureEventTriggerTest`, `WaiverCaseTriggerTest`, `ClosureSubmission_E2E_Test`, `Set_Make_Up_Required_Test`.

## Approval processes

| Process | Object | Purpose |
|---|---|---|
| `Closure_Submission_Review` | Case (Closure_Submission) | SCDE reviewer approves or returns a district closure submission. |
| `Waiver_Tier2_Approval` | Case (Closure_Waiver_Request) | Local-board approval for Tier 2 waivers. |
| `Waiver_Tier3_Approval` | Case (Closure_Waiver_Request) | State-board approval for Tier 3 / Tier 4 waivers (requires superintendent certification). |
| `Makeup_Approval` | Makeup_Day__c | SCDE approves or rejects a proposed makeup day. |

## Deploy

Always deploy new **fields** (objects) before deploying **permission sets** that grant FLS on those fields — Salesforce rejects an FLS grant referencing a field that doesn't exist yet.

```powershell
# Deploy metadata to the connected org
sf project deploy start --source-dir force-app

# Run all Apex tests after deploy
sf apex run test --test-level RunLocalTests --wait 10
```

## Permission sets & custom permissions

`Calendar_Closures_SCDE_Reviewer` — custom permission that unlocks reviewer-only actions (approve/return closures, view SCDE internal notes). Granted to SCDE staff; district users do not hold it.
