# Scenario 1: Patching 1000 RHEL8 + 1000 Windows Hosts

This document explains how the AIOps R8 patch workflow executes when patching 1000 RHEL8 and 1000 Windows hosts, including the full execution flow and a diagram.

---

## Scenario Setup


| Parameter             | Value                      |
| --------------------- | -------------------------- |
| **RHEL8 hosts**       | 1000                       |
| **Windows hosts**     | 1000                       |
| **Batch size**        | 10 (default)               |
| **Canary batch size** | 0 (disabled)               |
| **RHEL batches**      | 100 batches × 10 instances |
| **Windows batches**   | 100 batches × 10 instances |


---

## Workflow Execution Order

### Phase 1: Discovery and Validation


| Step | State                      | Lambda               | What Happens                                                                                                                                                   |
| ---- | -------------------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | **DiscoverInstances**      | `instance-discovery` | Discovers EC2 instances in VPC with `Role=patch-target`, `OS=rhel8` or `OS=windows`. Excludes `PatchExcluded=true`. Returns 1000 RHEL8 IDs + 1000 Windows IDs. |
| 2    | **CheckSSMAgentHealth**    | `ssm-agent-health`   | Filters to instances with `PingStatus=Online`. If any excluded → SNS alert. Output: managed RHEL8 IDs, managed Windows IDs.                                    |
| 3    | **FetchInspectorFindings** | `inspector-findings` | Fetches CVE findings from Amazon Inspector for the VPC (or instance IDs).                                                                                      |
| 4    | **AnalyzeCVEs**            | `cve-analyzer`       | Sends findings to Bedrock. Returns `has_critical_cves`, `critical_cve_ids`, recommendations.                                                                   |
| 5    | **CheckMaintenanceWindow** | `maintenance-window` | Checks if current UTC hour is within `maintenance_start_hour_utc`–`maintenance_end_hour_utc` (default 02:00–06:00 UTC).                                        |
| 6    | **CheckMaintenanceChoice** | (Choice)             | If `within_window=true` AND `has_critical_cves=true` → **PrepareBatches**. Else → **NotifyNoPatch** (end).                                                     |


### Phase 2: Batch Preparation


| Step | State              | Lambda          | What Happens                                                                                                                                                                                                                      |
| ---- | ------------------ | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 7    | **PrepareBatches** | `batch-prepare` | Splits RHEL8 IDs into 100 batches of 10. Splits Windows IDs into 100 batches of 10. Output: `{ rhel: { batches: [[i1..i10], [i11..i20], ..., [i991..i1000]], ... }, windows: { batches: [[w1..w10], ..., [w991..w1000]], ... } }` |


### Phase 3: Apply Patches (Parallel RHEL + Windows)

**ApplyPatches** runs two branches **in parallel**:

- **Branch A: MapRHELBatches** – iterates over 100 RHEL batches, one at a time (`MaxConcurrency=1`)
- **Branch B: MapWindowsBatches** – iterates over 100 Windows batches, one at a time (`MaxConcurrency=1`)

For **each batch** (RHEL or Windows), the iterator runs:


| Sub-step | State                                              | What Happens                                                                                                                                                                                                                                                                          |
| -------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3a       | **PatchRHELBatch** / **PatchWindowsBatch**         | SSM Runner: (1) Circuit-breaker check: query `cve-patch-failures` for blocked CVEs; if blocked → SNS alert, return early. (2) Create pre-patch AMIs (if enabled). (3) Run SSM: RHEL = `dnf update --security -y`, Windows = `AWS-RunPatchBaseline`. (4) Record in `patch_executions`. |
| 3b       | **WaitAfterRHELBatch** / **WaitAfterWindowsBatch** | Wait 180 seconds (for reboots).                                                                                                                                                                                                                                                       |
| 3c       | **CheckRHELFailure** / **CheckWindowsFailure**     | Failure Check Lambda: query `patch_executions` for recent patches, check EC2 state. If any instance is `stopped` → `abort=true`.                                                                                                                                                      |
| 3d       | **ChoiceRHELAbort** / **ChoiceWindowsAbort**       | If `abort=true` → **RHELFail** / **WindowsFail** (workflow fails, remaining batches not run). Else → **RHELSucceed** / **WindowsSucceed** → next batch.                                                                                                                               |


### Phase 4: Post-Patch


| Step | State         | Lambda       | What Happens                                                                                                          |
| ---- | ------------- | ------------ | --------------------------------------------------------------------------------------------------------------------- |
| 8    | **PostPatch** | `ssm-runner` | Parallel: RHEL post-patch verification (`dnf check-update --security`), Windows post-patch verification (PowerShell). |


---





## Execution Diagram

