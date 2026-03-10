# Post-Patch SSM Document

## Overview

The post-patch SSM documents run **after** CVE patching to verify that patches were applied and to generate a verification report.

In the Amazon Inspector flow, post-patch runs in **parallel** on both RHEL8 and Windows. Step Functions invokes the SSM Runner Lambda, which calls SSM to run the verification commands.

## SSM Document Content

### RHEL Post-Patch (`post-patch-cve-rhel.yaml`)

```yaml
schemaVersion: "2.2"
description: "Post-patch CVE verification for RHEL - verify patches and generate report"
parameters:
  ReportPath:
    type: String
    default: "/var/log/aiops"
    description: "Path to store post-patch report"

mainSteps:
  - name: rhelPostPatchVerify
    action: aws:runShellScript
    inputs:
      runCommand:
        - |
          mkdir -p {{ ReportPath }}
          echo "Post-patch CVE verification at $(date -Iseconds)" > {{ ReportPath }}/post_patch_report.txt
          echo "Hostname: $(hostname)" >> {{ ReportPath }}/post_patch_report.txt
          echo "========================================" >> {{ ReportPath }}/post_patch_report.txt
          echo "" >> {{ ReportPath }}/post_patch_report.txt
          echo "=== Remaining Security Updates ===" >> {{ ReportPath }}/post_patch_report.txt
          dnf check-update --security 2>/dev/null >> {{ ReportPath }}/post_patch_report.txt || echo "No pending security updates" >> {{ ReportPath }}/post_patch_report.txt
          echo "" >> {{ ReportPath }}/post_patch_report.txt
          echo "=== Last 10 Security Updates Applied ===" >> {{ ReportPath }}/post_patch_report.txt
          rpm -qa --last 2>/dev/null | head -10 >> {{ ReportPath }}/post_patch_report.txt || true
          echo "Report location: {{ ReportPath }}/post_patch_report.txt" >> {{ ReportPath }}/post_patch_report.txt
```

### Windows Post-Patch (`post-patch-cve-windows.yaml`)

```yaml
schemaVersion: "2.2"
description: "Post-patch CVE verification for Windows - verify patches and generate report"
parameters:
  ReportPath:
    type: String
    default: "C:\\aiops\\reports"
    description: "Path to store post-patch report"

mainSteps:
  - name: windowsPostPatchVerify
    action: aws:runPowerShellScript
    inputs:
      runCommand:
        - |
          $reportPath = "{{ ReportPath }}"
          if (-not (Test-Path $reportPath)) { New-Item -ItemType Directory -Path $reportPath -Force }
          $reportFile = Join-Path $reportPath "post_patch_report.txt"
          "Post-patch CVE verification at $(Get-Date -Format 'o')" | Out-File $reportFile
          "Hostname: $env:COMPUTERNAME" | Out-File $reportFile -Append
          "========================================" | Out-File $reportFile -Append
          try {
            $updateSession = New-Object -ComObject Microsoft.Update.Session
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software'")
            "Remaining updates: $($searchResult.Updates.Count)" | Out-File $reportFile -Append
          } catch {
            "Update check: $($_.Exception.Message)" | Out-File $reportFile -Append
          }
          "Report location: $reportFile" | Out-File $reportFile -Append
```

## Report Output Locations

| Platform | Path |
|----------|------|
| RHEL8 | `/var/log/aiops/post_patch_report.txt` |
| Windows | `C:\aiops\reports\post_patch_report.txt` |

## Full Document Files

The complete SSM documents are stored at:

- **RHEL**: `ssm-documents/post-patch-cve-rhel.yaml`
- **Windows**: `ssm-documents/post-patch-cve-windows.yaml`

## Post-Patch Verification Steps

1. **Timestamp** – Records when verification ran
2. **Remaining updates** – Checks if any security patches are still pending
3. **Applied patches** – Lists recently installed updates (RHEL: `rpm -qa --last`)
4. **Report path** – Confirms where the report is stored
