# Manual Execution Guide

This document describes how to manually execute the AIOps R8 patch workflow and its individual components.

---

## Prerequisites

1. **AWS CLI** configured with credentials that have permissions for:
  - Step Functions, Lambda, SSM, EC2, Bedrock, Inspector
2. **Terraform applied** – Infrastructure must be deployed
3. **Instance IDs** – RHEL8 and Windows instances must exist and be SSM-managed
4. **Bedrock access** – `us.amazon.nova-2-lite-v1:0` enabled in your region
5. **Amazon Inspector** – Enabled for EC2 (Terraform enables this)

---

## 1. Get Resource IDs

After `terraform apply`, retrieve the required values:

```bash
cd terraform

# State machine ARN (for full workflow)
terraform output patch_workflow_state_machine_arn

# VPC ID (for Inspector findings)
terraform output vpc_id

# Instance IDs
terraform output rhel8_instance_ids
terraform output windows_instance_ids

# Or get all outputs
terraform output
```

Example output:

```
patch_workflow_state_machine_arn = "arn:aws:states:us-east-2:123456789012:stateMachine:aiops-r8-patch-workflow"
vpc_id = "vpc-0abc123def456"
rhel8_instance_ids = ["i-0abc123", "i-0def456"]
windows_instance_ids = ["i-0ghi789", "i-0jkl012"]
```

---

## 2. Execute Full Patch Workflow (Step Functions)

### Via AWS CLI

### # Replace with your state machine ARN from terraform output
STATE_MACHINE_ARN="arn:aws:states:us-east-2:YOUR_ACCOUNT:stateMachine:aiops-r8-patch-workflow"

aws stepfunctions start-execution \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --input '{}'

The workflow uses instance IDs and VPC ID baked into the Terraform definition, so no input is required.

**Response:**

```json
{
  "executionArn": "arn:aws:states:us-east-2:123456789012:execution:aiops-r8-patch-workflow:manual-20240305-001",
  "startDate": "2024-03-05T00:01:00.000Z"
}
```

### Via AWS Console

1. Open **Step Functions** in the AWS Console
2. Select the state machine **aiops-r8-patch-workflow**
3. Click **Start execution**
4. Leave input as `{}` and click **Start execution**

---

## 3. Monitor Execution

### Via AWS CLI

```bash
# Replace with your execution ARN from start-execution response
EXECUTION_ARN="arn:aws:states:us-east-2:123456789012:execution:aiops-r8-patch-workflow:manual-20240305-001"

# Get execution status
aws stepfunctions describe-execution --execution-arn "$EXECUTION_ARN"

# Get execution history (detailed steps)
aws stepfunctions get-execution-history --execution-arn "$EXECUTION_ARN"
```

### Via AWS Console

1. Step Functions → **Executions**
2. Select your execution
3. View the visual graph and step-by-step status

---

## 4. Execute Individual SSM Commands (Bypass Workflow)

To run specific steps without the full workflow:

### Apply CVE Patches on RHEL8

```bash
# Replace with your RHEL8 instance IDs
RHEL_IDS="i-0abc123,i-0def456"

aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids $RHEL_IDS \
  --parameters 'commands=["sudo dnf update --security -y || sudo yum update --security -y"]' \
  --output text
```

### Apply CVE Patches on Windows

```bash
# Windows instances must have PatchGroup tag: aiops-r8-windows-cve
aws ssm send-command \
  --document-name "AWS-RunPatchBaseline" \
  --targets "Key=InstanceIds,Values=$WIN_IDS" \
  --parameters '{"Operation":["Install"],"RebootOption":["RebootIfNeeded"]}' \
  --output text
```

### Check Command Status

```bash
# Replace with CommandId from send-command response
COMMAND_ID="abc12345-6789-0def-ghij-klmnopqrstuv"

aws ssm list-command-invocations \
  --command-id "$COMMAND_ID" \
  --details
```

---

## 5. Invoke Inspector Findings Lambda Directly

To fetch Inspector findings (same as workflow step, but standalone):

```bash
# Replace with your VPC ID from terraform output
VPC_ID="vpc-0abc123def456"

aws lambda invoke \
  --function-name aiops-r8-inspector-findings \
  --payload "{\"vpc_id\":\"$VPC_ID\"}" \
  --cli-binary-format raw-in-base64-out \
  response.json

cat response.json
```

---

## 6. Invoke SSM Runner Lambda Directly

