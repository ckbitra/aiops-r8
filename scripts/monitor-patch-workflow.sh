#!/bin/bash
# =============================================================================
# AIOps R8 - Patch Workflow Monitoring Script
# =============================================================================
# Gathers variables, fetches EventBridge rule, Step Functions executions,
# and CloudWatch metrics for the patch workflow.
#
# Usage:
#   ./monitor-patch-workflow.sh              # Full monitoring report
#   ./monitor-patch-workflow.sh <execution-id>  # Details for specific execution
#
# Environment variables (optional):
#   PROJECT_NAME   Default: aiops-r8
#   ENVIRONMENT    Default: prod
#   AWS_REGION     Default: us-east-2
#
# Prerequisites: AWS CLI configured (aws configure or aws sso login)
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Configuration (override via environment variables)
# -----------------------------------------------------------------------------
PROJECT_NAME="${PROJECT_NAME:-aiops-r8}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# Derived resource names
STATE_MACHINE_NAME="${PROJECT_NAME}-patch-workflow"
PATCH_SCHEDULE_RULE="${PROJECT_NAME}-patch-schedule"
EC2_STOPPED_RULE="${PROJECT_NAME}-${ENVIRONMENT}-ec2-stopped-rule"
SFN_FAILURE_RULE="${PROJECT_NAME}-${ENVIRONMENT}-sfn-failure-rule"

# -----------------------------------------------------------------------------
# Gather variables from Terraform or AWS
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

# Try to get values from Terraform output if available
get_terraform_output() {
  local output_name="$1"
  if [[ -d "$TERRAFORM_DIR" ]]; then
    (cd "$TERRAFORM_DIR" && terraform output -raw "$output_name" 2>/dev/null) || true
  fi
}

# Gather AWS account and region
echo "=== Gathering AWS context ==="
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "ERROR: AWS CLI not configured or not authenticated. Run 'aws configure' or 'aws sso login'."
  exit 1
}

# Try Terraform first for state machine ARN
STATE_MACHINE_ARN=$(get_terraform_output "patch_workflow_state_machine_arn")
if [[ -z "$STATE_MACHINE_ARN" ]]; then
  STATE_MACHINE_ARN="arn:aws:states:${AWS_REGION}:${AWS_ACCOUNT_ID}:stateMachine:${STATE_MACHINE_NAME}"
fi

echo "  Project:      $PROJECT_NAME"
echo "  Environment:  $ENVIRONMENT"
echo "  Region:       $AWS_REGION"
echo "  Account:      $AWS_ACCOUNT_ID"
echo "  State Machine: $STATE_MACHINE_NAME"
echo ""

# -----------------------------------------------------------------------------
# 1. EventBridge - Patch Schedule Rule
# -----------------------------------------------------------------------------
echo "=== 1. EventBridge - Patch Schedule Rule ($PATCH_SCHEDULE_RULE) ==="
if aws events describe-rule --name "$PATCH_SCHEDULE_RULE" --region "$AWS_REGION" &>/dev/null; then
  aws events describe-rule --name "$PATCH_SCHEDULE_RULE" --region "$AWS_REGION" \
    --query '{Name:Name,State:State,ScheduleExpression:ScheduleExpression,Description:Description}' \
    --output table
else
  echo "  Rule not found or not accessible."
fi
echo ""

# -----------------------------------------------------------------------------
# 2. EventBridge - Rule Metrics (last 24 hours)
# -----------------------------------------------------------------------------
echo "=== 2. EventBridge - Patch Schedule Invocations (last 24h) ==="
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EPOCH_24H_AGO=$(($(date +%s) - 86400))
START_TIME=$(date -u -d "@${EPOCH_24H_AGO}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || date -u -r "${EPOCH_24H_AGO}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null

if aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name Invocations \
  --dimensions Name=RuleName,Value="$PATCH_SCHEDULE_RULE" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 3600 \
  --statistics Sum \
  --region "$AWS_REGION" \
  --query 'Datapoints[*].[Timestamp,Sum]' \
  --output table 2>/dev/null; then
  :
else
  echo "  No metrics or rule not found."
fi
echo ""

# -----------------------------------------------------------------------------
# 3. Step Functions - Recent Executions
# -----------------------------------------------------------------------------
echo "=== 3. Step Functions - Recent Executions (last 10) ==="
aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --region "$AWS_REGION" \
  --max-results 10 \
  --query 'executions[*].[name,status,startDate,stopDate]' \
  --output table 2>/dev/null || echo "  No executions or state machine not found."
echo ""

# -----------------------------------------------------------------------------
# 4. Step Functions - Execution Details (last run)
# -----------------------------------------------------------------------------
echo "=== 4. Step Functions - Last Execution Details ==="
LAST_EXEC_ARN=$(aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --region "$AWS_REGION" \
  --max-results 1 \
  --query 'executions[0].executionArn' \
  --output text 2>/dev/null)

if [[ -n "$LAST_EXEC_ARN" && "$LAST_EXEC_ARN" != "None" ]]; then
  aws stepfunctions describe-execution \
    --execution-arn "$LAST_EXEC_ARN" \
    --region "$AWS_REGION" \
    --query '{Name:name,Status:status,StartDate:startDate,StopDate:stopDate,Input:input,Output:output}' \
    --output json 2>/dev/null | head -50
else
  echo "  No executions found."
fi
echo ""

# -----------------------------------------------------------------------------
# 5. Lambda Log Groups (list)
# -----------------------------------------------------------------------------
echo "=== 5. Lambda Log Groups (aiops-r8) ==="
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/${PROJECT_NAME}" \
  --region "$AWS_REGION" \
  --query 'logGroups[*].logGroupName' \
  --output table 2>/dev/null || echo "  No log groups found."
echo ""

# -----------------------------------------------------------------------------
# 6. Console URLs
# -----------------------------------------------------------------------------
echo "=== 6. Quick Links (AWS Console) ==="
echo "  Step Functions:  https://${AWS_REGION}.console.aws.amazon.com/states/home?region=${AWS_REGION}#/statemachines/view/${STATE_MACHINE_ARN}"
echo "  EventBridge:     https://${AWS_REGION}.console.aws.amazon.com/events/home?region=${AWS_REGION}#/rules"
echo "  CloudWatch:     https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#logsV2:log-groups"
echo ""

# -----------------------------------------------------------------------------
# 7. Optional: Describe execution (if --exec-id passed)
# -----------------------------------------------------------------------------
if [[ -n "$1" ]]; then
  EXEC_ID="$1"
  echo "=== 7. Execution Details for: $EXEC_ID ==="
  EXEC_ARN="arn:aws:states:${AWS_REGION}:${AWS_ACCOUNT_ID}:execution:${STATE_MACHINE_NAME}:${EXEC_ID}"
  aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --region "$AWS_REGION" --output json || true
fi

echo "=== Monitoring complete ==="
