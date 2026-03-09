# Component Explanations

## AWS Services Used

### 1. Amazon EC2

**Purpose**: Hosts RHEL8 and Windows servers that receive CVE patches.

- **RHEL8 x2**: Free tier eligible (t2.micro), Red Hat AMI
- **Windows x2**: Free tier eligible (t2.micro), Windows Server 2022
- **Tagging**: `Project`, `Environment`, `OS`, `Role`, `PatchGroup` (Windows)
- **SSM Managed**: Instances use IAM instance profiles for SSM Agent

### 2. Amazon Inspector v2

**Purpose**: Automated vulnerability scanning for EC2 instances.

- **Enabled via Terraform**: `aws_inspector2_enabler` enables Inspector for EC2 at the account level
- **Scanning**: Inspector automatically scans EC2 instances for CVEs
- **Findings**: Fetched by the Inspector Findings Lambda via `inspector2:ListFindings`
- **Filtering**: Findings are filtered by VPC ID to scope to project instances

### 3. AWS Lambda

**Purpose**: Ten Lambda functions support the patch workflow.

- **`aiops-r8-instance-discovery`**: Discovers EC2 instances by tags (Role=patch-target); excludes PatchExcluded
- **`aiops-r8-batch-prepare`**: Splits instance IDs into batches for batched patching
- **`aiops-r8-get-batch`**: Returns batch at index (for loop-based patching)
- **`aiops-r8-failure-check`**: Checks if recently patched instances have stopped
- **`aiops-r8-maintenance-window`**: Optional maintenance window check
- **`aiops-r8-inspector-findings`**: Fetches CVE findings from Amazon Inspector v2
  - **Actions**: Calls `inspector2:ListFindings` with filters (VPC ID, resource type, status)
  - **Permissions**: CloudWatch Logs, Inspector ListFindings
  - **Output**: Structured findings (severity, CVE IDs, affected packages) for Bedrock
- **`aiops-r8-cve-analyzer`**: CVE analysis orchestration and Bedrock integration
  - **Actions**: `analyze` (receives Inspector findings, sends to Bedrock, returns has_critical_cves + critical_cve_ids)
  - **Permissions**: CloudWatch Logs, Bedrock InvokeModel
- **`aiops-r8-ssm-runner`**: Runs SSM commands; circuit-breaker pre-check; pre-patch AMI creation
  - **Purpose**: Invokes SSM SendCommand, polls until done; checks cve_patch_failures before patching; creates AMIs
  - **Permissions**: CloudWatch Logs, SSM, DynamoDB, SNS, EC2 (create_image)
  - **Runtime**: Python 3.12
- **`aiops-r8-ec2-stopped-handler`**: Circuit-breaker failure detection; optional recovery
  - **Purpose**: When EC2 instance stops, checks if recently patched; records CVE(s) in cve_patch_failures; optionally launches replacement from AMI
  - **Permissions**: CloudWatch Logs, DynamoDB, EC2
- **`aiops-r8-ami-cleanup`**: Daily AMI retention cleanup
  - **Purpose**: Deregisters pre-patch AMIs (AI-Patch-*) older than retention days; deletes snapshots
  - **Permissions**: CloudWatch Logs, EC2 (DescribeImages, DeregisterImage, DeleteSnapshot)

### 4. Amazon Bedrock

**Purpose**: LLM-powered CVE analysis and recommendations.

- **Model**: `us.amazon.nova-2-lite-v1:0` (Amazon Nova 2 Lite)
- **Use**: Analyzes Inspector findings, recommends patch approach, pre/post checklist
- **Input**: Inspector CVE findings (severity, CVE IDs, affected packages)
- **Output**: Structured CVE analysis, recommendations, and has_critical_cves flag

### 5. Amazon EventBridge

**Purpose**: Scheduled triggering and event-driven actions.

- **`aiops-r8-patch-schedule`**: Monthly patch workflow
  - **Schedule**: `cron(0 2 ? * 3#2 *)` – 2:00 AM UTC on 2nd Tuesday of each month (after Patch Tuesday)
  - **Target**: Step Functions state machine
- **`aiops-r8-{env}-ec2-stopped-rule`**: Circuit-breaker – EC2 instance state change (stopped)
  - **Target**: EC2 Stopped Handler Lambda
- **`aiops-r8-{env}-ami-cleanup-schedule`**: Daily AMI cleanup
  - **Schedule**: `cron(0 3 ? * * *)` – 3:00 AM UTC daily
  - **Target**: AMI Cleanup Lambda

### 6. AWS Step Functions

**Purpose**: Orchestrates the patch workflow as a state machine.

- **States**: FetchInspectorFindings → AnalyzeCVEs → CheckCriticalCVEs (Choice) → ApplyPatches (Parallel) → PostPatch (Parallel)
- **Integrations**: Lambda (invoke) only—no native SSM sync; SSM operations go through the SSM Runner Lambda
- **Choice**: Skips patching if Bedrock returns has_critical_cves=false