```
                                    ┌─────────────────────────┐
                                    │   EventBridge Schedule   │
                                    │  (2 AM UTC, 2nd Tuesday) │
                                    └────────────┬────────────┘
                                                 │
                                                 ▼
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                           Step Functions: Patch Workflow                                 │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│  1. DiscoverInstances ──► 1000 RHEL8 + 1000 Windows (by tags, exclude PatchExcluded)      │
│           │                                                                              │
│           ▼                                                                              │
│  2. CheckSSMAgentHealth ──► Filter to SSM-managed only (PingStatus=Online)               │
│           │                  [SNS if any excluded]                                       │
│           ▼                                                                              │
│  3. FetchInspectorFindings ──► Get CVE findings from Amazon Inspector                    │
│           │                                                                              │
│           ▼                                                                              │
│  4. AnalyzeCVEs ──► Bedrock analyzes → has_critical_cves, critical_cve_ids               │
│           │                                                                              │
│           ▼                                                                              │
│  5. CheckMaintenanceWindow ──► within_window?                                            │
│           │                                                                              │
│           ▼                                                                              │
│  6. CheckMaintenanceChoice ──► within_window AND has_critical_cves?                      │
│           │                           │                                                  │
│           │ Yes                       │ No → NotifyNoPatch (End)                         │
│           ▼                           │                                                  │
│  7. PrepareBatches ──► RHEL: 100 batches of 10  │  Windows: 100 batches of 10             │
│           │                                                                              │
│           ▼                                                                              │
│  8. ApplyPatches (PARALLEL)                                                              │
│     ┌─────────────────────────────────┐  ┌──────────────────────────────────┐            │
│     │  RHEL Branch                    │  │  Windows Branch                  │            │
│     │  MapRHELBatches (sequential)    │  │  MapWindowsBatches (sequential)  │            │
│     │                                 │  │                                  │            │
│     │  Batch 1: i1–i10   ──► Patch ──► │ │  Batch 1: w1–w10  ──► Patch ──►  │            │
│     │  Wait 180s ──► FailureCheck     │  │  Wait 180s ──► FailureCheck      │            │
│     │  abort? ──► Fail or next        │  │  abort? ──► Fail or next         │            │
│     │                                 │  │                                  │            │
│     │  Batch 2: i11–i20 ──► ...       │  │  Batch 2: w11–w20 ──► ...        │            │
│     │  ...                            │  │  ...                             │            │
│     │  Batch 100: i991–i1000           │  │  Batch 100: w991–w1000           │            │
│     └─────────────────────────────────┘  └──────────────────────────────────┘            │
│           │                                    │                                         │
│           └────────────────┬───────────────────┘                                         │
│                             ▼                                                            │
│  9. PostPatch (PARALLEL) ──► RHEL verify | Windows verify                                │
│                             ▼                                                            │
│                         End (Success)                                                    │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

---

## Timeline Example (Success Case)

Assuming all batches complete successfully and no failures:


| Time        | Event                                                                                               |
| ----------- | --------------------------------------------------------------------------------------------------- |
| T+0         | DiscoverInstances, CheckSSMAgentHealth, FetchInspectorFindings, AnalyzeCVEs, CheckMaintenanceWindow |
| T+1 min     | PrepareBatches → 100 RHEL batches, 100 Windows batches                                              |
| T+2 min     | **RHEL Batch 1** (i1–i10): Pre-patch AMIs, SSM command                                              |
| T+2 min     | **Windows Batch 1** (w1–w10): Pre-patch AMIs, SSM RunPatchBaseline                                  |
| T+5 min     | RHEL Batch 1 completes; Wait 180s                                                                   |
| T+5 min     | Windows Batch 1 completes; Wait 180s                                                                |
| T+8 min     | Failure Check (both): no stopped instances → continue                                               |
| T+8 min     | **RHEL Batch 2**, **Windows Batch 2** start                                                         |
| ...         | ...                                                                                                 |
| T+~8h 20min | All 100 RHEL + 100 Windows batches complete                                                         |
| T+~8h 21min | PostPatch (parallel RHEL + Windows verification)                                                    |
| T+~8h 22min | Workflow ends successfully                                                                          |


*Note: RHEL and Windows run in parallel, so total time is driven by the slower of the two (each has 100 batches × ~5 min ≈ 8h 20min).*

---

## Circuit-Breaker: Failure Scenario

If **RHEL instance 5** (in Batch 1) fails to reboot after patching:


| Time     | Event                                                                                                                          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------ |
| T+2 min  | RHEL Batch 1 patches i1–i10                                                                                                    |
| T+5 min  | RHEL Batch 1 SSM completes; Wait 180s                                                                                          |
| T+8 min  | Failure Check: instance i5 is `stopped` → `abort=true`                                                                         |
| T+8 min  | **RHELFail** → workflow transitions to **NotifyFailure**                                                                       |
| T+8 min  | **RHEL Batches 2–100 are not executed** (i11–i1000 never patched)                                                              |
| T+8 min  | **Windows branch** may still complete (parallel) or be caught by Catch                                                         |
| Next run | If EC2 Stopped Handler recorded CVE in `cve-patch-failures`, pre-patch check skips patching for all 2000 hosts; SNS alert sent |


---

## Summary


| Aspect          | Behavior                                                                               |
| --------------- | -------------------------------------------------------------------------------------- |
| **Discovery**   | 1000 RHEL8 + 1000 Windows by tags; exclude PatchExcluded                               |
| **Batching**    | 100 batches × 10 instances per platform (default batch_size=10)                        |
| **Parallelism** | RHEL and Windows branches run in parallel; batches within each branch run sequentially |
| **Per batch**   | Circuit-breaker check → AMI → Patch → Wait 180s → Failure Check → Continue or Fail     |
| **Failure**     | If any instance is stopped after patch, workflow fails; remaining batches not run      |
| **Future runs** | CVE recorded in cve-patch-failures blocks patching for 7 days (configurable)           |


