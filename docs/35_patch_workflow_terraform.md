# Patch Workflow Module – Terraform Structure

The `patch-workflow` Terraform module is split across multiple files for maintainability. This document describes the layout and where to find each resource.

## File Layout


| File                      | Purpose                                                                                           |
| ------------------------- | ------------------------------------------------------------------------------------------------- |
| `main.tf`                 | Module overview and file index                                                                    |
| `dynamodb.tf`             | Circuit-breaker tables (`cve_patch_failures`, `patch_executions`), patch history                  |
| `sns.tf`                  | SNS topic and optional email subscription for alerts                                              |
| `ssm.tf`                  | Windows patch baseline and patch group                                                            |
| `iam.tf`                  | Step Functions and EventBridge IAM roles                                                          |
| `lambda.tf`               | All Lambda functions (CVE analyzer, Inspector, SSM runner, discovery, batch, failure check, etc.) |
| `step_functions.tf`       | Patch workflow state machine (uses `workflow.asl.json.tftpl`)                                     |
| `eventbridge.tf`          | Patch schedule, EC2 stopped rule, AMI cleanup schedule, SFN failure rule                          |
| `workflow.asl.json.tftpl` | Step Functions definition (ASL JSON with Terraform template variables)                            |
| `variables.tf`            | Input variables                                                                                   |
| `outputs.tf`              | Output values                                                                                     |


## Step Functions Definition

The workflow definition lives in `workflow.asl.json.tftpl`. It is rendered by Terraform’s `templatefile()` with variables such as:

- Lambda function names
- `vpc_id`, `rhel8_ids`, `windows_ids`
- `batch_size`, `canary_batch_size`
- `dry_run`, `create_prepatch_ami`

To change the workflow logic, edit `workflow.asl.json.tftpl`. New template variables must be added in `step_functions.tf` in the `templatefile()` call.

## Adding New Resources

- **New DynamoDB table** → `dynamodb.tf`
- **New SNS topic/subscription** → `sns.tf`
- **New SSM resource** → `ssm.tf`
- **New Lambda + IAM** → `lambda.tf`
- **New EventBridge rule** → `eventbridge.tf`
- **New Step Functions state** → `workflow.asl.json.tftpl` and `step_functions.tf` (if new template vars)

## Monitoring Script

Run `scripts/monitor-patch-workflow.sh` to gather EventBridge rule status, Step Functions executions, and CloudWatch log groups:

```bash
./scripts/monitor-patch-workflow.sh
```

Override defaults with environment variables: `PROJECT_NAME`, `ENVIRONMENT`, `AWS_REGION`.

