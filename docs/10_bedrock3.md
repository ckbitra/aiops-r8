# Bedrock vs. Inspector/SSM: Who Does What in the Patch Workflow

## Overview

**SSM applies the patches.** Bedrock only analyzes and recommends. **Amazon Inspector** provides CVE findings. They work together: Inspector provides scan data; Bedrock provides intelligence; SSM provides execution.

## Summary Table (Amazon Inspector Flow)

| Step | Component | Role |
|------|-----------|------|
| 1. Fetch Inspector findings | **Inspector Findings Lambda → Inspector** | Lambda fetches CVE findings for EC2 in VPC |
| 2. Analyze | **CVE Analyzer Lambda + Bedrock** | Sends Inspector findings to Bedrock; returns has_critical_cves + recommendations |
| 3. Choice | **Step Functions** | If critical CVEs → apply; else → skip |
| 4. Apply patches | **SSM Runner Lambda → SSM** | Parallel: `dnf update --security` (RHEL) and `AWS-RunPatchBaseline` (Windows) |
| 5. Post-patch | **SSM Runner Lambda → SSM** | Parallel: Verification on RHEL8 and Windows |

---

## Detailed Explanation of Each Step

### Step 1: Fetch Inspector Findings (Inspector Findings Lambda → Inspector)

**What it does:** Step Functions invokes the Inspector Findings Lambda, which calls `inspector2:ListFindings` with filters (VPC ID, EC2, ACTIVE). Inspector returns CVE findings for EC2 instances in the project VPC. The Lambda summarizes findings (severity, CVE IDs, affected packages) and returns them to Step Functions.

**Why Lambda:** Step Functions has no native Inspector integration; the Lambda fetches and formats findings.

**Output:** Structured findings (findingsCount, findings) passed to the CVE Analyzer.

---

### Step 2: Analyze (Lambda + Bedrock)

**What it does:** Lambda receives Inspector findings, sends them to Bedrock (`us.amazon.nova-2-lite-v1:0`), and returns a structured response including `has_critical_cves` (true/false) and recommendations.

**Why Bedrock:** Bedrock analyzes the CVE data and determines whether critical patches need to be applied. The `has_critical_cves` flag drives the Choice state—if false, the workflow skips patching.

**Output:** `has_critical_cves`, `bedrock_analysis`, and `recommendation`.

---

### Step 3: Choice (Step Functions)

**What it does:** Step Functions evaluates `has_critical_cves` from the Lambda/Bedrock response. If true, it proceeds to ApplyPatches. If false, it goes to NotifyNoPatch and skips patching.

**Output:** Routes to either ApplyPatches or NotifyNoPatch.

---

### Step 4: Apply Patches (SSM Runner Lambda → SSM) – Parallel

**What it does:** Step Functions invokes the SSM Runner Lambda in parallel for RHEL8 and Windows. The Lambda calls SSM to apply patches.

- **RHEL8:** Uses `AWS-RunShellScript` to run `dnf update --security -y` (or `yum update --security -y`).
- **Windows:** Uses `AWS-RunPatchBaseline` with a CVE-focused patch baseline.

**Why parallel:** Reduces total workflow time.

**Output:** Patches installed on all instances.

---

### Step 5: Post-patch (SSM Runner Lambda → SSM) – Parallel

**What it does:** Step Functions invokes the SSM Runner Lambda in parallel. The Lambda calls SSM to run post-patch verification on both RHEL8 and Windows. On RHEL8, it checks for remaining security updates. On Windows, it confirms verification.

**Why parallel:** Both platforms are verified at the same time.

**Output:** Verification reports on each instance.

---

## Why This Division of Labor?

| Capability | Bedrock | Inspector | SSM |
|------------|---------|-----------|-----|
| Run commands on EC2 | No | No | Yes |
| Access instance filesystem | No | No | Yes |
| Scan EC2 for CVEs | No | Yes | No |
| Interpret CVE text | Yes | No | No |
| Produce natural-language recommendations | Yes | No | No |
| Apply packages/updates | No | No | Yes |

Bedrock is a cloud service that processes text; it does not have agents or direct access to your instances. Inspector scans EC2 for vulnerabilities. SSM is designed for systems management and has the agent and permissions to run commands. Together, Inspector provides scan data, Bedrock handles analysis, and SSM handles execution.
