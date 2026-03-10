# All Guardrails – Reference and Verification Guide

This document lists every guardrail in the AIOps R8 patch workflow, explains how each works, and provides verification steps for both the AWS Console and Terraform code.

---

## 1. Circuit-Breaker (CVE Block After Reboot Failure)

### What It Does

When a CVE patch causes an EC2 instance to fail to reboot, the circuit-breaker:
1. **Records** the CVE(s) in DynamoDB (`cve-patch-failures`)
2. **Blocks** future patching of that CVE for 7 days (configurable)
3. **Sends** an SNS alert when patching is skipped

This prevents cascading failures across multiple instances.

### How It Works

- **EC2 Stopped Handler Lambda** – Triggered by EventBridge when an instance stops. Checks if it was patched recently (within 45 minutes). If yes, writes CVE(s) to `cve-patch-failures`.
- **SSM Runner Lambda** – Before patching, queries `cve-patch-failures` for `critical_cve_ids`. If any CVE is blocked, skips patching and sends SNS alert.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **DynamoDB table** | DynamoDB → Tables → `aiops-r8-{env}-cve-patch-failures` | Table exists; PK `cve_id`, SK `failed_at` |
| **EventBridge rule** | EventBridge → Rules → `aiops-r8-{env}-ec2-stopped-rule` | Event pattern: EC2 state = stopped; Target: `aiops-r8-ec2-stopped-handler` |
| **EC2 Stopped Handler Lambda** | Lambda → Functions → `aiops-r8-ec2-stopped-handler` | Env vars: `PATCH_FAILURES_TABLE`, `PATCH_EXECUTIONS_TABLE` |
| **SSM Runner Lambda** | Lambda → Functions → `aiops-r8-ssm-runner` | Env vars: `PATCH_FAILURES_TABLE`, `PATCH_ALERTS_TOPIC_ARN` |
| **SNS topic** | SNS → Topics → `aiops-r8-{env}-patch-alerts` | Topic exists; subscriptions for alerts |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/main.tf` | `aws_dynamodb_table.cve_patch_failures` (lines ~18–38) |
| `terraform/modules/patch-workflow/main.tf` | `aws_cloudwatch_event_rule.ec2_stopped` (lines ~1095–1105) |
| `terraform/modules/patch-workflow/main.tf` | `aws_lambda_function.ec2_stopped_handler` |
| `terraform/modules/patch-workflow/lambda/ec2_stopped_handler.py` | Records CVE to `cve_patch_failures` |
| `terraform/modules/patch-workflow/lambda/ssm_runner.py` | `_check_blocked_cves()` – queries before patching |

---

## 2. CVE Analysis (Bedrock)

### What It Does

Bedrock analyzes Amazon Inspector findings and decides whether critical CVEs require patching. If `has_critical_cves=false`, the workflow skips patching entirely.

### How It Works

- **CVE Analyzer Lambda** – Sends Inspector findings to Bedrock; returns `has_critical_cves` and `critical_cve_ids`.
- **Step Functions Choice** – Proceeds to patching only when `has_critical_cves=true`.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **CVE Analyzer Lambda** | Lambda → Functions → `aiops-r8-cve-analyzer` | Env var: `BEDROCK_MODEL_ID` |
| **Step Functions** | Step Functions → State machines → `aiops-r8-patch-workflow` | Definition includes `CheckMaintenanceChoice` with `has_critical_cves` condition |
| **Bedrock** | Bedrock → Model access | `us.amazon.nova-2-lite-v1:0` (or configured model) enabled |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/main.tf` | `aws_lambda_function.cve_analyzer` |
| `terraform/modules/patch-workflow/main.tf` | Step Functions `CheckMaintenanceChoice` – `$.analyzeResult.Payload.body.has_critical_cves` |
| `terraform/modules/patch-workflow/lambda/cve_analyzer.py` | Bedrock `InvokeModel` call; returns `has_critical_cves` |

---

## 3. Pre-Patch AMI

### What It Does

Before applying patches, the SSM Runner creates an AMI of each target instance. If a patch causes boot failure, you can restore from this AMI. Optional auto-recovery can launch a replacement from the AMI.

### How It Works

