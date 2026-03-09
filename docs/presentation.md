# AIOps R8: Production-Safe CVE Patching
## Presentation Guide

---

## Slide 1: Title & Overview

**AIOps R8 – Production-Safe CVE Patching with AWS Lambda, Inspector, and Bedrock**

- Automated CVE patching for **RHEL8** and **Windows** servers
- Uses **Amazon Inspector v2** for vulnerability scanning
- Uses **Bedrock** (Amazon Nova 2 Lite) for AI-driven patch decisions
- Orchestrated by **Step Functions**, triggered by **EventBridge**
- **CVE-only** patching – security updates only, production-safe

**Talking point:** This project combines AWS security services with generative AI to automate and intelligently gate CVE patching.

---

## Slide 2: The Problem

- **Manual patching** is error-prone and doesn’t scale
- **Blind automation** can apply non-critical updates and cause unnecessary risk
- **Pre-patch scans** via custom scripts are inconsistent and hard to maintain
- Need a way to **decide when to patch** based on severity and context

**Talking point:** We wanted automation that is both safe and smart – only patch when there are critical CVEs, and use structured data instead of ad-hoc scripts.

---

## Slide 3: The Solution – High-Level Flow

```
EventBridge (monthly) → Step Functions
    → 1. Fetch Inspector findings (Lambda)
    → 2. Analyze with Bedrock (Lambda)
    → 3. Choice: Critical CVEs? → Apply patches | Skip
    → 4. Apply patches (Parallel: RHEL + Windows via SSM)
       - Circuit-breaker: pre-patch check for blocked CVEs
       - Pre-patch AMI creation for recovery
    → 5. Post-patch verification (Parallel)

Circuit-breaker: EC2 stopped → record CVE failure → block future patches
AMI cleanup: Daily deregister old pre-patch AMIs
```

**Talking point:** Inspector provides the data, Bedrock provides the decision, SSM provides the execution. Circuit-breaker prevents cascading failures; pre-patch AMIs enable recovery.

---

## Slide 4: Architecture – Key Components

| Component | Role |
|-----------|------|
| **Amazon Inspector v2** | Discovers EC2 instances, scans for CVEs, stores structured findings |
| **Inspector Findings Lambda** | Fetches findings from Inspector (ListFindings API), filters by VPC |
| **CVE Analyzer Lambda** | Sends findings to Bedrock, returns `has_critical_cves` + `critical_cve_ids` |
| **Step Functions** | Orchestrates workflow, Choice state gates patching |
| **SSM Runner Lambda** | Invokes SSM Run Command; circuit-breaker pre-check; creates pre-patch AMIs |
| **EC2 Stopped Handler Lambda** | Circuit-breaker: records CVE failures when instance stops; optional recovery |
| **AMI Cleanup Lambda** | Daily cleanup of old pre-patch AMIs (retention policy) |
| **Systems Manager** | Runs `dnf update --security` (RHEL) and Patch Baseline (Windows) |
| **Bedrock** | Analyzes CVE severity, returns patch/no-patch recommendation |
| **DynamoDB** | `cve-patch-failures`, `patch-executions` for circuit-breaker |
| **SNS** | Patch alerts when CVE is blocked |

**Talking point:** Five Lambdas – Inspector, CVE Analyzer, SSM Runner, EC2 Stopped Handler, AMI Cleanup. DynamoDB and SNS support the circuit-breaker.

---

## Slide 5: Amazon Inspector – Why It Replaces Pre-Patch Scripts

| Aspect | SSM Pre-Patch Scripts | Amazon Inspector |
|--------|----------------------|------------------|
| Scan source | Commands on each instance | AWS-managed service |
| Data format | Raw command output | Structured (severity, CVE IDs, packages) |
| Maintenance | Custom SSM documents | None – Inspector handles it |
| Coverage | Per-instance | EC2, ECR, Lambda (we use EC2) |
| Consistency | Varies by OS/script | Unified CVE database |

**Talking point:** Inspector discovers workloads automatically. No manual registration, no custom scan scripts. Enable it for EC2 and it scans everything in the account.

---

## Slide 6: AI in the Loop – Bedrock’s Role

- **Input:** Inspector findings (severity, CVE IDs, affected packages)
- **Model:** `us.amazon.nova-2-lite-v1:0` (Amazon Nova 2 Lite)
- **Output:** `has_critical_cves` (true/false) + recommendations
- **Decision:** If `false` → skip patching (NotifyNoPatch)
- **Decision:** If `true` → apply patches in parallel

**Talking point:** Bedrock interprets the CVE data and decides. We don’t hard-code severity thresholds – the model can consider context. The `has_critical_cves` flag drives the Step Functions Choice state.

---

## Slide 7: CVE-Only Patching (Production-Safe)

