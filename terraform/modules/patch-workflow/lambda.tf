# =============================================================================
# Lambda Functions - CVE Analyzer, Inspector, SSM Runner, Discovery, etc.
# =============================================================================

# -----------------------------------------------------------------------------
# CVE Analyzer (calls Bedrock)
# -----------------------------------------------------------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/cve_analyzer.py"
  output_path = "${path.module}/lambda/cve_analyzer.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-cve-analyzer-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.project_name}-cve-analyzer-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "cve_analyzer" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.project_name}-cve-analyzer"
  role             = aws_iam_role.lambda.arn
  handler          = "cve_analyzer.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 60

  environment {
    variables = {
      BEDROCK_MODEL_ID    = var.bedrock_model
      BEDROCK_MAX_RETRIES = "3"
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-cve-analyzer" })
}

resource "aws_lambda_permission" "step_functions" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cve_analyzer.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

# -----------------------------------------------------------------------------
# Inspector Findings (fetches Amazon Inspector CVE findings)
# -----------------------------------------------------------------------------

data "archive_file" "inspector_findings_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/inspector_findings.py"
  output_path = "${path.module}/lambda/inspector_findings.zip"
}

resource "aws_iam_role" "inspector_findings_lambda" {
  name = "${var.project_name}-inspector-findings-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "inspector_findings_lambda" {
  name = "${var.project_name}-inspector-findings-policy"
  role = aws_iam_role.inspector_findings_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["inspector2:ListFindings"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "inspector_findings" {
  filename         = data.archive_file.inspector_findings_zip.output_path
  function_name    = "${var.project_name}-inspector-findings"
  role             = aws_iam_role.inspector_findings_lambda.arn
  handler          = "inspector_findings.lambda_handler"
  source_code_hash = data.archive_file.inspector_findings_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 60

  environment {
    variables = {
      INSPECTOR_MAX_RESULTS  = tostring(var.inspector_max_results)
      FINDINGS_SUMMARY_LIMIT = tostring(var.findings_summary_limit)
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-inspector-findings" })
}

resource "aws_lambda_permission" "inspector_findings_step_functions" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.inspector_findings.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

# -----------------------------------------------------------------------------
# SSM Runner (runs SSM commands and waits)
# -----------------------------------------------------------------------------

data "archive_file" "ssm_runner_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/ssm_runner.py"
  output_path = "${path.module}/lambda/ssm_runner.zip"
}

resource "aws_iam_role" "ssm_runner_lambda" {
  name = "${var.project_name}-ssm-runner-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "ssm_runner_lambda" {
  name = "${var.project_name}-ssm-runner-policy"
  role = aws_iam_role.ssm_runner_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query", "dynamodb:BatchWriteItem"]
        Resource = [aws_dynamodb_table.cve_patch_failures.arn, aws_dynamodb_table.patch_executions.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.patch_alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateImage", "ec2:DescribeImages", "ec2:DeregisterImage", "ec2:DescribeSnapshots", "ec2:DeleteSnapshot"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "ssm_runner" {
  filename         = data.archive_file.ssm_runner_zip.output_path
  function_name    = "${var.project_name}-ssm-runner"
  role             = aws_iam_role.ssm_runner_lambda.arn
  handler          = "ssm_runner.lambda_handler"
  source_code_hash = data.archive_file.ssm_runner_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 300

  environment {
    variables = {
      PATCH_FAILURES_TABLE      = aws_dynamodb_table.cve_patch_failures.name
      PATCH_EXECUTIONS_TABLE    = aws_dynamodb_table.patch_executions.name
      PATCH_ALERTS_TOPIC_ARN    = aws_sns_topic.patch_alerts.arn
      CVE_BLOCK_TTL_DAYS        = tostring(var.cve_block_ttl_days)
      PATCH_CORRELATION_MINUTES = tostring(var.patch_correlation_minutes)
      AMI_RETENTION_DAYS        = tostring(var.ami_retention_days)
      SSM_CHUNK_SIZE            = tostring(var.ssm_chunk_size)
      METRIC_NAMESPACE          = "AIOps/Patch"
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-ssm-runner" })
}

resource "aws_lambda_permission" "ssm_runner_step_functions" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ssm_runner.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

# -----------------------------------------------------------------------------
# Instance Discovery (dynamic by tags)
# -----------------------------------------------------------------------------

data "archive_file" "instance_discovery_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/instance_discovery.py"
  output_path = "${path.module}/lambda/instance_discovery.zip"
}

resource "aws_iam_role" "instance_discovery_lambda" {
  name = "${var.project_name}-instance-discovery-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "instance_discovery_lambda" {
  name   = "${var.project_name}-instance-discovery-policy"
  role   = aws_iam_role.instance_discovery_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:DescribeInstances"], Resource = "*" },
    ]
  })
}

resource "aws_lambda_function" "instance_discovery" {
  filename         = data.archive_file.instance_discovery_zip.output_path
  function_name    = "${var.project_name}-instance-discovery"
  role             = aws_iam_role.instance_discovery_lambda.arn
  handler          = "instance_discovery.lambda_handler"
  source_code_hash = data.archive_file.instance_discovery_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  environment {
    variables = { VPC_ID = var.vpc_id }
  }
  tags = merge(var.tags, { Name = "${var.project_name}-instance-discovery" })
}

resource "aws_lambda_permission" "instance_discovery_sf" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.instance_discovery.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

# -----------------------------------------------------------------------------
# SSM Agent Health (filter instances not in Managed state)
# -----------------------------------------------------------------------------

data "archive_file" "ssm_agent_health_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/ssm_agent_health.py"
  output_path = "${path.module}/lambda/ssm_agent_health.zip"
}

resource "aws_iam_role" "ssm_agent_health_lambda" {
  name = "${var.project_name}-ssm-agent-health-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "ssm_agent_health_lambda" {
  name   = "${var.project_name}-ssm-agent-health-policy"
  role   = aws_iam_role.ssm_agent_health_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
      { Effect = "Allow", Action = ["ssm:DescribeInstanceInformation"], Resource = "*" },
      { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.patch_alerts.arn },
    ]
  })
}

