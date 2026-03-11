# AWS Console Verification Guide

This document describes how to verify each component of the AIOps R8 patch workflow in the AWS Console. Use this guide after `terraform apply` to confirm all resources are deployed and configured correctly.

---

## Prerequisites

- **Region**: Ensure you are in the correct region (e.g., `us-east-2`). Check your `terraform.tfvars` or run `terraform output` to confirm.
- **Credentials**: AWS CLI or Console access with permissions for Inspector, Lambda, Step Functions, EventBridge, Bedrock, SSM, EC2, and IAM.

---

## 1. Amazon Inspector v2

**Path**: AWS Console → **Amazon Inspector** (search in the top bar)

### Verify Inspector is Enabled

1. Open **Amazon Inspector**.
2. In the left sidebar, select **Settings** (or **Account management**).
3. Under **Resource coverage**, confirm **Amazon EC2** is **Enabled**.
4. If not enabled, Terraform should have enabled it via `aws_inspector2_enabler`. Re-run `terraform apply` if needed.

### Verify Findings (Optional)

1. In the left sidebar, select **Findings**.
2. Use filters:
  - **Resource type**: EC2 instance
  - **Finding status**: Active
  - **VPC ID**: Your project VPC (from `terraform output vpc_id`)
3. New instances may take minutes to hours to appear. If no findings exist, the workflow will still run (it will pass empty findings to Bedrock).

---

## 2. AWS Lambda

**Path**: AWS Console → **Lambda** → **Functions**

### Verify All Lambda Functions Exist

| Function Name                 | Purpose                                                       |
| ----------------------------- | ------------------------------------------------------------- |
| `aiops-r8-inspector-findings` | Fetches CVE findings from Inspector                           |
| `aiops-r8-cve-analyzer`       | Sends findings to Bedrock, returns analysis + critical_cve_ids |
| `aiops-r8-ssm-runner`         | Runs SSM commands; circuit-breaker pre-check; pre-patch AMIs  |
| `aiops-r8-ec2-stopped-handler`| Circuit-breaker: records CVE failures; optional recovery       |
| `aiops-r8-ami-cleanup`        | Daily cleanup of old pre-patch AMIs                           |
| `aiops-r8-ssm-agent-health`   | Filters out instances not in SSM Managed state before patching |


### Inspector Findings Lambda

1. Click `**aiops-r8-inspector-findings`**.
2. **Configuration** tab:
  - **Runtime**: Python 3.12
  - **Timeout**: 60 seconds
  - **Handler**: `inspector_findings.lambda_handler`
3. **Permissions** tab: Role should have `inspector2:ListFindings` and CloudWatch Logs.
4. **Test** (optional): Create a test event with `{"vpc_id": "vpc-xxxxx"}` (use your VPC ID). Run and check response.

### CVE Analyzer Lambda

1. Click `**aiops-r8-cve-analyzer`**.
2. **Configuration** tab:
  - **Runtime**: Python 3.12
  - **Timeout**: 60 seconds
  - **Environment variables**: `BEDROCK_MODEL_ID` (e.g., `us.amazon.nova-2-lite-v1:0`)
3. **Permissions** tab: Role should have `bedrock:InvokeModel` and CloudWatch Logs.

### SSM Runner Lambda

1. Click `**aiops-r8-ssm-runner`**.
2. **Configuration** tab:
  - **Runtime**: Python 3.12
  - **Timeout**: 300 seconds (5 minutes)
  - **Handler**: `ssm_runner.lambda_handler`
  - **Environment variables**: `PATCH_FAILURES_TABLE`, `PATCH_EXECUTIONS_TABLE`, `PATCH_ALERTS_TOPIC_ARN`, `CVE_BLOCK_TTL_DAYS`, `PATCH_CORRELATION_MINUTES`, `AMI_RETENTION_DAYS`
3. **Permissions** tab: Role should have `ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`, DynamoDB, SNS, EC2 (create_image), and CloudWatch Logs.

### Check Logs

1. For any function, go to **Monitor** tab → **View CloudWatch logs**.
2. Click the latest log stream to see recent invocations and any errors.

---

## 3. AWS Step Functions

**Path**: AWS Console → **Step Functions** → **State machines**

### Verify State Machine

1. Find `**aiops-r8-patch-workflow`**.
2. Click the state machine name.
3. **Definition** tab: Confirm the workflow includes:
  - `DiscoverInstances` (start)
  - `CheckSSMAgentHealth`
  - `FetchInspectorFindings`
  - `AnalyzeCVEs`
  - `CheckMaintenanceWindow`
  - `CheckCriticalCVEs` (Choice)
  - `ApplyPatches` (Parallel)
  - `PostPatch` (Parallel)
  - `NotifyNoPatch` (Pass)

### Run a Test Execution

