# Windows CVE Scan Report

## Overview

This document contains the CVE security scan report for Windows instances in the AIOps R8 patch workflow.

## Report Location on Server

| Location | Description |
|----------|-------------|
| **`C:\aiops\reports\windows_scan_report.txt`** | Full CVE scan report (default) |
| **`C:\aiops\reports\pre_patch_report.txt`** | Pre-patch assessment (legacy SSM document; workflow uses Amazon Inspector) |
| **`C:\aiops\reports\post_patch_report.txt`** | Post-patch verification (from SSM document) |

## Generating the Report

### Via SSM Run Command

```powershell
# Using AWS CLI - target Windows instances by tag
aws ssm send-command \
  --document-name "AWS-RunPowerShellScript" \
  --instance-ids "i-xxxxxxxxx" \
  --parameters 'commands=["powershell -ExecutionPolicy Bypass -File C:\\path\\to\\scan-windows.ps1"]'
```

### Via Direct Execution

Copy `scripts/scan-windows.ps1` to the instance and run:

```powershell
powershell -ExecutionPolicy Bypass -File scan-windows.ps1
# Or with custom path:
$env:REPORT_DIR = "D:\reports"; powershell -ExecutionPolicy Bypass -File scan-windows.ps1
```

## Report Contents

- System information (Windows version)
- Available security updates (pending)
- Recently installed hotfixes
- Report storage path

## Custom Report Path

Set the `REPORT_DIR` environment variable to change the output location:

```powershell
$env:REPORT_DIR = "D:\custom\reports"
.\scan-windows.ps1
```
