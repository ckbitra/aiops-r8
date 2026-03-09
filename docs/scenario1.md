# Scenario 1: 100 RHEL8 Hosts – Workflow and Circuit-Breaker Behavior

## Workflow with 100 RHEL8 Hosts (Updated with Batched Patching)

### 1. How the workflow runs

```
1. DiscoverInstances      →  Discovers 100 RHEL8 instances by tags (or static IDs)
2. FetchInspectorFindings →  Gets CVE findings for all 100 instances in the VPC
3. AnalyzeCVEs            →  Bedrock returns has_critical_cves + critical_cve_ids
4. CheckMaintenanceWindow →  Optional: skip if outside window
5. PrepareBatches         →  Splits 100 instances into batches of 10 (configurable)
6. ApplyPatches (Map)     →  For each batch:
   - Patch batch (10 instances) via SSM Runner
   - Wait 180 seconds (for reboots)
   - CheckFailure Lambda: any recently patched instance stopped?
   - If yes → Fail → NotifyFailure (stop remaining batches)
   - If no → next batch
7. Post-patch verification
```

**Important:** With batched patching, if node 2 (in batch 1) fails to reboot, the Failure Check detects it before batch 2 runs. Patching stops within the same run.

---

## What the Circuit-Breaker Does (Updated)

### It DOES stop the current run (with batched patching)

- Instances are patched in batches (default 10).
- After each batch: Wait 180s → CheckFailure Lambda queries patch_executions and EC2 state.
- If any recently patched instance is `stopped`, the workflow fails that batch and transitions to NotifyFailure.
- Remaining batches are not executed.

So if node 2 (in batch 1) fails to reboot, the Failure Check detects it before batch 2 runs. Nodes 11–100 are not patched.

### It DOES protect future runs

1. **Pre-patch check (before each run)**  
   Before sending any patch command, the SSM Runner queries `cve_patch_failures` for the current `critical_cve_ids`.  
   If a CVE was recorded there (from a previous run), patching is skipped for all instances and an SNS alert is sent.

2. **Failure detection (after a run)**  
   When an instance goes to `stopped`, EventBridge invokes the EC2 Stopped Handler.  
   It checks `patch_executions` to see if that instance was patched recently (within `PATCH_CORRELATION_MINUTES`, default 45).  
   If yes, it writes the CVE(s) into `cve_patch_failures`.

3. **Next run**  
   On the next scheduled or manual run, the pre-patch check finds the CVE in `cve_patch_failures` and skips patching for all 100 hosts.

---

## Timeline Example (Batched)

| Time | Event |
|------|--------|
| T+0 | Batch 1 (nodes 1–10): Patch command sent |
| T+3 min | Batch 1 completes; Wait 180s |
| T+6 min | CheckFailure: Node 2 is `stopped` → Fail → NotifyFailure |
| T+6 min | Batches 2–10 are not executed |
| Next month | Run 2: Pre-patch check finds CVE in `cve_patch_failures` → patching skipped for all 100 |

---

## Summary

- **Current behavior:**  
  - Batched patching (default 10 per batch).  
  - The circuit-breaker stops the current run if any instance fails to reboot.

- **What the circuit-breaker does:**  
  - Stops within the same run when Failure Check detects a stopped instance.
  - Prevents future runs from patching the same CVE for 7 days (configurable) after a reboot failure is detected.