- **RHEL8:** `dnf update --security -y` – security updates only
- **Windows:** Patch Baseline with `CLASSIFICATION=SecurityUpdates,CriticalUpdates`, `enable_non_security=false`
- No feature updates, no optional packages – only CVE-related patches

**Talking point:** We patch only what’s needed for security. This reduces risk of breaking changes from non-security updates.

---

## Slide 8: Schedule & Triggers

- **EventBridge:** `cron(0 2 ? * 3#2 *)` – 2:00 AM UTC on the **2nd Tuesday** of each month
- Aligns with **Patch Tuesday** (1st Tuesday) – gives time for testing
- **Manual trigger:** `aws stepfunctions start-execution --state-machine-arn <ARN> --input '{}'`

**Talking point:** Monthly cadence keeps systems current without constant churn. Manual runs are supported for urgent cases.

---

## Slide 9: Report Locations

| Platform | Post-Patch Report |
|----------|-------------------|
| RHEL8 | `/var/log/aiops/post_patch_report.txt` |
| Windows | `C:\aiops\reports\post_patch_report.txt` |

Reports include remaining security updates and last applied patches.

**Talking point:** Each instance gets a local report for audit and troubleshooting.

---

## Slide 10: Cost Overview

| Scale | Patch Workflow (excl. EC2) | With EC2 |
|-------|----------------------------|----------|
| 4 nodes | ~$5–20/month | ~$50–200/month |
| 1000 nodes | ~$50–200/month | Dominated by EC2 (~$12K–50K/month) |

- Lambda, Step Functions, Bedrock: low cost
- Inspector: scales with findings
- SSM: ~$0.005/instance/month

**Talking point:** The orchestration layer is cheap. EC2 and Inspector drive most of the cost at scale.

---

## Slide 11: Where Are Patch Decisions Stored?

- **Step Functions execution history** – full input/output for each run
- **CloudWatch Logs** – Lambda invocation logs
- **DynamoDB** – `cve-patch-failures` (blocked CVEs), `patch-executions` (patch tracking for circuit-breaker)
- **SNS** – Alerts when CVE patching is blocked

**Talking point:** Circuit-breaker uses DynamoDB for failure tracking. Step Functions history plus DynamoDB provide audit trail.

---

## Slide 12: Infrastructure as Code

- **Terraform** for all AWS resources
- **Modules:** VPC, EC2 (RHEL8 + Windows), Patch Workflow (Lambdas, Step Functions, EventBridge)
- **Inspector:** Enabled via `aws_inspector2_enabler` (EC2)
- **Single `terraform apply`** deploys the full stack

**Talking point:** Everything is reproducible. New environments are a Terraform run away.

---

## Slide 13: Key Takeaways

1. **Inspector + Bedrock + SSM** – scan, decide, execute
2. **CVE-only patching** – production-safe, security-focused
3. **AI-gated** – patch only when Bedrock says there are critical CVEs
4. **Circuit-breaker** – halt patching when a CVE caused reboot failure; prevent cascading failures
5. **Pre-patch AMIs** – created before patching; optional auto-recovery; daily cleanup
6. **Parallel execution** – RHEL and Windows patched concurrently
7. **Infrastructure as Code** – Terraform for full stack

---

## Slide 14: Q&A / Demo

**Demo ideas:**
- Show Step Functions execution in AWS Console
- Show Inspector findings filtered by VPC
- Show Bedrock analysis in CVE Analyzer Lambda logs
- Show post-patch report on an instance

**Common questions:**
- *Can we exclude instances?* Yes – tag with `InspectorEc2Exclusion`
- *What if Bedrock is wrong?* You can override by manually triggering and the model can be tuned
- *Multi-account?* Inspector supports delegated admin; workflow would need per-account deployment

---

## Appendix: Quick Reference

### Lambda Functions
- `aiops-r8-inspector-findings` – Fetches Inspector findings
- `aiops-r8-cve-analyzer` – Bedrock analysis
- `aiops-r8-ssm-runner` – SSM Run Command (circuit-breaker, pre-patch AMIs)
- `aiops-r8-ec2-stopped-handler` – Circuit-breaker failure detection; optional recovery
- `aiops-r8-ami-cleanup` – Daily AMI retention cleanup

### Step Functions States
1. FetchInspectorFindings  
2. AnalyzeCVEs  
3. CheckCriticalCVEs (Choice)  
4. ApplyPatches (Parallel) / NotifyNoPatch  
5. PostPatch (Parallel)

### Prerequisites
- AWS account with EC2, Lambda, Step Functions, EventBridge, SSM, Bedrock, Inspector
- Bedrock model `us.amazon.nova-2-lite-v1:0` enabled
- SSM Agent on instances
- Inspector v2 enabled for EC2 (Terraform does this)