1. Click **Start execution**.
2. Leave input as `{}` and click **Start execution**.
3. Go to **Executions** tab to watch the run.
4. Click an execution to see the visual graph and step-by-step status (Running, Succeeded, Failed).

---

## 4. Amazon EventBridge

**Path**: AWS Console → **EventBridge** → **Rules**

### Verify Schedule Rule

1. Find `**aiops-r8-patch-schedule`**.
2. Click the rule name.
3. **Schedule** tab:
  - **Schedule expression**: `cron(0 2 ? * 3#2 *)` (2 AM UTC, 2nd Tuesday of month)
4. **Targets** tab:
  - **Target**: Step Functions state machine `aiops-r8-patch-workflow`
  - **Role**: EventBridge execution role
5. **Rule state**: Should be **Enabled**.

### Verify EC2 Stopped Rule (Circuit-Breaker)

1. Find `**aiops-r8-{env}-ec2-stopped-rule`** (e.g., `aiops-r8-prod-ec2-stopped-rule`).
2. **Event pattern**: EC2 Instance State-change Notification, state = stopped
3. **Target**: Lambda `aiops-r8-ec2-stopped-handler`

### Verify AMI Cleanup Schedule

1. Find `**aiops-r8-{env}-ami-cleanup-schedule`**.
2. **Schedule**: `cron(0 3 ? * * *)` (3 AM UTC daily)
3. **Target**: Lambda `aiops-r8-ami-cleanup`

### Verify Step Functions Failure Rule

1. Find `**aiops-r8-{env}-sfn-failure-rule`**.
2. **Event pattern**: Source `aws.states`, detail-type `Step Functions Execution Status Change`, status `FAILED`, `ABORTED`, `TIMED_OUT`
3. **Target**: Lambda `aiops-r8-sfn-failure-notifier`
4. **Purpose**: Sends SNS alert when patch workflow execution fails

---

## 5. Amazon Bedrock

**Path**: AWS Console → **Amazon Bedrock**

### Where to Enable vs. Test Models

| Location | Purpose |
|----------|---------|
| **Model access** (left sidebar → Settings or Foundation models) | Enable/request access to models. This is where you grant your account permission to use a model. |
| **Chat** or **Text Playground** | Test models *after* they are enabled. You select from models you already have access to. |

**Chat/Text Playground is NOT where you enable models.** If a model does not appear in the Playground, it may not be enabled for your account, or it may not be available in your region.

### Default Model for This Project

**Model used by this project**: `us.amazon.nova-2-lite-v1:0` (Amazon Nova 2 Lite, via US inference profile)

**Why not Titan Text Lite?** Amazon Titan Text Lite (`amazon.titan-text-lite-v1`) is **not available in us-east-2**. It is only in us-east-1, us-west-2, and a few other regions. If you deploy in us-east-2, use Nova 2 Lite instead.

### Verify Model Access

1. Open **Amazon Bedrock**.
2. In the left sidebar, select **Model access** (under **Settings** or **Foundation models**).
3. Find **Amazon** → **Nova 2 Lite** (or **Nova Lite**).
4. Ensure the model shows **Access granted**. If not, click **Manage model access** and request access.

### Marketplace Access Denied Error

If you see:

> Model access is denied due to IAM user or service role is not authorized to perform the required AWS Marketplace actions (aws-marketplace:ViewSubscriptions, aws-marketplace:Subscribe)

This typically affects third-party models (e.g., Claude Sonnet 4.6) that require Marketplace subscription. **Amazon Nova** and **Amazon Titan** models are AWS-native and do not require Marketplace subscription.

**Recommended for us-east-2** (no Marketplace):
- `us.amazon.nova-2-lite-v1:0` – Nova 2 Lite via US inference profile (routes from us-east-2)
- `amazon.nova-lite-v1:0` – Nova Lite (use in us-east-1; not natively in us-east-2)

**If deploying in us-east-1** (N. Virginia):
- `amazon.titan-text-lite-v1` – Titan Text Lite (lowest cost)
- `amazon.nova-lite-v1:0` – Nova Lite

### Test Model (Optional)

1. Go to **Chat** or **Text Playground** in Bedrock.
2. Select **Nova 2 Lite** or **Nova Lite** (or your configured model).
3. Send a test message to confirm the model responds.

---

## 6. AWS Systems Manager (SSM)

**Path**: AWS Console → **Systems Manager**

### Verify Managed Instances

1. In the left sidebar, select **Fleet Manager** → **Managed nodes** (or **Managed instances**).
2. Confirm your RHEL8 and Windows instances appear with status **Online**.
3. If instances show **Connection lost**, check:
  - IAM instance profile has `AmazonSSMManagedInstanceCore`
  - Security group allows outbound HTTPS (443)
  - Instances have network path to SSM endpoints (e.g., via NAT Gateway)

### Verify Patch Baseline (Windows)

