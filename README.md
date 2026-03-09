# AIOps R8 - Production-Safe CVE Patching

Automated CVE patching workflow for RHEL8 and Windows servers using AWS Lambda, EventBridge, Step Functions, Systems Manager, Amazon Inspector, and Bedrock (`us.amazon.nova-2-lite-v1:0`).

## Quick Start

```bash
# 1. Configure Terraform
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your AWS region, key pair, etc.

# 2. Deploy
terraform init
terraform plan
terraform apply

# 3. Register SSM documents (manual step - for post-patch only)
# See docs/ssm_documents.md for post-patch document registration
```

## Project Structure

```
aiops-r8/
├── terraform/           # Infrastructure as Code
│   ├── modules/         # VPC, EC2, Patch Workflow (Inspector Findings, CVE Analyzer, SSM Runner Lambdas)
│   └── main.tf
├── ssm-documents/       # Post-patch SSM documents
├── scripts/             # Scan scripts (RHEL8, Windows)
├── docs/                # Documentation
│   ├── diagram.md       # Architecture diagrams
│   ├── inspector.md     # Amazon Inspector integration
│   ├── rhel8_report.md  # RHEL8 report locations
│   ├── windows_report.md# Windows report locations
│   ├── post_patching.md # Post-patch SSM document
│   ├── terraform_workflow.md
│   ├── complete_project.md
│   ├── components.md
│   ├── ssm_documents.md
│   └── ssm_runner.md
└── README.md
```

## Report Locations on Servers

| Platform | Scan Report | Post-Patch |
|----------|-------------|------------|
| **RHEL8** | `/var/log/aiops/rhel8_scan_report.txt` | `/var/log/aiops/post_patch_report.txt` |
| **Windows** | `C:\aiops\reports\windows_scan_report.txt` | `C:\aiops\reports\post_patch_report.txt` |

## Features

- **2 RHEL8 + 2 Windows** free tier EC2 instances
- **Modular Terraform** with tagging
- **CVE-only patching** (security updates)
- **Amazon Inspector v2** for CVE scanning (replaces SSM pre-patch scans)
- **Flow**: Fetch Inspector findings → Bedrock analysis → Choice → Parallel apply → Parallel post-patch
- **Bedrock LLM** (`us.amazon.nova-2-lite-v1:0`) for CVE analysis with Inspector findings
- **Choice state**: Skips patching when no critical CVEs
- **Parallel execution**: RHEL and Windows patches run concurrently
- **EventBridge** monthly schedule (2nd Tuesday)
- **Step Functions** orchestration
- **SSM Runner Lambda** for synchronous SSM execution (no native Step Functions SSM sync)
- **SSM** for agentless management

## Documentation

See the [docs/](docs/) directory for detailed documentation.
