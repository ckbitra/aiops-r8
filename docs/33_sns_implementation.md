# SNS Implementation in AIOps R8

This document explains Amazon Simple Notification Service (SNS) and how it is implemented in the AIOps R8 patch workflow, ordered by execution flow.

---

## What is SNS?

Amazon SNS is a fully managed pub/sub messaging service. Publishers send messages to a **topic**; subscribers receive those messages via their chosen protocol (email, SMS, HTTP, Lambda, etc.). In this project, SNS is used to send email alerts when guardrail conditions are triggered during the patch workflow.

---

## SNS in This Project – Overview

| Component | Description |
|-----------|-------------|
| **Topic** | `aiops-r8-{env}-patch-alerts` (e.g., `aiops-r8-prod-patch-alerts`) |
| **Subscription** | Optional email subscription when `alert_email` is set |
| **Publishers** | SSM Agent Health Lambda, SSM Runner Lambda, SFN Failure Notifier Lambda |
| **Purpose** | Alert operators when instances are excluded, CVE patching is blocked, or workflow fails |

---

## Execution Order – When SNS Alerts Are Sent

SNS alerts are sent at three points:

**During workflow execution:**

```
DiscoverInstances
       │
       ▼
┌──────────────────────┐
│ CheckSSMAgentHealth   │  ◄── SNS ALERT #1: Instances excluded (not SSM-managed)
└──────────────────────┘
       │
       ▼
FetchInspectorFindings → AnalyzeCVEs → CheckMaintenanceWindow → CheckMaintenanceChoice
       │
       ▼
PrepareBatches
       │
       ▼
┌──────────────────────┐
│ ApplyPatches          │
│   MapRHELBatches     │
│   MapWindowsBatches  │
│       │              │
│       ▼              │
│   SSM Runner Lambda  │  ◄── SNS ALERT #2: CVE patching blocked (circuit-breaker)
└──────────────────────┘
```

**After workflow ends (EventBridge):**

```
Step Functions execution → FAILED / ABORTED / TIMED_OUT
       │
       ▼
EventBridge rule (aiops-r8-{env}-sfn-failure-rule)
       │
       ▼
SFN Failure Notifier Lambda  ◄── SNS ALERT #3: Patch workflow execution failed
```

---

## 1. SNS Alert #1 – SSM Agent Health (Early in Workflow)

### Execution Position

Runs as the **second step** of the workflow, immediately after `DiscoverInstances`.

### When It Fires

When one or more discovered instances are **not** in SSM Managed state (`PingStatus ≠ Online`). Those instances are filtered out before patching; an SNS alert is sent to notify operators.

### Implementation

| Item | Details |
|------|---------|
| **Lambda** | `aiops-r8-ssm-agent-health` |
| **Step Functions state** | `CheckSSMAgentHealth` |
| **Trigger** | `excluded_rhel` or `excluded_windows` is non-empty |
| **Subject** | `AIOps: Instances excluded (not SSM-managed)` |
| **Message** | Lists excluded RHEL and Windows instance IDs |

### Code Reference

```python
# terraform/modules/patch-workflow/lambda/ssm_agent_health.py
if excluded_rhel or excluded_windows:
    if PATCH_ALERTS_TOPIC_ARN:
        sns.publish(
            TopicArn=PATCH_ALERTS_TOPIC_ARN,
            Subject="AIOps: Instances excluded (not SSM-managed)",
            Message=f"Instances excluded from patching (not in SSM Managed state):\n"
                    f"RHEL: {excluded_rhel}\nWindows: {excluded_windows}",
        )
```

### Environment Variable

- `PATCH_ALERTS_TOPIC_ARN` – Set by Terraform to the patch-alerts topic ARN

---

## 2. SNS Alert #2 – Circuit-Breaker (During ApplyPatches)

### Execution Position

Runs **inside** `ApplyPatches`, when the SSM Runner Lambda is invoked for each batch (RHEL and Windows). The circuit-breaker check runs before any SSM commands or AMI creation.

### When It Fires

When one or more critical CVEs are **blocked** in the `cve-patch-failures` DynamoDB table (because a previous patch caused a reboot failure within the TTL window, default 7 days). Patching is skipped for that batch and an SNS alert is sent.

### Implementation

| Item | Details |
|------|---------|
| **Lambda** | `aiops-r8-ssm-runner` |
| **Step Functions state** | Invoked from `PatchRHELBatch` / `PatchWindowsBatch` |
| **Trigger** | `_check_blocked_cves()` returns non-empty list |
| **Subject** | `AIOps: CVE patching blocked (circuit-breaker)` |
| **Message** | Lists blocked CVE IDs and states that patching was skipped |

