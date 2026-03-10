# SSM Document Details

## Overview

AWS Systems Manager (SSM) documents define the commands and scripts run on EC2 instances during the patch workflow. The workflow uses **Amazon Inspector** for CVE scanning; SSM is used for **apply patches** and **post-patch verification** only.

## AWS Managed Documents Used

| Document | Platform | Purpose |
|----------|----------|---------|
| `AWS-RunShellScript` | Linux/RHEL | Run shell commands on RHEL8 |
| `AWS-RunPowerShellScript` | Windows | Run PowerShell on Windows |
| `AWS-RunPatchBaseline` | Windows | Apply patches from Patch Baseline (CVE-only) |

## Custom SSM Documents (Project)

### Post-Patch Documents Only

The workflow no longer uses pre-patch SSM documents. CVE scanning is done by **Amazon Inspector**.

| Document | File | Platform |
|----------|------|----------|
| Post-patch CVE RHEL | `ssm-documents/post-patch-cve-rhel.yaml` | RHEL8 |
| Post-patch CVE Windows | `ssm-documents/post-patch-cve-windows.yaml` | Windows |

**Schema**: 2.2  
**Parameters**: `ReportPath`  
**Output**: Post-patch verification report

## Document Structure (YAML)

```yaml
schemaVersion: "2.2"
description: "Document description"
parameters:
  ReportPath:
    type: String
    default: "/var/log/aiops"
    description: "Path for report output"

mainSteps:
  - name: stepName
    action: aws:runShellScript   # or aws:runPowerShellScript
    inputs:
      runCommand:
        - "command1"
        - "command2"
```

## Step Functions Integration (Amazon Inspector Flow)

1. **Fetch Inspector findings**: Inspector Findings Lambda fetches CVE data from Amazon Inspector v2 (no SSM)
2. **Apply patches**: Step Functions invokes SSM Runner Lambda → Lambda calls SSM SendCommand
3. **Post-patch**: SSM Runner Lambda runs verification on both platforms in parallel

**Flow**: Step Functions → Lambda (ssm_runner) → SSM → EC2 instances

- **RHEL**: `AWS-RunShellScript`, `InstanceIds`, `Parameters.commands`
- **Windows**: `AWS-RunPatchBaseline` or `AWS-RunPowerShellScript`, `Targets` or `InstanceIds`

## Registering Custom Documents

```bash
# RHEL post-patch
aws ssm create-document \
  --name "AIOpsR8-PostPatch-RHEL" \
  --document-type "Command" \
  --document-format "YAML" \
  --content file://ssm-documents/post-patch-cve-rhel.yaml

# Windows post-patch
aws ssm create-document \
  --name "AIOpsR8-PostPatch-Windows" \
  --document-type "Command" \
  --document-format "YAML" \
  --content file://ssm-documents/post-patch-cve-windows.yaml
```

**Note**: Pre-patch documents (AIOpsR8-PrePatch-RHEL, AIOpsR8-PrePatch-Windows) are no longer used by the workflow. The project uses Amazon Inspector for CVE scanning.

## Report Paths Summary

| Document | RHEL Path | Windows Path |
|----------|-----------|---------------|
| Post-patch | `/var/log/aiops/post_patch_report.txt` | `C:\aiops\reports\post_patch_report.txt` |
