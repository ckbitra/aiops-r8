# Complete Project Workflow

## AIOps R8 - Production-Safe CVE Patching (Amazon Inspector)

This document describes the end-to-end workflow for automated CVE patching of RHEL8 and Windows servers using AWS services and Bedrock LLM.

## Workflow Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        AIOps R8 Patch Workflow (Amazon Inspector)             │
└─────────────────────────────────────────────────────────────────────────────┘

1. SCHEDULE (EventBridge)
   │  cron(0 2 ? * 3#2 *)  →  2:00 AM UTC on 2nd Tuesday (after Patch Tuesday)
   ▼
2. DISCOVER INSTANCES (Lambda)
   │  Instance Discovery Lambda: by tags (Role=patch-target) or static Terraform IDs
   │  Excludes PatchExcluded=true
   ▼
3. FETCH INSPECTOR FINDINGS (Lambda)
   │  Inspector Findings Lambda fetches CVE findings from Amazon Inspector v2
   ▼
4. ANALYZE (Lambda + Bedrock)
   │  Lambda sends Inspector findings to Bedrock; model analyzes CVEs
   │  Returns has_critical_cves flag + recommendations
   ▼
5. CHECK MAINTENANCE WINDOW (optional)
   │  If outside window → Skip
   ▼
6. PREPARE BATCHES + APPLY (Map over batches)
   │  Per batch: Patch → Wait 180s → CheckFailure → continue or abort
   │  Batched patching stops within same run if instance fails to reboot
   ▼
7. POST-PATCH (Parallel, via Lambda → SSM)
   │  SSM Runner Lambda verifies patches on RHEL8 and Windows
   ▼
8. COMPLETE
```

## Component Interaction

| Step | Component | Action |
|------|------------|--------|
| 1 | EventBridge | Triggers Step Functions on schedule |
| 2 | Instance Discovery Lambda | Discovers instances by tags; excludes PatchExcluded |
| 3 | Inspector Findings Lambda | Fetches CVE findings from Amazon Inspector v2 |
| 4 | CVE Analyzer Lambda + Bedrock | CVE analysis (retry, fallback, safe parsing) |
| 5 | Maintenance Window Lambda | Optional: skip if outside window |
| 6 | Batch Prepare + SSM Runner | Batched patching; mid-run failure detection |
| 7 | SSM Runner Lambda → SSM | Post-patch verification |
| 8 | Step Functions | Workflow completes |

**Circuit-breaker:** EventBridge rule on EC2 `stopped` invokes EC2 Stopped Handler Lambda. Records CVE failures in DynamoDB. SSM Runner checks before patching; skips and sends SNS alert if CVE is blocked.

**AMI cleanup:** Daily EventBridge rule invokes AMI Cleanup Lambda to deregister old pre-patch AMIs.

## CVE-Only Patching

- **RHEL8**: `dnf update --security -y` / `yum update --security -y` – security updates only
- **Windows**: Patch Baseline with `CLASSIFICATION=SecurityUpdates,CriticalUpdates` and `enable_non_security=false`

## Report Locations

| Platform | Scan Report | Pre-Patch | Post-Patch |
|----------|-------------|-----------|------------|
| RHEL8 | `/var/log/aiops/rhel8_scan_report.txt` | N/A (Inspector) | `/var/log/aiops/post_patch_report.txt` |
| Windows | `C:\aiops\reports\windows_scan_report.txt` | N/A (Inspector) | `C:\aiops\reports\post_patch_report.txt` |

## Manual Triggers

To run the workflow manually:

```bash
aws stepfunctions start-execution \
  --state-machine-arn <STATE_MACHINE_ARN> \
  --input '{}'
```

## Prerequisites

1. **AWS Account** – With permissions for EC2, Lambda, Step Functions, EventBridge, SSM, Bedrock, Inspector
2. **Bedrock Access** – `us.amazon.nova-2-lite-v1:0` (Amazon Nova 2 Lite) enabled in your region
3. **SSM Agent** – Pre-installed on RHEL and Windows AMIs
4. **Network** – Instances need outbound HTTPS for SSM, yum, Windows Update
5. **Amazon Inspector v2** – Enabled for EC2 (Terraform enables this automatically)

---

## Circuit-Breaker

The circuit-breaker prevents cascading failures when a CVE patch causes an instance to fail to reboot. Without it, the workflow would continue patching other instances with the same CVE, potentially taking multiple nodes offline.

### What It Does

1. **Within the same run** – Instances are patched in batches. After each batch, the Failure Check Lambda verifies that recently patched instances are still running. If any instance is `stopped`, the workflow fails and remaining batches are not executed.

2. **Across future runs** – When an EC2 instance transitions to `stopped`, EventBridge invokes the EC2 Stopped Handler Lambda. It checks if that instance was patched recently (within a correlation window, default 45 minutes). If yes, it records the CVE(s) in the `cve-patch-failures` DynamoDB table. On the next scheduled or manual run, the SSM Runner queries this table before patching. If any critical CVE is blocked, patching is skipped for all instances and an SNS alert is sent.

### Key Components

| Component | Role |
|-----------|------|
| **EventBridge rule** (`ec2-stopped-rule`) | Triggers on EC2 instance state `stopped` |
| **EC2 Stopped Handler Lambda** | Correlates stop with recent patch; records CVE(s) in `cve-patch-failures` |
| **DynamoDB `cve-patch-failures`** | Block list of CVEs that caused reboot failure |
| **DynamoDB `patch-executions`** | Tracks which instances were patched and when (for correlation) |
| **SSM Runner Lambda** | Pre-patch check: queries `cve-patch-failures`; skips patching if CVE is blocked |
| **SNS `patch-alerts`** | Notifies when patching is skipped due to circuit-breaker |
| **Failure Check Lambda** | Detects stopped instances within the same run; stops remaining batches |

### Configuration

- **`CVE_BLOCK_TTL_DAYS`** (default 7): How long a CVE remains blocked after a failure.
- **`PATCH_CORRELATION_MINUTES`** (default 45): Window to correlate an instance stop with a recent patch.

To clear a block before TTL expires, delete the failure record from `cve-patch-failures` for that CVE.