- **SSM Runner Lambda** – Calls `ec2.create_image` for each instance before patching. AMIs named `AI-Patch-{InstanceId}-{timestamp}-{patch_mode}`.
- **EC2 Stopped Handler** – When `enable_auto_recovery=true`, finds the pre-patch AMI and launches a replacement instance.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **SSM Runner Lambda** | Lambda → Functions → `aiops-r8-ssm-runner` | IAM role has `ec2:CreateImage` |
| **EC2** | EC2 → Images → AMIs | After a patch run, AMIs with prefix `AI-Patch-` exist |
| **AMI Cleanup Lambda** | Lambda → Functions → `aiops-r8-ami-cleanup` | Daily schedule deregisters old AMIs |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/variables.tf` | `variable "create_prepatch_ami"` (default: true) |
| `terraform/modules/patch-workflow/main.tf` | `create_prepatch_ami` passed to SSM Runner payload |
| `terraform/modules/patch-workflow/lambda/ssm_runner.py` | `_create_prepatch_amis()` – `ec2.create_image()` |
| `terraform/main.tf` | `create_prepatch_ami = var.create_prepatch_ami` |

---

## 4. Dry-Run Mode

### What It Does

When enabled, the SSM Runner logs what it would patch but does not run any SSM commands. Useful for testing the workflow without applying patches.

### How It Works

- **SSM Runner Lambda** – If `dry_run=true`, returns early with a message; no AMI creation or SSM commands.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **Step Functions execution** | Step Functions → Executions | Run with `dry_run=true`; ApplyPatches step returns `dry_run: true` |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/variables.tf` | `variable "dry_run"` (default: false) |
| `terraform/modules/patch-workflow/main.tf` | `dry_run = var.dry_run` in ApplyPatches payload |
| `terraform/modules/patch-workflow/lambda/ssm_runner.py` | `if dry_run: return {...}` before SSM/AMI |

---

## 5. Maintenance Window

### What It Does

Patching runs only during a configured UTC time window (default 02:00–06:00 UTC). Outside the window, the workflow skips patching.

### How It Works

- **Maintenance Window Lambda** – Compares current UTC hour to `maintenance_start_hour_utc` and `maintenance_end_hour_utc`. Returns `within_window: true/false`.
- **Step Functions Choice** – Proceeds to PrepareBatches only when `within_window=true` and `has_critical_cves=true`.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **Maintenance Window Lambda** | Lambda → Functions → `aiops-r8-maintenance-window` | Env vars: `MAINTENANCE_START_HOUR_UTC`, `MAINTENANCE_END_HOUR_UTC`, `CHECK_MAINTENANCE_WINDOW` |
| **Step Functions** | Step Functions → State machines → `aiops-r8-patch-workflow` | `CheckMaintenanceChoice` uses `$.maintenanceCheck.Payload.body.within_window` |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/variables.tf` | `check_maintenance_window` (default: true), `maintenance_start_hour_utc` (2), `maintenance_end_hour_utc` (6) |
| `terraform/modules/patch-workflow/main.tf` | `aws_lambda_function.maintenance_window` – env vars |
| `terraform/modules/patch-workflow/lambda/maintenance_window.py` | Logic for `within_window` |
| `terraform/main.tf` | `check_maintenance_window = var.check_maintenance_window` |

---

## 6. Instance Exclusion (PatchExcluded Tag)

### What It Does

Instances tagged `PatchExcluded=true` (configurable) are excluded from discovery and never patched.

### How It Works

- **Instance Discovery Lambda** – Filters out instances where `tag[EXCLUSION_TAG_KEY] == EXCLUSION_TAG_VALUE` (default: `PatchExcluded=true`).

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **EC2 instance** | EC2 → Instances | Add tag `PatchExcluded` = `true` to an instance; run workflow; instance should not appear in patch targets |
| **Instance Discovery Lambda** | Lambda → Functions → `aiops-r8-instance-discovery` | Logs show excluded instances (or check Step Functions execution input/output) |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/lambda/instance_discovery.py` | `EXCLUSION_TAG_KEY`, `EXCLUSION_TAG_VALUE` (default: PatchExcluded, true) |
| `terraform/modules/patch-workflow/lambda/instance_discovery.py` | `if tags.get(exclusion_tag[0]) == exclusion_tag[1]: continue` |

---

## 7. SSM Agent Health Pre-Check

### What It Does

Before patching, filters out instances that are not in SSM Managed state (PingStatus ≠ Online). Sends an SNS alert when instances are excluded.

### How It Works

