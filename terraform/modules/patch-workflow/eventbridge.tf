# =============================================================================
# EventBridge - Schedules and event-driven triggers
# =============================================================================

# -----------------------------------------------------------------------------
# Patch workflow schedule (monthly, 2 AM UTC on 2nd Tuesday after Patch Tuesday)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "patch_schedule" {
  name                = "${var.project_name}-patch-schedule"
  description         = "Triggers CVE patch workflow monthly"
  schedule_expression = "cron(25 22 12 3 ? 2026)"
#  schedule_expression = "cron(0 2 ? * 3#2 *)"

# cron(45 16 13 3 ? 2026)
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "patch_workflow" {
  rule      = aws_cloudwatch_event_rule.patch_schedule.name
  target_id = "PatchWorkflow"
  arn       = aws_sfn_state_machine.patch_workflow.arn
  role_arn  = aws_iam_role.eventbridge.arn
}

# -----------------------------------------------------------------------------
# EC2 instance stopped (circuit-breaker failure detection)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "ec2_stopped" {
  name          = "${var.project_name}-${var.environment}-ec2-stopped-rule"
  description   = "Triggers circuit-breaker when EC2 instance stops (possible patch failure)"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["stopped"]
    }
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "ec2_stopped_lambda" {
  rule      = aws_cloudwatch_event_rule.ec2_stopped.name
  target_id = "Ec2StoppedHandler"
  arn       = aws_lambda_function.ec2_stopped_handler.arn
}

resource "aws_lambda_permission" "ec2_stopped_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ec2_stopped_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ec2_stopped.arn
}

# -----------------------------------------------------------------------------
# AMI cleanup schedule (daily, 3 AM UTC)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "ami_cleanup_schedule" {
  name                = "${var.project_name}-${var.environment}-ami-cleanup-schedule"
  description         = "Daily AMI cleanup for pre-patch backups"
  schedule_expression = "cron(0 3 ? * * *)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "ami_cleanup" {
  rule      = aws_cloudwatch_event_rule.ami_cleanup_schedule.name
  target_id = "AmiCleanup"
  arn       = aws_lambda_function.ami_cleanup.arn
}

resource "aws_lambda_permission" "ami_cleanup_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ami_cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ami_cleanup_schedule.arn
}

# -----------------------------------------------------------------------------
# Step Functions failure notification (SNS alert when workflow fails)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "sfn_failure" {
  name           = "${var.project_name}-${var.environment}-sfn-failure-rule"
  description    = "Trigger SNS alert when patch workflow Step Functions execution fails"
  event_bus_name = "default"

  event_pattern = jsonencode({
    source      = ["aws.states"]
    "detail-type" = ["Step Functions Execution Status Change"]
    detail = {
      status           = ["FAILED", "ABORTED", "TIMED_OUT"]
      stateMachineArn = [aws_sfn_state_machine.patch_workflow.arn]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "sfn_failure_notifier" {
  rule      = aws_cloudwatch_event_rule.sfn_failure.name
  target_id = "SfnFailureNotifier"
  arn       = aws_lambda_function.sfn_failure_notifier.arn
}

resource "aws_lambda_permission" "sfn_failure_notifier_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sfn_failure_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sfn_failure.arn
}
