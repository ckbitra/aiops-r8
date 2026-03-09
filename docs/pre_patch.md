# Pre-Patch: Amazon Inspector (Replaces SSM Pre-Patch)

## Overview

The patch workflow no longer uses SSM pre-patch documents for CVE scanning. Instead, **Amazon Inspector v2** provides CVE findings. The **Inspector Findings Lambda** fetches these findings and passes them to the CVE Analyzer for Bedrock analysis.

## Previous vs Current Approach

| Previous (SSM Pre-Patch) | Current (Amazon Inspector) |
|--------------------------|----------------------------|
| SSM Runner Lambda invoked SSM on RHEL8 and Windows | Inspector Findings Lambda calls `inspector2:ListFindings` |
| Custom SSM documents (pre-patch-cve-rhel, pre-patch-cve-windows) | No custom pre-patch documents |
| Output: Raw command output from instances | Output: Structured findings (severity, CVE IDs, packages) |

## Workflow Integration

1. **FetchInspectorFindings** – Step Functions invokes the Inspector Findings Lambda
2. Lambda calls `inspector2:ListFindings` with filters (VPC ID, EC2, ACTIVE)
3. Lambda returns a summary to Step Functions
4. **AnalyzeCVEs** – CVE Analyzer receives the findings and sends to Bedrock

## Report Locations (Legacy)

The following paths were used by the old SSM pre-patch documents. They are no longer populated by the patch workflow:

| Platform | Legacy Pre-Patch Path |
|----------|------------------------|
| RHEL8 | `/var/log/aiops/pre_patch_report.txt` |
| Windows | `C:\aiops\reports\pre_patch_report.txt` |

If you run the old pre-patch SSM documents manually, they will still write to these paths. The automated workflow uses Inspector instead.

## See Also

- [docs/inspector.md](inspector.md) – Amazon Inspector integration details
- [docs/ssm_documents.md](ssm_documents.md) – SSM documents (post-patch only)
