# AIOps R8: Production-Safe CVE Patching
## Presentation Guide

---

## Slide 1: Title & Overview

# AIOps R8 – Production-Safe CVE Patching

**Automated CVE patching for RHEL8 and Windows using AWS + AI**

- **Amazon Inspector v2** – Vulnerability scanning
- **Amazon Bedrock** (Nova 2 Lite) – AI-driven patch decisions
- **Step Functions** – Workflow orchestration
- **EventBridge Scheduler** – EDT timezone support
- **CVE-only** – Security updates only, production-safe

*One sentence: Patch critical CVEs automatically and safely, using structured data and AI to decide when to act.*

---

## Slide 2: The Problem

| Pain Point | Impact |
|------------|--------|
| **Manual patching** | Error-prone, doesn't scale |
| **Blind automation** | Unnecessary risk, non-critical updates |
| **Custom pre-patch scripts** | Inconsistent, hard to maintain |
| **When to patch?** | Need smart, data-driven decisions |

**Goal:** Automation that is both **safe** and **smart** – only patch when there are critical CVEs.

---

## Slide 3: The Solution – End-to-End Flow

```
EventBridge Scheduler (EDT) → Step Functions
    → 1. Discover instances (Lambda)
    → 2. Check SSM Agent health (Lambda)
    → 3. Fetch Inspector findings (Lambda)
    → 4. Analyze with Bedrock (Lambda) → has_critical_cves?
    → 5. Choice: Critical CVEs? → Apply patches | Skip
    → 6. Apply patches (batched, parallel RHEL + Windows via SSM)
       • Circuit-breaker: pre-patch check for blocked CVEs
       • Pre-patch AMI creation for recovery
    → 7. Post-patch verification (Parallel)
```

**Circuit-breaker:** EC2 stopped → record CVE failure → block future patches for 7 days.

---

## Slide 4: Architecture – Key Components

| Layer | Components |
|-------|-------------|
| **Schedule** | EventBridge Scheduler (America/New_York) |
| **Orchestration** | Step Functions state machine |
| **Data** | Amazon Inspector v2 (CVE findings) |
| **AI** | Bedrock Nova 2 Lite (patch/no-patch decision) |
| **Execution** | SSM Runner Lambda → Systems Manager |
| **Safety** | Circuit-breaker (DynamoDB, EC2 Stopped Handler) |
| **Alerts** | SNS patch-alerts topic |

**11 Lambda functions** – Instance discovery, Inspector, CVE analyzer, SSM runner, batch prepare, failure check, EC2 stopped handler, AMI cleanup, SFN failure notifier.

---

## Slide 5: Inspector + Bedrock – AI in the Loop

**Inspector** → Structured CVE findings (severity, CVE IDs, affected packages)

**Bedrock** (`us.amazon.nova-2-lite-v1:0`) → Analyzes findings, returns:
- `has_critical_cves` (true/false)
- Recommendations

**Decision:** If `false` → Skip patching (NotifyNoPatch)  
**Decision:** If `true` → Apply patches in parallel

*No hard-coded severity thresholds – the model considers context.*

---

## Slide 6: Circuit-Breaker – Production Safety

**Problem:** A CVE patch causes instance to fail reboot → cascading failures if we keep patching.

**Solution:**

| Within same run | Across future runs |
|-----------------|-------------------|
| Batched patching (e.g., 10/batch) | EC2 stopped → EC2 Stopped Handler |
| After each batch: wait 180s → Failure Check | Records CVE in `cve-patch-failures` |
| If any instance stopped → abort remaining batches | SSM Runner checks before patching |
| | If CVE blocked → skip + SNS alert |

**Config:** `CVE_BLOCK_TTL_DAYS` (7), `PATCH_CORRELATION_MINUTES` (45)

---

## Slide 7: CVE-Only Patching (Production-Safe)

| Platform | Command / Method |
|----------|------------------|
| **RHEL8** | `dnf update --security -y` |
| **Windows** | Patch Baseline: SecurityUpdates, CriticalUpdates only; `enable_non_security=false` |

**No** feature updates, **no** optional packages – only CVE-related patches.

---

## Slide 8: Schedule & Triggers

| Type | Details |
|------|---------|
| **Scheduled** | EventBridge Scheduler – `cron(15 19 12 3 ? 2026)` |
| **Timezone** | `America/New_York` (EDT/EST) |
| **Manual** | `aws stepfunctions start-execution --state-machine-arn <ARN> --input '{}'` |

Aligns with Patch Tuesday (1st Tuesday) – 2nd Tuesday gives time for testing.

---

## Slide 9: Infrastructure as Code

**Terraform** – Single `terraform apply` deploys full stack.

| Module | Contents |
|--------|----------|
| **VPC** | Subnets, NAT, security groups |
| **EC2 RHEL8** | 2 × free tier RHEL8 |
| **EC2 Windows** | 2 × free tier Windows Server 2022 |
| **Patch Workflow** | Lambdas, Step Functions, EventBridge Scheduler, DynamoDB, SNS, Inspector enabler |

---

## Slide 10: Report Locations

| Platform | Scan Report | Post-Patch Report |
|----------|-------------|-------------------|
| **RHEL8** | `/var/log/aiops/rhel8_scan_report.txt` | `/var/log/aiops/post_patch_report.txt` |
| **Windows** | `C:\aiops\reports\windows_scan_report.txt` | `C:\aiops\reports\post_patch_report.txt` |

---

## Slide 11: Key Takeaways

1. **Inspector + Bedrock + SSM** – Scan, decide, execute
2. **CVE-only patching** – Production-safe, security-focused
3. **AI-gated** – Patch only when Bedrock says critical CVEs exist
4. **Circuit-breaker** – Halt on reboot failure; prevent cascading failures
5. **Pre-patch AMIs** – Recovery option; daily cleanup
6. **EDT timezone** – EventBridge Scheduler with America/New_York
7. **Infrastructure as Code** – Terraform for full stack

---

## Slide 12: Q&A / Demo

**Demo ideas:**
- Step Functions execution in AWS Console
- Inspector findings filtered by VPC
- Bedrock analysis in CVE Analyzer Lambda logs
- Post-patch report on an instance

**Common questions:**
- *Exclude instances?* Tag with `PatchExcluded=true`
- *Multi-account?* Inspector supports delegated admin; workflow needs per-account deployment