1. In the left sidebar, select **Patch Manager** → **Patch baselines**.
2. Find `**aiops-r8-windows-cve-baseline`**.
3. Confirm it is associated with patch group `**aiops-r8-windows-cve**`.

### Verify Patch Group

1. Go to **Patch Manager** → **Patch groups**.
2. Confirm `**aiops-r8-windows-cve`** is linked to the CVE baseline.

---

## 6.5. DynamoDB & SNS (Circuit-Breaker)

**Path**: AWS Console → **DynamoDB** → **Tables** and **SNS** → **Topics**

### Verify DynamoDB Tables

1. **`aiops-r8-{env}-cve-patch-failures`**: PK `cve_id`, SK `failed_at` – stores CVEs that caused reboot failure
2. **`aiops-r8-{env}-patch-executions`**: PK `instance_id`, SK `started_at` – tracks patch executions for correlation

### Verify SNS Topic

1. Find `**aiops-r8-{env}-patch-alerts`**.
2. Subscribe your email or other endpoint to receive circuit-breaker alerts when CVE patching is skipped.

---

## 7. Amazon EC2

**Path**: AWS Console → **EC2** → **Instances**

### Verify Instances

1. Filter or search for instances with tag **Project** = `aiops-r8`.
2. You should see:
  - **2 RHEL8 instances** (e.g., `aiops-r8-rhel8-1`, `aiops-r8-rhel8-2`)
  - **2 Windows instances** (e.g., `aiops-r8-windows-1`, `aiops-r8-windows-2`)
3. **State**: Should be **Running**.
4. **Tags**: `OS` (rhel8/windows), `Role` (patch-target), `PatchGroup` (aiops-r8-windows-cve for Windows).

---

## 8. VPC

**Path**: AWS Console → **VPC** → **Your VPCs**

### Verify VPC

1. Find the VPC used by the project (check `terraform output vpc_id` or look for tag **Project** = `aiops-r8`).
2. Confirm:
  - **CIDR**: Typically `10.0.0.0/16`
  - **Subnets**: Private subnets for EC2, public subnet for NAT (if used)

---

## 9. IAM Roles

**Path**: AWS Console → **IAM** → **Roles**

### Key Roles to Verify


| Role Name                                 | Purpose                             |
| ----------------------------------------- | ----------------------------------- |
| `aiops-r8-inspector-findings-lambda-role` | Inspector Findings Lambda           |
| `aiops-r8-cve-analyzer-lambda-role`       | CVE Analyzer Lambda                 |
| `aiops-r8-ssm-runner-lambda-role`         | SSM Runner Lambda                   |
| `aiops-r8-ec2-stopped-handler-role`       | EC2 Stopped Handler (circuit-breaker) |
| `aiops-r8-ami-cleanup-role`               | AMI Cleanup Lambda                  |
| `aiops-r8-sfn-failure-notifier-role`      | SFN Failure Notifier (workflow failure SNS) |
| `aiops-r8-patch-stepfunctions-role`       | Step Functions execution            |
| `aiops-r8-patch-eventbridge-role`         | EventBridge to start Step Functions |


1. Search for `aiops-r8` in the Roles list.
2. Click each role and verify **Permissions** tab shows the expected policies.

---

## Quick Verification Checklist


| Component          | What to Check                                                   |
| ------------------ | --------------------------------------------------------------- |
| **Inspector**      | EC2 enabled in Settings                                         |
| **Lambda**         | All 12 functions exist (cve-analyzer, ssm-runner, inspector-findings, ssm-agent-health, sfn-failure-notifier, etc.) |
| **Step Functions** | State machine `aiops-r8-patch-workflow` exists                  |
| **EventBridge**    | Rules: patch-schedule, ec2-stopped-rule, ami-cleanup-schedule, sfn-failure-rule   |
| **DynamoDB**       | Tables: cve-patch-failures, patch-executions                    |
| **SNS**            | Topic `aiops-r8-{env}-patch-alerts` for circuit-breaker, SSM exclusions, workflow failures |
| **Bedrock**        | Model access granted for `us.amazon.nova-2-lite-v1:0`            |
| **SSM**            | Managed instances Online, patch baseline exists                 |
| **EC2**            | 4 instances (2 RHEL8, 2 Windows) running                        |
| **IAM**            | Roles exist with correct policies                               |


---

## Troubleshooting in the Console


| Issue                  | Where to Look                                                  |
| ---------------------- | -------------------------------------------------------------- |
| Lambda errors          | Lambda → Function → Monitor → CloudWatch logs                  |
| Step Functions failure | Step Functions → Executions → Failed execution → Input/Output  |
| No Bedrock response    | Bedrock → Model access (ensure model enabled)                  |
| SSM instances offline  | SSM → Managed nodes; EC2 → Instance → IAM role, security group |
| EventBridge not firing | EventBridge → Rules → Rule state; check cron expression        |


