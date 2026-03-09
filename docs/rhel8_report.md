# RHEL8 CVE Scan Report

## Overview

This document contains the CVE security scan report for RHEL8 instances in the AIOps R8 patch workflow.

## Report Location on Server

| Location | Description |
|----------|-------------|
| **`/var/log/aiops/rhel8_scan_report.txt`** | Full CVE scan report (default) |
| **`/var/log/aiops/pre_patch_report.txt`** | Pre-patch assessment (legacy SSM document; workflow uses Amazon Inspector) |
| **`/var/log/aiops/post_patch_report.txt`** | Post-patch verification (from SSM document) |

## Generating the Report

### Via SSM Run Command

```bash
# Using AWS CLI - target RHEL8 instances by tag
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "i-xxxxxxxxx" \
  --parameters 'commands=["bash -c \"curl -s https://raw.githubusercontent.com/.../scan-rhel8.sh | bash\""]'
```

### Via Direct Execution

Copy `scripts/scan-rhel8.sh` to the instance and run:

```bash
chmod +x scan-rhel8.sh
./scan-rhel8.sh
# Or with custom path:
REPORT_DIR=/opt/reports ./scan-rhel8.sh
```

## Report Contents

- System information (RHEL version, kernel)
- Available security updates (CVE-related)
- Pending security patches
- Recently installed packages
- Report storage path

## Custom Report Path

Set the `REPORT_DIR` environment variable to change the output location:

```bash
export REPORT_DIR=/custom/path
./scan-rhel8.sh
```