resource "aws_lambda_function" "ssm_agent_health" {
  filename         = data.archive_file.ssm_agent_health_zip.output_path
  function_name    = "${var.project_name}-ssm-agent-health"
  role             = aws_iam_role.ssm_agent_health_lambda.arn
  handler          = "ssm_agent_health.lambda_handler"
  source_code_hash = data.archive_file.ssm_agent_health_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  environment {
    variables = {
      PATCH_ALERTS_TOPIC_ARN = aws_sns_topic.patch_alerts.arn
      CHECK_SSM_AGENT_HEALTH = tostring(var.check_ssm_agent_health)
    }
  }
  tags = merge(var.tags, { Name = "${var.project_name}-ssm-agent-health" })
}

resource "aws_lambda_permission" "ssm_agent_health_sf" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ssm_agent_health.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

# -----------------------------------------------------------------------------
# Batch Prepare, Get Batch, Failure Check, Maintenance Window
# -----------------------------------------------------------------------------

data "archive_file" "batch_prepare_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/batch_prepare.py"
  output_path = "${path.module}/lambda/batch_prepare.zip"
}

data "archive_file" "get_batch_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/get_batch.py"
  output_path = "${path.module}/lambda/get_batch.zip"
}

data "archive_file" "failure_check_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/failure_check.py"
  output_path = "${path.module}/lambda/failure_check.zip"
}

data "archive_file" "maintenance_window_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/maintenance_window.py"
  output_path = "${path.module}/lambda/maintenance_window.zip"
}

resource "aws_iam_role" "batch_lambdas" {
  name = "${var.project_name}-batch-lambdas-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "failure_check_lambda" {
  name   = "${var.project_name}-failure-check-policy"
  role   = aws_iam_role.batch_lambdas.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
      { Effect = "Allow", Action = ["dynamodb:Scan"], Resource = aws_dynamodb_table.patch_executions.arn },
      { Effect = "Allow", Action = ["ec2:DescribeInstances"], Resource = "*" },
    ]
  })
}