To run SSM commands through the Lambda (same as workflow, but standalone):

```bash
# Replace with your instance IDs and Lambda name
RHEL_IDS='["i-0abc123","i-0def456"]'

aws lambda invoke \
  --function-name aiops-r8-ssm-runner \
  --payload "{\"document_name\":\"AWS-RunShellScript\",\"instance_ids\":$RHEL_IDS,\"parameters\":{\"commands\":[\"dnf check-update --security 2>/dev/null || echo No updates\"]}}" \
  --cli-binary-format raw-in-base64-out \
  response.json

cat response.json
```

---

## 7. Invoke CVE Analyzer Lambda (Analysis Only)

To run Bedrock CVE analysis without patching:

```bash
# Requires Inspector findings - typically from a previous Inspector Findings Lambda run
aws lambda invoke \
  --function-name aiops-r8-cve-analyzer \
  --payload '{"action":"analyze","inspector_findings":{"findingsCount":2,"findings":[{"severity":"CRITICAL","cveIds":["CVE-2024-1234"],"affectedPackages":["openssl"],"description":"Sample finding"}]},"rhel8_ids":["i-0abc123"],"windows_ids":["i-0ghi789"]}' \
  --cli-binary-format raw-in-base64-out \
  response.json

cat response.json
```

---

## 8. Run Scan Scripts on Instances

### RHEL8 Scan (via SSM)

```bash
# Copy script content and run via SSM
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids $RHEL_IDS \
  --parameters 'commands=["mkdir -p /var/log/aiops","(dnf updateinfo list security 2>/dev/null || yum updateinfo list security 2>/dev/null || echo No info) | tee /var/log/aiops/rhel8_scan_report.txt","cat /var/log/aiops/rhel8_scan_report.txt"]' \
  --output text
```

### Windows Scan (via SSM)

```bash
aws ssm send-command \
  --document-name "AWS-RunPowerShellScript" \
  --instance-ids $WIN_IDS \
  --parameters 'commands=["if (-not (Test-Path C:\\aiops\\reports)) { New-Item -ItemType Directory -Path C:\\aiops\\reports -Force }; Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 20 | Out-File C:\\aiops\\reports\\windows_scan_report.txt; Get-Content C:\\aiops\\reports\\windows_scan_report.txt"]' \
  --output text
```

---

## 9. Retrieve Reports from Instances

Reports are stored on the instances. To view them, use SSM Session Manager or copy via SSM Run Command:

### RHEL8 Report

```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "i-0abc123" \
  --parameters 'commands=["cat /var/log/aiops/rhel8_scan_report.txt 2>/dev/null || cat /var/log/aiops/post_patch_report.txt"]' \
  --output text
```

### Windows Report

```bash
aws ssm send-command \
  --document-name "AWS-RunPowerShellScript" \
  --instance-ids "i-0ghi789" \
  --parameters 'commands=["Get-Content C:\\aiops\\reports\\windows_scan_report.txt -ErrorAction SilentlyContinue"]' \
  --output text
```

**Report locations:**

- RHEL8: `/var/log/aiops/rhel8_scan_report.txt`, `/var/log/aiops/post_patch_report.txt`
- Windows: `C:\aiops\reports\windows_scan_report.txt`, `C:\aiops\reports\post_patch_report.txt`

---

## 10. Disable/Enable Scheduled Execution

To prevent the EventBridge schedule from triggering the workflow:

```bash
# Disable the rule
aws events disable-rule --name aiops-r8-patch-schedule

# Re-enable when ready
aws events enable-rule --name aiops-r8-patch-schedule
```

---

## 11. Troubleshooting


| Issue                                     | Action                                                                             |
| ----------------------------------------- | ---------------------------------------------------------------------------------- |
| Execution fails at FetchInspectorFindings | Verify Inspector v2 is enabled; check Lambda logs; ensure VPC ID is correct        |
| No Inspector findings                     | New instances may need time; Inspector scans periodically; check Inspector console |
| Execution fails at ApplyPatches           | Verify RHEL8/Windows instances are SSM-managed; check SSM Agent status             |
| Bedrock analysis fails                    | Ensure `us.amazon.nova-2-lite-v1:0` is enabled in Bedrock Model access             |
| No instance IDs                           | Run `terraform output`; ensure EC2 instances were created successfully             |
| Lambda timeout                            | Increase SSM Runner Lambda timeout in Terraform (default 300s)                     |


