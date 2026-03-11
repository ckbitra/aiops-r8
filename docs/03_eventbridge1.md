# When and How Step Functions Are Triggered

## Overview

Step Functions in this project are triggered in two ways: by EventBridge on a schedule (primary) and manually. A separate EventBridge rule listens for Step Functions execution failures and sends SNS alerts.

---

## 1. Scheduled Trigger (Primary)

**EventBridge** runs the patch workflow on a schedule:

- **Rule**: `aiops-r8-patch-schedule`
- **Schedule**: `cron(0 2 ? * 3#2 *)` → 2:00 AM UTC on the 2nd Tuesday of every month (after Patch Tuesday)
- **Target**: The Step Functions state machine `aiops-r8-patch-workflow`

Flow:

```
EventBridge rule (cron) → EventBridge target → Step Functions StartExecution
```

When the cron fires, EventBridge calls `states:StartExecution` on the state machine. The EventBridge role has permission to do this.

---

## 2. Failure Notification (EventBridge → SNS)

A second EventBridge rule listens for Step Functions execution status changes:

- **Rule**: `aiops-r8-{env}-sfn-failure-rule`
- **Event pattern**: `source=aws.states`, `detail-type=Step Functions Execution Status Change`, `status=FAILED|ABORTED|TIMED_OUT`
- **Target**: Lambda `aiops-r8-sfn-failure-notifier`
- **Purpose**: When the patch workflow fails, the Lambda publishes an SNS alert to the patch-alerts topic (same as circuit-breaker). If `alert_email` is configured, operators receive an email with execution details, error, and cause.

---

## 3. Manual Trigger

You can also start an execution manually:

```bash
aws stepfunctions start-execution \
  --state-machine-arn <STATE_MACHINE_ARN> \
  --input '{}'
```

Or via the AWS Console: Step Functions → select the state machine → Start execution.

---

## How the Trigger Works (Technical)

1. **EventBridge rule** (`aws_cloudwatch_event_rule.patch_schedule`):
   - Evaluates the cron expression
   - At 2:00 AM UTC on the 2nd Tuesday of each month, the rule matches

2. **EventBridge target** (`aws_cloudwatch_event_target.patch_workflow`):
   - Sends the event to the Step Functions state machine ARN
   - Uses the EventBridge role to call `StartExecution`

3. **Step Functions**:
   - Starts a new execution
   - Begins with the `FetchInspectorFindings` state (fetches CVE findings from Amazon Inspector)
   - Flow: Fetch Inspector findings → Analyze → Choice → Apply (parallel) → Post-patch (parallel)

---

## End-to-End Flow (Amazon Inspector)

```
EventBridge (cron: 2nd Tuesday of month, 2 AM UTC)
    │
    ▼
Step Functions: StartExecution
    │
    ├─► FetchInspectorFindings (Lambda inspector_findings → Inspector)
    ├─► AnalyzeCVEs (Lambda cve_analyzer → Bedrock)
    ├─► CheckCriticalCVEs (Choice)
    │   ├─► If critical: ApplyPatches (Lambda ssm_runner → SSM, Parallel)
    │   │   └─► PostPatch (Lambda ssm_runner → SSM, Parallel)
    │   └─► Else: NotifyNoPatch (skip)
    └─► End
```

EventBridge triggers Step Functions. CVE data comes from Amazon Inspector; SSM operations go through the SSM Runner Lambda.