resource "aws_lambda_function" "batch_prepare" {
  filename         = data.archive_file.batch_prepare_zip.output_path
  function_name    = "${var.project_name}-batch-prepare"
  role             = aws_iam_role.batch_lambdas.arn
  handler          = "batch_prepare.lambda_handler"
  source_code_hash = data.archive_file.batch_prepare_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 10
  tags = merge(var.tags, { Name = "${var.project_name}-batch-prepare" })
}

resource "aws_lambda_function" "get_batch" {
  filename         = data.archive_file.get_batch_zip.output_path
  function_name    = "${var.project_name}-get-batch"
  role             = aws_iam_role.batch_lambdas.arn
  handler          = "get_batch.lambda_handler"
  source_code_hash = data.archive_file.get_batch_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 10
  tags = merge(var.tags, { Name = "${var.project_name}-get-batch" })
}

resource "aws_lambda_function" "failure_check" {
  filename         = data.archive_file.failure_check_zip.output_path
  function_name    = "${var.project_name}-failure-check"
  role             = aws_iam_role.batch_lambdas.arn
  handler          = "failure_check.lambda_handler"
  source_code_hash = data.archive_file.failure_check_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  environment {
    variables = {
      PATCH_EXECUTIONS_TABLE    = aws_dynamodb_table.patch_executions.name
      PATCH_CORRELATION_MINUTES = tostring(var.patch_correlation_minutes)
    }
  }
  tags = merge(var.tags, { Name = "${var.project_name}-failure-check" })
}

resource "aws_lambda_function" "maintenance_window" {
  filename         = data.archive_file.maintenance_window_zip.output_path
  function_name    = "${var.project_name}-maintenance-window"
  role             = aws_iam_role.batch_lambdas.arn
  handler          = "maintenance_window.lambda_handler"
  source_code_hash = data.archive_file.maintenance_window_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 10
  environment {
    variables = {
      MAINTENANCE_START_HOUR_UTC = tostring(var.maintenance_start_hour_utc)
      MAINTENANCE_END_HOUR_UTC   = tostring(var.maintenance_end_hour_utc)
      CHECK_MAINTENANCE_WINDOW   = tostring(var.check_maintenance_window)
    }
  }
  tags = merge(var.tags, { Name = "${var.project_name}-maintenance-window" })
}

resource "aws_lambda_permission" "batch_prepare_sf" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.batch_prepare.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

resource "aws_lambda_permission" "get_batch_sf" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_batch.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

resource "aws_lambda_permission" "failure_check_sf" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failure_check.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

resource "aws_lambda_permission" "maintenance_window_sf" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.maintenance_window.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

resource "aws_lambda_permission" "patch_notifier_sf" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.patch_notifier.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

# -----------------------------------------------------------------------------
# EC2 stopped handler (circuit-breaker: record CVE failure, optional recovery)
# -----------------------------------------------------------------------------

data "archive_file" "ec2_stopped_handler_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/ec2_stopped_handler.py"
  output_path = "${path.module}/lambda/ec2_stopped_handler.zip"
}