### Code Reference

```python
# terraform/modules/patch-workflow/lambda/ssm_runner.py
blocked = _check_blocked_cves(critical_cve_ids)
if blocked:
    _send_blocked_alert(blocked)
    # ... return early, no patching

def _send_blocked_alert(blocked_cves: List[str]) -> None:
    sns.publish(
        TopicArn=PATCH_ALERTS_TOPIC_ARN,
        Subject="AIOps: CVE patching blocked (circuit-breaker)",
        Message=f"CVE(s) blocked—previous patch caused reboot failure: {', '.join(blocked_cves)}. Patching skipped.",
    )
```

### Environment Variable

- `PATCH_ALERTS_TOPIC_ARN` – Set by Terraform to the patch-alerts topic ARN

---

## 3. SNS Alert #3 – Step Functions Execution Failure (EventBridge)

### Execution Position

Triggered **after** the Step Functions execution ends with status `FAILED`, `ABORTED`, or `TIMED_OUT`. EventBridge receives the Step Functions execution status change event and invokes the SFN Failure Notifier Lambda.

### When It Fires

When the patch workflow state machine execution fails for any reason (Lambda error, timeout, circuit-breaker triggered, etc.). The Lambda formats the failure details and publishes to SNS.

### Implementation

| Item | Details |
|------|---------|
| **Lambda** | `aiops-r8-sfn-failure-notifier` |
| **Trigger** | EventBridge rule `aiops-r8-{env}-sfn-failure-rule` on Step Functions execution status change |
| **Event pattern** | `source=aws.states`, `detail-type=Step Functions Execution Status Change`, `status=FAILED|ABORTED|TIMED_OUT` |
| **Subject** | `AIOps: Patch workflow FAILED - {execution_name}` |
| **Message** | Execution name, ID, status, start/stop time, error, cause, ARNs |

### Code Reference

```python
# terraform/modules/patch-workflow/lambda/sfn_failure_notifier.py
# Receives EventBridge event, publishes to SNS when status is FAILED, ABORTED, or TIMED_OUT
sns.publish(
    TopicArn=PATCH_ALERTS_TOPIC_ARN,
    Subject=f"AIOps: Patch workflow FAILED - {execution_name}",
    Message=message,  # Includes execution details, error, cause
)
```

### Environment Variable

- `PATCH_ALERTS_TOPIC_ARN` – Set by Terraform to the patch-alerts topic ARN

---

## Terraform Configuration

### SNS Topic

```hcl
# terraform/modules/patch-workflow/sns.tf, lambda.tf, eventbridge.tf
resource "aws_sns_topic" "patch_alerts" {
  name = "${var.project_name}-${var.environment}-patch-alerts"
  tags = var.tags
}
```

### Email Subscription (Optional)

The email subscription is created only when `alert_email` is non-empty:

```hcl
resource "aws_sns_topic_subscription" "patch_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.patch_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

### Variable

| Variable | Default | Description |
|----------|---------|-------------|
| `alert_email` | `""` | Email address for patch alerts. If empty, no email subscription is created. |

Set in `terraform.tfvars`:

```hcl
alert_email = "ops-team@example.com"
```

---

## IAM Permissions

All three Lambdas that publish to SNS have `sns:Publish` on the patch-alerts topic:

| Lambda | IAM Policy |
|--------|------------|
| `aiops-r8-ssm-agent-health` | `sns:Publish` on `aws_sns_topic.patch_alerts.arn` |
| `aiops-r8-ssm-runner` | `sns:Publish` on `aws_sns_topic.patch_alerts.arn` |
| `aiops-r8-sfn-failure-notifier` | `sns:Publish` on `aws_sns_topic.patch_alerts.arn` |

---

## Email Subscription Confirmation

When `alert_email` is set and Terraform creates the subscription, AWS sends a **confirmation email** to that address. The recipient must click **Confirm subscription** before any alerts are delivered. Until confirmed, the subscription status is `PendingConfirmation`.

---

## Summary – Execution Order

| Order | Step | Lambda | SNS Alert When |
|-------|------|--------|----------------|
| 1 | CheckSSMAgentHealth | `ssm-agent-health` | Instances excluded (not SSM-managed) |
| 2 | ApplyPatches → PatchRHELBatch / PatchWindowsBatch | `ssm-runner` | CVE(s) blocked by circuit-breaker |
| 3 | Step Functions execution ends (FAILED/ABORTED/TIMED_OUT) | `sfn-failure-notifier` | Workflow execution failed |

All three alerts use the same SNS topic (`aiops-r8-{env}-patch-alerts`) and, when configured, the same email subscription.
