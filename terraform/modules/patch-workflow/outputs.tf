# =============================================================================
# Patch Workflow Module - Outputs
# =============================================================================

output "state_machine_arn" {
  description = "ARN of the Step Functions state machine"
  value       = aws_sfn_state_machine.patch_workflow.arn
}

output "state_machine_name" {
  description = "Name of the Step Functions state machine"
  value       = aws_sfn_state_machine.patch_workflow.name
}

output "schedule_rule_arn" {
  description = "ARN of the EventBridge Scheduler schedule (patch workflow, EDT timezone)"
  value       = aws_scheduler_schedule.patch_workflow.arn
}

output "cve_analyzer_lambda_arn" {
  description = "ARN of the CVE analyzer Lambda function"
  value       = aws_lambda_function.cve_analyzer.arn
}

output "ssm_runner_lambda_arn" {
  description = "ARN of the SSM Runner Lambda function"
  value       = aws_lambda_function.ssm_runner.arn
}

output "inspector_findings_lambda_arn" {
  description = "ARN of the Inspector Findings Lambda function"
  value       = aws_lambda_function.inspector_findings.arn
}

output "patch_alerts_topic_arn" {
  description = "ARN of SNS topic for circuit-breaker patch alerts"
  value       = aws_sns_topic.patch_alerts.arn
}

output "sfn_failure_rule_arn" {
  description = "ARN of EventBridge rule for Step Functions failure notifications"
  value       = aws_cloudwatch_event_rule.sfn_failure.arn
}

output "cve_patch_failures_table" {
  description = "DynamoDB table for CVE patch failures (circuit-breaker)"
  value       = aws_dynamodb_table.cve_patch_failures.name
}

output "patch_executions_table" {
  description = "DynamoDB table for patch execution tracking"
  value       = aws_dynamodb_table.patch_executions.name
}