resource "aws_iam_role" "ec2_stopped_handler_lambda" {
  name = "${var.project_name}-ec2-stopped-handler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "ec2_stopped_handler_lambda" {
  name = "${var.project_name}-ec2-stopped-handler-policy"
  role = aws_iam_role.ec2_stopped_handler_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query", "dynamodb:DeleteItem"]
        Resource = [aws_dynamodb_table.cve_patch_failures.arn, aws_dynamodb_table.patch_executions.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeImages", "ec2:RunInstances", "ec2:DescribeInstances", "ec2:CreateTags"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "ec2_stopped_handler" {
  filename         = data.archive_file.ec2_stopped_handler_zip.output_path
  function_name    = "${var.project_name}-ec2-stopped-handler"
  role             = aws_iam_role.ec2_stopped_handler_lambda.arn
  handler          = "ec2_stopped_handler.lambda_handler"
  source_code_hash = data.archive_file.ec2_stopped_handler_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 60

  environment {
    variables = {
      PATCH_FAILURES_TABLE      = aws_dynamodb_table.cve_patch_failures.name
      PATCH_EXECUTIONS_TABLE   = aws_dynamodb_table.patch_executions.name
      PATCH_CORRELATION_MINUTES = tostring(var.patch_correlation_minutes)
      ENABLE_AUTO_RECOVERY     = tostring(var.enable_auto_recovery)
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-ec2-stopped-handler" })
}

# -----------------------------------------------------------------------------
# AMI cleanup (retention policy)
# -----------------------------------------------------------------------------

data "archive_file" "ami_cleanup_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/ami_cleanup.py"
  output_path = "${path.module}/lambda/ami_cleanup.zip"
}

resource "aws_iam_role" "ami_cleanup_lambda" {
  name = "${var.project_name}-ami-cleanup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "ami_cleanup_lambda" {
  name = "${var.project_name}-ami-cleanup-policy"
  role = aws_iam_role.ami_cleanup_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeImages", "ec2:DeregisterImage", "ec2:DescribeSnapshots", "ec2:DeleteSnapshot"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "ami_cleanup" {
  filename         = data.archive_file.ami_cleanup_zip.output_path
  function_name    = "${var.project_name}-ami-cleanup"
  role             = aws_iam_role.ami_cleanup_lambda.arn
  handler          = "ami_cleanup.lambda_handler"
  source_code_hash = data.archive_file.ami_cleanup_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 300

  environment {
    variables = {
      AMI_RETENTION_DAYS = tostring(var.ami_retention_days)
      AMI_NAME_PREFIX    = "AI-Patch-"
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-ami-cleanup" })
}

# -----------------------------------------------------------------------------
# Patch Notifier (SNS email when patching starts and completes)
# -----------------------------------------------------------------------------

data "archive_file" "patch_notifier_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/patch_notifier.py"
  output_path = "${path.module}/lambda/patch_notifier.zip"
}

resource "aws_iam_role" "patch_notifier_lambda" {
  name = "${var.project_name}-patch-notifier-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "patch_notifier_lambda" {
  name = "${var.project_name}-patch-notifier-policy"
  role = aws_iam_role.patch_notifier_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.patch_alerts.arn
      }
    ]
  })
}

resource "aws_lambda_function" "patch_notifier" {
  filename         = data.archive_file.patch_notifier_zip.output_path
  function_name    = "${var.project_name}-patch-notifier"
  role             = aws_iam_role.patch_notifier_lambda.arn
  handler          = "patch_notifier.lambda_handler"
  source_code_hash = data.archive_file.patch_notifier_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      PATCH_ALERTS_TOPIC_ARN = aws_sns_topic.patch_alerts.arn
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-patch-notifier" })
}

# -----------------------------------------------------------------------------
# Step Functions Failure Notifier (SNS alert when workflow fails)
# -----------------------------------------------------------------------------

data "archive_file" "sfn_failure_notifier_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/sfn_failure_notifier.py"
  output_path = "${path.module}/lambda/sfn_failure_notifier.zip"
}

resource "aws_iam_role" "sfn_failure_notifier_lambda" {
  name = "${var.project_name}-sfn-failure-notifier-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "sfn_failure_notifier_lambda" {
  name = "${var.project_name}-sfn-failure-notifier-policy"
  role = aws_iam_role.sfn_failure_notifier_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.patch_alerts.arn
      }
    ]
  })
}

resource "aws_lambda_function" "sfn_failure_notifier" {
  filename         = data.archive_file.sfn_failure_notifier_zip.output_path
  function_name    = "${var.project_name}-sfn-failure-notifier"
  role             = aws_iam_role.sfn_failure_notifier_lambda.arn
  handler          = "sfn_failure_notifier.lambda_handler"
  source_code_hash = data.archive_file.sfn_failure_notifier_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      PATCH_ALERTS_TOPIC_ARN = aws_sns_topic.patch_alerts.arn
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-sfn-failure-notifier" })
}
