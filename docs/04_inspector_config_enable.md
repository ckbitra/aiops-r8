# Amazon Inspector: Configuration and Enablement

## Overview

To enable Amazon Inspector scanning, you must **enable** Inspector for the resource types you want to scan. Inspector is **off by default** until you activate it.

## 1. Enable Inspector for Resource Types

Inspector must be enabled for each resource type you want to scan.

### Resource Types

| Resource Type | What It Scans |
|---------------|---------------|
| **EC2** | EC2 instances (package vulnerabilities, network reachability) |
| **ECR** | Container images in ECR |
| **LAMBDA** | Lambda functions (software vulnerabilities) |
| **LAMBDA_CODE** | Lambda custom code (requires LAMBDA enabled first) |
| **CODE_REPOSITORY** | Code repositories |

### How to Enable

**AWS Console**

1. Open **Amazon Inspector** → **Account management**
2. Select the account(s)
3. Click **Activate**
4. Choose scan types (EC2, ECR, Lambda, etc.)

**AWS CLI**

```bash
aws inspector2 enable --resource-types EC2
# or multiple:
aws inspector2 enable --resource-types EC2 ECR LAMBDA
```

**Terraform** (as in this project)

```hcl
resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2"]
}
```

## 2. What Inspector Configures for You

When you enable Inspector, AWS automatically:

- Creates the necessary service-linked roles
- Grants Inspector permissions to access EC2, ECR, Lambda, etc.
- Begins discovering and scanning resources for the enabled types

You typically don't need to configure IAM roles or policies manually.

## 3. EC2-Specific Requirements

For EC2 scanning to work:

- **SSM Agent** – Instances must have the SSM agent installed (for agent-based scanning) or be eligible for agentless scanning
- **Network** – Instances need outbound internet or VPC endpoints so Inspector can reach them

## 4. Timing

Enabling Inspector can take **15–30 minutes**. This project uses a 30-minute Terraform timeout for the enabler resource because of this.

---

**Summary:** The main configuration is enabling Inspector for the desired resource types (EC2, ECR, Lambda, etc.). Once enabled, Inspector discovers and scans those resources automatically.
