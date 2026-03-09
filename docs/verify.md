# AIOps R8 – Resource Verification Guide

How to verify each resource created by this project and ensure all required resources exist.

---

## Easiest Way to Check All Resources

**Run `terraform plan`** — if it reports "No changes. Your infrastructure matches the configuration", all required resources exist and are in sync:

```bash
cd terraform
terraform plan
```

For a quick count of resources in state: `terraform state list | wc -l` (expect 80–100+).

---

## Quick Check: Are All Resources Created?

### Option 1: Terraform Plan (Recommended)

```bash
cd terraform
terraform plan
```

- **Exit 0, "No changes"** → All resources exist and match the configuration.
- **Exit 0, "Plan: X to add, Y to change, Z to destroy"** → Some resources are missing or differ.
- **Exit 1** → Configuration or state error; fix before proceeding.

### Option 2: Terraform State List

```bash
cd terraform
terraform state list
```

Lists every resource in the state. Compare against expected resources (see [Resource Inventory](#resource-inventory) below). Missing items indicate resources not yet created.

### Option 3: Terraform Validate

```bash
cd terraform
terraform validate
```

Validates configuration syntax only (does not check if resources exist in AWS).

---

## Resource Inventory

| Module | Resource Type | Count | Naming Pattern |
|--------|---------------|-------|----------------|
| Root | Inspector2 Enabler | 1 | Account-level |
| VPC | VPC | 1 | `{project}-{env}-vpc` |
| VPC | Internet Gateway | 1 | `{project}-{env}-igw` |
| VPC | Public Subnet | 2 | `{project}-{env}-public-{1,2}` |
| VPC | Private Subnet | 2 | `{project}-{env}-private-{1,2}` |
| VPC | NAT Gateway | 1 | `{project}-{env}-nat` |
| VPC | Elastic IP | 1 | `{project}-{env}-nat-eip` |
| VPC | Route Tables | 2 | public, private |
| VPC | Security Group | 1 | `{project}-{env}-sg` |
| EC2 RHEL8 | Instance | 2 | `{project}-rhel8-{1,2}` |
| EC2 RHEL8 | IAM Role | 2 | `{project}-rhel8-{n}-ssm-role` |
| EC2 Windows | Instance | 2 | `{project}-windows-{1,2}` |
| EC2 Windows | IAM Role | 2 | `{project}-windows-{n}-ssm-role` |
| Patch Workflow | DynamoDB Tables | 3 | cve-patch-failures, patch-executions, patch-history |
| Patch Workflow | SNS Topic | 1 | patch-alerts |
| Patch Workflow | SSM Patch Baseline | 1 | windows-cve-baseline |
| Patch Workflow | Step Functions | 1 | patch workflow |
| Patch Workflow | EventBridge Rules | 3 | patch schedule, ec2 stopped, ami cleanup |
| Patch Workflow | Lambda Functions | 9 | cve_analyzer, ssm_runner, inspector_findings, etc. |

Default `project_name` = `aiops-r8`, `environment` = `prod`.

---

## Verification by Resource Type

### 1. Amazon Inspector v2

**Purpose:** EC2 vulnerability scanning for CVE detection.

| Method | Command / Action |
|--------|------------------|
| **CLI** | `aws inspector2 list-account-statuses --region <region>` |
| **Console** | Inspector → Settings → EC2 scanning should show "Enabled" |
| **Verify** | Status `ENABLED` for resource type `EC2` |

---

### 2. VPC & Networking

**Purpose:** Network foundation for EC2 instances (private subnets, NAT for outbound).

| Resource | How to Verify |
|----------|---------------|
| **VPC** | `aws ec2 describe-vpcs --filters "Name=tag:Project,Values=aiops-r8"` |
| **Subnets** | `aws ec2 describe-subnets --filters "Name=tag:Project,Values=aiops-r8"` — expect 4 (2 public, 2 private) |
| **Internet Gateway** | `aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=<vpc-id>"` |
| **NAT Gateway** | `aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=<vpc-id>"` — state should be `available` |
| **Security Group** | `aws ec2 describe-security-groups --filters "Name=group-name,Values=aiops-r8-prod-sg"` |

**Console:** VPC → Your VPCs → filter by tag `Project=aiops-r8`.

---

### 3. EC2 Instances (RHEL8 & Windows)

**Purpose:** Patch targets for CVE remediation.

| Resource | How to Verify |
|----------|---------------|
| **RHEL8 instances** | `aws ec2 describe-instances --filters "Name=tag:OS,Values=rhel8" "Name=instance-state-name,Values=running"` |
| **Windows instances** | `aws ec2 describe-instances --filters "Name=tag:OS,Values=windows" "Name=instance-state-name,Values=running"` |
| **All patch targets** | `aws ec2 describe-instances --filters "Name=tag:Role,Values=patch-target"` |

**Console:** EC2 → Instances → filter by tag `Role=patch-target`.

**Outputs:** `terraform output rhel8_instance_ids` and `terraform output windows_instance_ids`.

---

### 4. SSM (Systems Manager) – Managed Instances

**Purpose:** Instances must register with SSM for patch commands.

| Check | Command / Action |
|-------|------------------|
| **Managed instances** | `aws ssm describe-instance-information --region <region>` |
| **Filter by tag** | Check output for instances with `PlatformName` Linux/Windows and matching instance IDs |

**Console:** Systems Manager → Fleet Manager → Managed nodes.

**Note:** RHEL8 instances require SSM agent installed via `user_data` (not pre-installed on Red Hat AMIs). If RHEL8 nodes are missing, ensure the ec2-rhel8 module includes `user_data` to install the agent, then recreate the instances.

---

### 5. DynamoDB Tables

**Purpose:** Circuit-breaker (CVE failures), patch execution tracking, patch history.

| Table | Verify Command |
|-------|----------------|
| **cve-patch-failures** | `aws dynamodb describe-table --table-name aiops-r8-prod-cve-patch-failures` |
| **patch-executions** | `aws dynamodb describe-table --table-name aiops-r8-prod-patch-executions` |
| **patch-history** | `aws dynamodb describe-table --table-name aiops-r8-prod-patch-history` |

**Console:** DynamoDB → Tables → filter by `aiops-r8`.

---

### 6. SNS Topic (Patch Alerts)

**Purpose:** Circuit-breaker alerts when a CVE is blocked.

| Check | Command |
|-------|---------|
| **Topic exists** | `aws sns list-topics --query "Topics[?contains(TopicArn,'aiops-r8')]"` |
| **Subscriptions** | `aws sns list-subscriptions-by-topic --topic-arn <topic-arn>` (if `alert_email` is set) |

**Console:** SNS → Topics → `aiops-r8-prod-patch-alerts`.

---

### 7. SSM Patch Baseline (Windows)

**Purpose:** CVE/security-only patches for Windows.

| Check | Command |
|-------|---------|
| **Baseline** | `aws ssm describe-patch-baselines --filters "Key=NAME_PREFIX,Value=aiops-r8"` |
| **Patch group** | `aws ssm describe-patch-groups` — look for `aiops-r8-windows-cve` |

**Console:** Systems Manager → Patch Manager → Patch baselines.

---

### 8. Step Functions (Patch Workflow)

**Purpose:** Orchestrates the CVE analysis and patching workflow.

| Check | Command |
|-------|---------|
| **State machine** | `aws stepfunctions list-state-machines --query "stateMachines[?contains(name,'aiops-r8')]"` |
| **Recent executions** | `aws stepfunctions list-executions --state-machine-arn <arn>` |

**Console:** Step Functions → State machines → filter by `aiops-r8`.

**Output:** `terraform output patch_workflow_state_machine_arn`.

---

### 9. EventBridge Rules

**Purpose:** Schedule patch runs, react to EC2 stopped, trigger AMI cleanup.

| Rule | Purpose | Verify |
|------|---------|--------|
| **patch_schedule** | Cron for patch workflow | `aws events list-rules --name-prefix aiops-r8` |
| **ec2_stopped** | Circuit-breaker on instance stop | Same command |
| **ami_cleanup_schedule** | Periodic AMI cleanup | Same command |

**Console:** EventBridge → Rules → filter by `aiops-r8`.

---

### 10. Lambda Functions

**Purpose:** CVE analysis, Inspector findings, SSM runner, instance discovery, batch logic, failure check, maintenance window, EC2 stopped handler, AMI cleanup.

| Function | Purpose |
|----------|---------|
| `aiops-r8-cve-analyzer` | Bedrock CVE analysis |
| `aiops-r8-ssm-runner` | Run SSM patch commands |
| `aiops-r8-inspector-findings` | Fetch Inspector findings |
| `aiops-r8-instance-discovery` | Discover instances by tags |
| `aiops-r8-batch-prepare` | Prepare patch batches |
| `aiops-r8-get-batch` | Get batch details |
| `aiops-r8-failure-check` | Circuit-breaker failure check |
| `aiops-r8-maintenance-window` | Maintenance window check |
| `aiops-r8-ec2-stopped-handler` | Handle EC2 stopped events |
| `aiops-r8-ami-cleanup` | Clean up old AMIs |

**Verify all:**
```bash
aws lambda list-functions --query "Functions[?starts_with(FunctionName,'aiops-r8')].FunctionName" --output table
```

**Console:** Lambda → Functions → filter by `aiops-r8`.

---

### 11. IAM Roles

**Purpose:** Instance profiles for EC2 (SSM), execution roles for Lambda and Step Functions.

| Role Type | Naming Pattern | Verify |
|-----------|----------------|--------|
| **EC2 (RHEL8/Windows)** | `aiops-r8-{rhel8,windows}-{n}-ssm-role` | `aws iam list-roles --query "Roles[?contains(RoleName,'aiops-r8')]"` |
| **Lambda** | `aiops-r8-*-lambda-role` | Same |
| **Step Functions** | `aiops-r8-patch-stepfunctions-role` | Same |
| **EventBridge** | `aiops-r8-patch-eventbridge-role` | Same |

**Console:** IAM → Roles → filter by `aiops-r8`.

---

## One-Liner: Count Resources in State

```bash
cd terraform && terraform state list | wc -l
```

Typical count: 80–100+ resources depending on module count and optional resources (e.g. SNS email subscription).

---

## Verification Script (Optional)

You can create a simple script that runs the key checks:

```bash
#!/bin/bash
# verify-resources.sh - Run from project root
set -e
REGION="${AWS_REGION:-us-east-1}"
PROJECT="aiops-r8"
ENV="prod"

echo "=== Terraform State ==="
cd terraform && terraform state list | wc -l

echo "=== EC2 Instances (patch targets) ==="
aws ec2 describe-instances --filters "Name=tag:Role,Values=patch-target" "Name=instance-state-name,Values=running" \
  --query "length(Reservations[].Instances[])" --output text --region "$REGION"

echo "=== SSM Managed Instances ==="
aws ssm describe-instance-information --query "length(InstanceInformationList)" --output text --region "$REGION"

echo "=== DynamoDB Tables ==="
aws dynamodb list-tables --query "TableNames[?contains(@,'$PROJECT')]" --output table --region "$REGION"

echo "=== Lambda Functions ==="
aws lambda list-functions --query "length(Functions[?starts_with(FunctionName,'$PROJECT')])" --output text --region "$REGION"

echo "=== Step Functions ==="
aws stepfunctions list-state-machines --query "length(stateMachines[?contains(name,'$PROJECT')])" --output text --region "$REGION"
```

---

## Troubleshooting

| Symptom | Likely Cause | Action |
|---------|--------------|--------|
| `terraform plan` shows many resources to add | State out of sync or first run | Run `terraform apply` |
| RHEL8 instances not in SSM | SSM agent not installed on RHEL8 AMI | Ensure ec2-rhel8 has `user_data` to install agent; recreate instances |
| Step Functions execution fails | Lambda permissions or Bedrock access | Check Lambda logs, IAM roles, Bedrock model availability in region |
| Inspector findings empty | Inspector not enabled or scan not complete | Wait 15+ min after enabling; verify Inspector settings |
| EventBridge rule not triggering | Wrong schedule or target | Check rule schedule (cron) and target (Step Functions ARN) |