- **SSM Agent Health Lambda** – Calls `ssm:DescribeInstanceInformation`, keeps only instances with `PingStatus=Online`. Returns filtered `rhel8_ids` and `windows_ids`.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **SSM Agent Health Lambda** | Lambda → Functions → `aiops-r8-ssm-agent-health` | Env vars: `CHECK_SSM_AGENT_HEALTH`, `PATCH_ALERTS_TOPIC_ARN` |
| **Step Functions** | Step Functions → State machines → `aiops-r8-patch-workflow` | `CheckSSMAgentHealth` state between DiscoverInstances and FetchInspectorFindings |
| **Fleet Manager** | Systems Manager → Fleet Manager | Instances show "Managed" status |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/variables.tf` | `variable "check_ssm_agent_health"` (default: true) |
| `terraform/modules/patch-workflow/main.tf` | `aws_lambda_function.ssm_agent_health` |
| `terraform/modules/patch-workflow/main.tf` | Step Functions `CheckSSMAgentHealth` state |
| `terraform/modules/patch-workflow/lambda/ssm_agent_health.py` | `_get_managed_instance_ids()` – `DescribeInstanceInformation`, filter `PingStatus=Online` |
| `terraform/main.tf` | `check_ssm_agent_health = var.check_ssm_agent_health` |

---

## 8. Canary / Phased Rollout

### What It Does

When `canary_batch_size` > 0, the first batch patches fewer instances (e.g. 1–2). Remaining batches use `batch_size`. Reduces risk by validating patches on a small subset first.

### How It Works

- **Batch Prepare Lambda** – If `canary_batch_size` > 0 and instance count > canary size, first batch = `instances[:canary_batch_size]`, remaining = `instances[canary_batch_size:]` split by `batch_size`.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **Step Functions execution** | Step Functions → Executions | With `canary_batch_size=2`, first RHEL/Windows batch has 2 instances; subsequent batches use `batch_size` |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/variables.tf` | `variable "canary_batch_size"` (default: 0) |
| `terraform/modules/patch-workflow/main.tf` | `canary_batch_size = var.canary_batch_size` in PrepareBatches payload |
| `terraform/modules/patch-workflow/lambda/batch_prepare.py` | `canary_batch_size` logic – first batch vs remaining batches |
| `terraform/main.tf` | `canary_batch_size = var.canary_batch_size` |
| `tests/test_batch_prepare.py` | `test_batch_prepare_canary` |

---

## 9. Batched Patching

### What It Does

Instances are patched in batches (default 10) instead of all at once. Reduces blast radius and allows failure detection between batches.

### How It Works

- **Batch Prepare Lambda** – Splits instance IDs into batches of `batch_size`.
- **Step Functions Map** – Iterates over batches; each batch: Patch → Wait 180s → Failure Check.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **Step Functions execution** | Step Functions → Executions | Map state shows multiple batches; each batch runs sequentially |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/variables.tf` | `variable "batch_size"` (default: 10) |
| `terraform/modules/patch-workflow/main.tf` | `batch_size = var.batch_size` in PrepareBatches |
| `terraform/modules/patch-workflow/main.tf` | Map states `MapRHELBatches`, `MapWindowsBatches` with `ItemsPath` = batches |
| `terraform/modules/patch-workflow/lambda/batch_prepare.py` | `batches = [instance_ids[i:i+batch_size] for ...]` |

---

## 10. Failure Detection (Within Run)

### What It Does

After each batch, the workflow waits 180 seconds, then the Failure Check Lambda verifies that recently patched instances are still running. If any are `stopped`, the workflow fails and remaining batches are not executed.

### How It Works

- **Failure Check Lambda** – Queries `patch_executions` for recent patches, then `ec2:DescribeInstances` for those instance IDs. If any are `stopped`, returns `abort: true`.
- **Step Functions Choice** – If `abort=true`, transitions to Fail state; otherwise continues to next batch.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **Failure Check Lambda** | Lambda → Functions → `aiops-r8-failure-check` | Env vars: `PATCH_EXECUTIONS_TABLE`, `PATCH_CORRELATION_MINUTES` |
| **Step Functions** | Step Functions → State machines → `aiops-r8-patch-workflow` | Each batch: `WaitAfterRHELBatch` (180s) → `CheckRHELFailure` → `ChoiceRHELAbort` |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/main.tf` | `WaitAfterRHELBatch`, `WaitAfterWindowsBatch` – `Seconds = 180` |
| `terraform/modules/patch-workflow/main.tf` | `CheckRHELFailure`, `CheckWindowsFailure` – invoke `failure_check` |
| `terraform/modules/patch-workflow/main.tf` | `ChoiceRHELAbort`, `ChoiceWindowsAbort` – `$.failureCheck.Payload.body.abort` |
| `terraform/modules/patch-workflow/lambda/failure_check.py` | Queries `patch_executions`, `ec2.describe_instances`; returns `abort` |

---

## 11. Patch Scope (RHEL – Security Only)

