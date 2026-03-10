# AWS Lambda: Inspector Findings, CVE Analyzer, and SSM Runner

This project uses three Lambda functions: **Inspector Findings** (fetches CVE data), **CVE Analyzer** (Bedrock integration), and **SSM Runner** (SSM command execution).

---

## Inspector Findings Lambda (`aiops-r8-inspector-findings`)

**Purpose:** Fetches CVE findings from Amazon Inspector v2 for EC2 instances in the project VPC.

**Flow:** Step Functions → Inspector Findings Lambda → Inspector ListFindings → return structured findings

**Used for:** CVE scan data (replaces SSM pre-patch scans)

**Input:** `vpc_id`, `rhel8_ids`, `windows_ids` (optional)

**Output:** `findingsCount`, `findings` (severity, CVE IDs, affected packages), `rawFindingsCount`

---

## SSM Runner Lambda (`aiops-r8-ssm-runner`)

**Purpose:** Runs SSM commands and waits for completion. Step Functions has no native `ssm:sendCommand.sync` integration, so this Lambda provides synchronous SSM execution.

**Flow:** Step Functions → SSM Runner Lambda → SSM SendCommand → poll until done → return output

**Used for:** Apply patches, post-patch verification (no longer used for pre-patch scans)

---

## CVE Analyzer Lambda (`aiops-r8-cve-analyzer`)

### What "CVE Analysis Orchestration" Means

**Orchestration** = coordinating the steps that lead to CVE analysis.

The Lambda function (Amazon Inspector flow):

1. **Receives** Inspector findings from Step Functions (from Inspector Findings Lambda)
2. **Extracts** context from the findings (severity, CVE IDs, packages)
3. **Sends** the data to Bedrock (`us.amazon.nova-2-lite-v1:0`)
4. **Returns** `has_critical_cves` (true/false) and recommendations to Step Functions

It doesn't perform the analysis itself—it runs the flow that makes the analysis happen.

---

## What "Bedrock Integration" Means

**Integration** = connecting Step Functions to Bedrock.

- Step Functions cannot call Bedrock directly (no native integration)
- Lambda can call Bedrock via the AWS SDK
- Lambda acts as the bridge: Step Functions → Lambda → Bedrock

---

## What the Lambda Actually Does (Amazon Inspector Flow)

| Action | What Happens |
|--------|--------------|
| **`analyze`** | Receives Inspector findings (findingsCount, findings), extracts context, sends to Bedrock. Returns `has_critical_cves` and recommendations. Drives the Choice state (skip patching if no critical CVEs). |

---

## Flow Diagram (Amazon Inspector)

```
Step Functions                    Lambda                         Bedrock
      │                              │                               │
      │  Inspector findings           │                               │
      │  (severity, CVE IDs, etc.)    │                               │
      │─────────────────────────────►│                               │
      │                              │  CVE findings data              │
      │                              │──────────────────────────────►│
      │                              │                               │
      │                              │  has_critical_cves + recs      │
      │                              │◄──────────────────────────────│
      │  Analysis result             │                               │
      │◄─────────────────────────────│                               │
```

---

## Why Lambda Instead of Calling Bedrock Directly?

- Step Functions has no native Bedrock integration
- Lambda can use the Bedrock SDK and handle the request/response
- Lambda can add logic (retries, validation, formatting) before and after the Bedrock call

**In short:** *Orchestration* = running the analysis workflow; *Bedrock integration* = Lambda being the component that talks to Bedrock.

---

## What Is in a CVE Context?

**CVE context** is the data passed to Bedrock so it can analyze vulnerabilities and recommend actions.

### What This Project Sends (Amazon Inspector)

- **Instance IDs** – RHEL8 and Windows instance IDs
- **Inspector findings** – Severity, CVE IDs, affected packages, descriptions
- **Findings count** – Number of active findings

### Where This Data Comes From

- **Amazon Inspector v2** – `inspector2:ListFindings` with filters (VPC ID, EC2, ACTIVE)
- **Inspector Findings Lambda** – Summarizes findings for Bedrock

---

## Usual Recommendations from CVE Analysis

Typical recommendations produced after CVE analysis (including what Bedrock is prompted to generate in this project) usually fall into these categories:

### 1. Patch Prioritization

| Recommendation | Description |
|----------------|-------------|
| **Patch immediately** | Critical CVEs with known exploits; aim for 24–48 hours |
| **Patch in next maintenance window** | High severity, no known exploit; schedule in normal window |
| **Patch when convenient** | Medium/low severity; low risk |
| **Defer or skip** | Not applicable to your environment, or compensating controls in place |

### 2. Maintenance Window Guidance

- **Suggested time** – e.g., 2–4 AM local, low-traffic period
- **Suggested day** – e.g., Tuesday–Thursday, avoid Fridays
- **Reboot strategy** – when to reboot, batch order, impact on services

### 3. Pre-Patch Checklist

- Create snapshots/backups
- Notify stakeholders
- Put monitoring/alerting in place
- Run pre-patch scan and save results
- Check for dependencies or conflicts
- Review rollback plan

### 4. Post-Patch Verification

- Confirm patches installed (e.g., `rpm -qa`, `Get-HotFix`)
- Check for remaining security updates
- Verify services and applications
- Monitor logs for errors
- Document what was patched and when

### 5. Risk and Impact

- **Exploitability** – known exploits, PoC, or active use
- **Blast radius** – which systems and services are affected
- **Compatibility** – possible breaking changes or known issues

### 6. Alternative Mitigations

When patching is not possible:

- Network segmentation or firewall rules
- Disabling affected features
- Temporary workarounds
- Timeline for applying patches later

### 7. Compliance and Audit

- Mapping to compliance requirements (PCI, HIPAA, SOC2, etc.)
- Suggested evidence for audits
- Retention of scan and patch records

---

### What This Project's Lambda Asks For

From the Lambda prompt:

> Provide:
> 1. Summary of CVE patches that should be applied (security/critical only)
> 2. Recommended patch window (maintenance window)
> 3. Pre-patch checklist items
> 4. Post-patch verification steps

So the usual recommendations in this project are: **what to patch**, **when to patch**, **what to do before patching**, and **what to do after patching**.
