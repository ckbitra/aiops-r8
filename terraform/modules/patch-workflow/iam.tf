# =============================================================================
# IAM Roles - Step Functions and EventBridge (orchestration)
# =============================================================================
# Lambda IAM roles are defined in lambda.tf with their respective functions.
# =============================================================================

# -----------------------------------------------------------------------------
# Step Functions execution role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "step_functions" {
  name = "${var.project_name}-patch-stepfunctions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "step_functions" {
  name = "${var.project_name}-patch-stepfunctions-policy"
  role = aws_iam_role.step_functions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = [
          aws_lambda_function.cve_analyzer.arn,
          aws_lambda_function.ssm_runner.arn,
          aws_lambda_function.inspector_findings.arn,
          aws_lambda_function.instance_discovery.arn,
          aws_lambda_function.ssm_agent_health.arn,
          aws_lambda_function.batch_prepare.arn,
          aws_lambda_function.get_batch.arn,
          aws_lambda_function.failure_check.arn,
          aws_lambda_function.maintenance_window.arn,
          aws_lambda_function.patch_notifier.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations"
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# EventBridge Scheduler role (to start Step Functions on schedule, EDT timezone)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-patch-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.project_name}-patch-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.patch_workflow.arn
      }
    ]
  })
}