### What It Does

RHEL patching uses `dnf update --security -y` (or `yum update --security -y`), so only security updates are applied—no feature or non-security updates.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **Step Functions** | Step Functions → State machines → `aiops-r8-patch-workflow` | ApplyPatches payload: `"commands": ["sudo dnf update --security -y || sudo yum update --security -y"]` |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/main.tf` | MapRHELBatches parameters: `"commands" = ["sudo dnf update --security -y \|\| sudo yum update --security -y"]` |

---

## 12. Patch Baseline (Windows – CVE Only)

### What It Does

Windows uses an SSM Patch Baseline that allows only SecurityUpdates and CriticalUpdates, with `enable_non_security=false`. MSRC severity limited to Critical and Important.

### How It Works

- **Patch Baseline** – `aws_ssm_patch_baseline.windows_cve` with `CLASSIFICATION=SecurityUpdates,CriticalUpdates`, `enable_non_security=false`, `MSRC_SEVERITY=Critical,Important`.
- **Patch Group** – Windows instances must have `PatchGroup=aiops-r8-windows-cve` to use this baseline.

### Verify on AWS Console

| Resource | Path | What to Check |
|----------|------|---------------|
| **Patch Baseline** | Systems Manager → Patch Manager → Patch baselines | `aiops-r8-windows-cve-baseline` exists; approval rules show SecurityUpdates, CriticalUpdates; enable_non_security = false |
| **Patch Group** | Systems Manager → Patch Manager → Patch groups | `aiops-r8-windows-cve` linked to baseline |
| **EC2 instance** | EC2 → Instances → Tags | Windows instances have `PatchGroup` = `aiops-r8-windows-cve` |

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/main.tf` | `aws_ssm_patch_baseline.windows_cve` – `enable_non_security = false`, `CLASSIFICATION`, `MSRC_SEVERITY` |
| `terraform/modules/patch-workflow/main.tf` | `aws_ssm_patch_group.windows` |
| `terraform/main.tf` | EC2 Windows module: `PatchGroup = "aiops-r8-windows-cve"` (or equivalent) |

---

## 13. Reboot Behavior (Windows)

### What It Does

Windows patching uses `RebootOption=RebootIfNeeded`, so instances reboot when required by patches. The 180s wait and Failure Check detect boot failures.

### Verify in Terraform

| File | Resource / Location |
|------|---------------------|
| `terraform/modules/patch-workflow/main.tf` | ApplyPatches Windows parameters: `"RebootOption" = "RebootIfNeeded"` |
| `terraform/modules/patch-workflow/lambda/batch_prepare.py` | `{"Operation": "Install", "RebootOption": "RebootIfNeeded"}` |

---

## Quick Reference: All Variables

| Variable | Default | Terraform Location |
|----------|---------|-------------------|
| `check_maintenance_window` | `true` | `terraform/modules/patch-workflow/variables.tf` |
| `maintenance_start_hour_utc` | `2` | `terraform/modules/patch-workflow/variables.tf` |
| `maintenance_end_hour_utc` | `6` | `terraform/modules/patch-workflow/variables.tf` |
| `check_ssm_agent_health` | `true` | `terraform/modules/patch-workflow/variables.tf` |
| `canary_batch_size` | `0` | `terraform/modules/patch-workflow/variables.tf` |
| `dry_run` | `false` | `terraform/variables.tf` |
| `create_prepatch_ami` | `true` | `terraform/modules/patch-workflow/variables.tf` |
| `batch_size` | `10` | `terraform/modules/patch-workflow/variables.tf` |
| `cve_block_ttl_days` | `7` | `terraform/modules/patch-workflow/variables.tf` |
| `patch_correlation_minutes` | `45` | `terraform/modules/patch-workflow/variables.tf` |
| `enable_auto_recovery` | `false` | `terraform/modules/patch-workflow/variables.tf` |

---

## Verification Commands (CLI)

```bash
# Terraform: validate configuration
cd terraform && terraform validate

# Terraform: list all resources
terraform state list

# DynamoDB: circuit-breaker table
aws dynamodb describe-table --table-name aiops-r8-prod-cve-patch-failures

# EventBridge: EC2 stopped rule
aws events describe-rule --name aiops-r8-prod-ec2-stopped-rule

# Lambda: list functions
aws lambda list-functions --query "Functions[?contains(FunctionName,'aiops-r8')].FunctionName" --output table

# SSM: patch baselines
aws ssm describe-patch-baselines --filters "Key=NAME_PREFIX,Value=aiops-r8"
```