### 7. AWS Systems Manager (SSM)

**Purpose**: Runs commands and documents on EC2 instances without SSH/RDP.

- **Invoked via**: SSM Runner Lambda (Step Functions has no native `ssm:sendCommand.sync` integration)
- **Run Command**: Executes shell/PowerShell on instances
- **Documents**: AWS-RunShellScript, AWS-RunPowerShellScript, AWS-RunPatchBaseline
- **Patch Manager**: Patch Baseline for Windows (CVE-only)
- **Patch Group**: `aiops-r8-windows-cve` – tags Windows instances

### 8. VPC & Networking

**Purpose**: Isolated network for patch targets.

- **VPC**: 10.0.0.0/16
- **Private Subnets**: EC2 instances (no direct internet)
- **NAT Gateway**: Outbound internet for SSM, yum, Windows Update
- **Security Group**: Egress only (SSM uses outbound HTTPS)

## Supporting Components

### DynamoDB

- **`{project}-{env}-cve-patch-failures`**: Stores CVE IDs that caused reboot failure (circuit-breaker block list)
- **`{project}-{env}-patch-executions`**: Tracks patch executions (instance_id, cve_ids, started_at) for correlation

### SNS

- **`{project}-{env}-patch-alerts`**: Topic for circuit-breaker alerts when CVE patching is skipped

### IAM Roles

- **EC2 Instance Profile**: `AmazonSSMManagedInstanceCore` for SSM Agent
- **Inspector Findings Lambda Role**: Logs + Inspector ListFindings
- **CVE Analyzer Lambda Role**: Logs + Bedrock
- **SSM Runner Lambda Role**: Logs + SSM, DynamoDB, SNS, EC2
- **EC2 Stopped Handler Lambda Role**: Logs + DynamoDB, EC2
- **AMI Cleanup Lambda Role**: Logs + EC2
- **Step Functions Role**: Lambda invoke (Inspector findings, CVE analyzer, SSM runner)
- **EventBridge Role**: Step Functions StartExecution

### Patch Baseline (Windows)

- **Name**: `aiops-r8-windows-cve-baseline`
- **Classification**: SecurityUpdates, CriticalUpdates
- **MSRC Severity**: Critical, Important
- **Non-security**: Disabled (`enable_non_security = false`)

---

## Circuit-Breaker

The circuit-breaker prevents cascading failures when a CVE patch causes an instance to fail to reboot. Without it, the workflow would continue patching other instances with the same CVE, potentially taking multiple nodes offline.

### Problem It Solves

If a CVE patch is applied and the node fails to reboot successfully, continuing to patch other nodes with the same CVE can cause cascading failures—multiple nodes going offline instead of just one.

### How It Works

**1. Within the same run (batched patching)**

- Instances are patched in batches (default 10 per batch).
- After each batch: Wait 180 seconds → Failure Check Lambda queries `patch_executions` and EC2 state.
- If any recently patched instance is `stopped`, the workflow fails that batch and transitions to NotifyFailure.
- Remaining batches are not executed.

**2. Across future runs**

| Step | Component | Action |
|------|------------|--------|
| Patch tracking | SSM Runner Lambda | Records `instance_id`, `cve_ids`, `started_at` in `patch_executions` when patching starts |
| Failure detection | EventBridge + EC2 Stopped Handler | When EC2 instance goes to `stopped`, Lambda checks if it was patched recently (within `PATCH_CORRELATION_MINUTES`, default 45). If yes, writes CVE(s) to `cve_patch_failures` |
| Pre-patch check | SSM Runner Lambda | Before sending any patch command, queries `cve_patch_failures` for `critical_cve_ids`. If a CVE is blocked (within `CVE_BLOCK_TTL_DAYS`, default 7), skips patching and sends SNS alert |

### Components Involved

| Component | Role |
|-----------|------|
| `aiops-r8-{env}-ec2-stopped-rule` | EventBridge rule on EC2 instance state `stopped` |
| `aiops-r8-ec2-stopped-handler` | Correlates stop with recent patch; records CVE(s) in `cve-patch-failures` |
| `aiops-r8-ssm-runner` | Pre-patch check; records to `patch_executions`; skips patching if CVE blocked |
| `aiops-r8-failure-check` | Detects stopped instances within same run; stops remaining batches |
| `{project}-{env}-cve-patch-failures` | DynamoDB table: block list of CVEs (PK: cve_id, SK: failed_at) |
| `{project}-{env}-patch-executions` | DynamoDB table: patch tracking for correlation (PK: instance_id, SK: started_at) |
| `{project}-{env}-patch-alerts` | SNS topic for alerts when patching is skipped |

### Configuration

| Environment Variable | Default | Purpose |
|----------------------|---------|---------|
| `CVE_BLOCK_TTL_DAYS` | 7 | Days to block a CVE after a failure |
| `PATCH_CORRELATION_MINUTES` | 45 | Window to correlate instance stop with recent patch |

To clear a block before TTL expires, delete the failure record from `cve-patch-failures` for that CVE.
