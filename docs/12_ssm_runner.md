# SSM Runner Lambda

## Overview

The **SSM Runner Lambda** (`aiops-r8-ssm-runner`) runs SSM commands and waits for completion. It exists because Step Functions has no native `ssm:sendCommand.sync` integration. It also implements the **circuit-breaker** (pre-patch check for blocked CVEs) and **pre-patch AMI creation**.

## Why It Exists

- **Step Functions limitation**: There is no `arn:aws:states:::ssm:sendCommand.sync` resource
- **Requirement**: The patch workflow needs to run SSM commands and wait for results before continuing
- **Solution**: Lambda invokes SSM SendCommand, polls `GetCommandInvocation` until all instances complete, then returns the output

## Flow

```
Step Functions  →  Lambda (ssm_runner)
    →  Circuit-breaker check (query cve_patch_failures)
    →  If blocked: SNS alert, return early
    →  Create pre-patch AMIs (EC2 create_image)
    →  SSM SendCommand  →  Record to patch_executions  →  Poll until done  →  Return output
```

## Circuit-Breaker

Before applying patches, the Lambda queries the `cve-patch-failures` DynamoDB table for any of the `critical_cve_ids`. If a CVE was recently recorded (within `CVE_BLOCK_TTL_DAYS`, default 7) because a patch caused a reboot failure, patching is skipped and an SNS alert is sent.

## Pre-Patch AMIs

Before running SSM patch commands, the Lambda creates AMIs for each target instance via `ec2.create_image`. AMIs are named `AI-Patch-{InstanceId}-{timestamp}-{patch_mode}`. These enable recovery if a patch causes boot failure (see EC2 Stopped Handler Lambda).

## Usage in the Workflow

| Step | Lambda Input | SSM Document |
|------|--------------|--------------|
| ApplyRHEL | document_name, instance_ids, critical_cve_ids, patch_mode, parameters.commands | AWS-RunShellScript |
| ApplyWindows | document_name, targets, critical_cve_ids, patch_mode, parameters | AWS-RunPatchBaseline |
| PostPatchRHEL | document_name, instance_ids, parameters.commands | AWS-RunShellScript |
| PostPatchWindows | document_name, instance_ids, parameters.commands | AWS-RunPowerShellScript |

**Note:** Pre-patch scans are no longer done via SSM. The workflow uses Amazon Inspector for CVE scanning; the Inspector Findings Lambda fetches findings directly from Inspector.

## Input Format

```json
{
  "document_name": "AWS-RunShellScript",
  "instance_ids": ["i-xxx", "i-yyy"],
  "critical_cve_ids": ["CVE-2024-1234"],
  "patch_mode": "rhel",
  "parameters": {
    "commands": ["echo hello"]
  }
}
```

For RunPatchBaseline (Windows):

```json
{
  "document_name": "AWS-RunPatchBaseline",
  "targets": [{"Key": "InstanceIds", "Values": ["i-xxx"]}],
  "critical_cve_ids": ["CVE-2024-1234"],
  "patch_mode": "windows",
  "parameters": {
    "Operation": "Install",
    "RebootOption": "RebootIfNeeded"
  }
}
```

## Output Format

**Success:**
```json
{
  "statusCode": 200,
  "body": {
    "CommandId": "xxx",
    "Invocations": [
      {
        "InstanceId": "i-xxx",
        "Status": "Success",
        "Output": "command output text",
        "Error": ""
      }
    ]
  }
}
```

**Blocked (circuit-breaker):**
```json
{
  "statusCode": 200,
  "body": {
    "blocked": true,
    "blocked_cves": ["CVE-2024-1234"],
    "message": "Patching skipped—CVE(s) blocked by circuit-breaker (previous patch caused reboot failure)"
  }
}
```

## Environment Variables

| Variable | Purpose |
|---------|---------|
| `PATCH_FAILURES_TABLE` | DynamoDB table for CVE failures |
| `PATCH_EXECUTIONS_TABLE` | DynamoDB table for patch tracking |
| `PATCH_ALERTS_TOPIC_ARN` | SNS topic for blocked-CVE alerts |
| `CVE_BLOCK_TTL_DAYS` | Days to block a CVE after failure (default 7) |
| `PATCH_CORRELATION_MINUTES` | Correlation window for EC2 stopped (default 45) |
| `AMI_RETENTION_DAYS` | Days to retain pre-patch AMIs (default 7) |

## Permissions

- `ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`
- DynamoDB: GetItem, PutItem, Query, BatchWriteItem
- SNS: Publish
- EC2: CreateImage, DescribeImages, DeregisterImage, DescribeSnapshots, DeleteSnapshot
- CloudWatch Logs

## Timeout

Lambda timeout: 300 seconds (5 minutes). Long-running patch operations may need adjustment.
