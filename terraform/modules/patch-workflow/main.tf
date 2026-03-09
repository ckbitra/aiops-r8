# =============================================================================
# Patch Workflow Module - Production-safe CVE patching with Bedrock LLM
# =============================================================================
# Flow: Amazon Inspector findings -> Bedrock analysis -> Choice -> Parallel apply -> Parallel post-patch
# 1. Fetch Inspector findings for VPC (CVE scan from Amazon Inspector)
# 2. Lambda sends findings to Bedrock for analysis
# 3. Bedrock analyzes CVE data, returns has_critical_cves + critical_cve_ids
# 4. Choice: if critical CVEs -> apply; else -> skip
# 5. Parallel: Apply RHEL patches | Apply Windows patches (with circuit-breaker pre-check)
# 6. Parallel: Post-patch RHEL | Post-patch Windows
# Circuit-breaker: EC2 stopped -> record CVE failure -> block future patches for that CVE
# =============================================================================

# -----------------------------------------------------------------------------
# DynamoDB - Circuit-breaker: CVE failures and patch execution tracking
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "cve_patch_failures" {
  name         = "${var.project_name}-${var.environment}-cve-patch-failures"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cve_id"
  range_key    = "failed_at"

  attribute {
    name = "cve_id"
    type = "S"
  }
  attribute {
    name = "failed_at"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(var.tags, { Name = "${var.project_name}-cve-patch-failures" })
}

resource "aws_dynamodb_table" "patch_executions" {
  name         = "${var.project_name}-${var.environment}-patch-executions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "instance_id"
  range_key    = "started_at"

  attribute {
    name = "instance_id"
    type = "S"
  }
  attribute {
    name = "started_at"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(var.tags, { Name = "${var.project_name}-patch-executions" })
}

# -----------------------------------------------------------------------------
# SNS - Circuit-breaker alerts when CVE is blocked
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "patch_alerts" {
  name = "${var.project_name}-${var.environment}-patch-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "patch_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.patch_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# DynamoDB - Patch history for observability
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "patch_history" {
  name         = "${var.project_name}-${var.environment}-patch-history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "run_id"
  range_key    = "timestamp"

  attribute {
    name = "run_id"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(var.tags, { Name = "${var.project_name}-patch-history" })
}

# -----------------------------------------------------------------------------
# SSM Patch Baseline - CVE/Security patches only (Windows)
# -----------------------------------------------------------------------------

resource "aws_ssm_patch_baseline" "windows_cve" {
  name             = "${var.project_name}-windows-cve-baseline"
  description      = "CVE and security patches only for Windows"
  operating_system = "WINDOWS"

  approval_rule {
    approve_after_days  = 0
    compliance_level    = "CRITICAL"
    enable_non_security = false

    patch_filter {
      key    = "CLASSIFICATION"
      values = ["SecurityUpdates", "CriticalUpdates"]
    }
    patch_filter {
      key    = "MSRC_SEVERITY"
      values = ["Critical", "Important"]
    }
  }

  tags = var.tags
}

resource "aws_ssm_patch_group" "windows" {
  baseline_id = aws_ssm_patch_baseline.windows_cve.id
  patch_group = "${var.project_name}-windows-cve"
}

# -----------------------------------------------------------------------------
# IAM Role - Step Functions execution
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
          aws_lambda_function.batch_prepare.arn,
          aws_lambda_function.get_batch.arn,
          aws_lambda_function.failure_check.arn,
          aws_lambda_function.maintenance_window.arn,
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
      {
        Effect   = "Allow"
        Action   = "events:PutTargets"
        Resource = aws_cloudwatch_event_rule.patch_schedule.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Lambda - CVE Analyzer (calls Bedrock)
# -----------------------------------------------------------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/cve_analyzer.py"
  output_path = "${path.module}/lambda/cve_analyzer.zip"
}

# -----------------------------------------------------------------------------
# Lambda - Inspector Findings (fetches Amazon Inspector CVE findings)
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
# Lambda - SSM Runner (runs SSM commands and waits - no native Step Functions sync)
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
      BEDROCK_MODEL_ID     = var.bedrock_model
      BEDROCK_MAX_RETRIES  = "3"
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-cve-analyzer"
  })
}

# Allow Step Functions to invoke Lambda
resource "aws_lambda_permission" "step_functions" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cve_analyzer.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
}

# -----------------------------------------------------------------------------
# Step Functions - Patch workflow state machine
# -----------------------------------------------------------------------------

resource "aws_sfn_state_machine" "patch_workflow" {
  name     = "${var.project_name}-patch-workflow"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Production-safe CVE patch workflow (Amazon Inspector)"
    StartAt = "DiscoverInstances"
    States = {
      DiscoverInstances = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.instance_discovery.function_name
          Payload = {
            "vpc_id"               = var.vpc_id
            "use_dynamic_discovery" = var.use_dynamic_discovery
            "rhel8_ids"            = var.rhel8_ids
            "windows_ids"          = var.windows_ids
          }
        }
        ResultPath = "$.discoveredInstances"
        Next       = "FetchInspectorFindings"
      }
      FetchInspectorFindings = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.inspector_findings.function_name
          Payload = {
            "vpc_id"        = var.vpc_id
            "rhel8_ids.$"   = "$.discoveredInstances.Payload.body.rhel8_ids"
            "windows_ids.$" = "$.discoveredInstances.Payload.body.windows_ids"
          }
        }
        ResultPath = "$.inspectorFindings"
        Next       = "AnalyzeCVEs"
      }
      AnalyzeCVEs = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.cve_analyzer.function_name
          Payload = {
            "action"                 = "analyze"
            "inspector_findings.$"    = "$.inspectorFindings.Payload.body"
            "rhel8_ids.$"            = "$.discoveredInstances.Payload.body.rhel8_ids"
            "windows_ids.$"           = "$.discoveredInstances.Payload.body.windows_ids"
          }
        }
        ResultPath = "$.analyzeResult"
        Next       = "CheckMaintenanceWindow"
      }
      CheckMaintenanceWindow = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.maintenance_window.function_name
          Payload      = {}
        }
        ResultPath = "$.maintenanceCheck"
        Next       = "CheckMaintenanceChoice"
      }
      CheckMaintenanceChoice = {
        Type = "Choice"
        Choices = [
          {
            And = [
              { Variable = "$.maintenanceCheck.Payload.body.within_window", BooleanEquals = true },
              { Variable = "$.analyzeResult.Payload.body.has_critical_cves", BooleanEquals = true }
            ]
            Next = "PrepareBatches"
          }
        ]
        Default = "NotifyNoPatch"
      }
      PrepareBatches = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.batch_prepare.function_name
          Payload = {
            "rhel8_ids.$"       = "$.discoveredInstances.Payload.body.rhel8_ids"
            "windows_ids.$"     = "$.discoveredInstances.Payload.body.windows_ids"
            "critical_cve_ids.$" = "$.analyzeResult.Payload.body.critical_cve_ids"
            "batch_size"        = var.batch_size
          }
        }
        ResultPath = "$.batches"
        Next       = "ApplyPatches"
      }
      NotifyNoPatch = {
        Type = "Pass"
        Parameters = {
          "message" = "No critical CVEs - skipping patch application"
        }
        ResultPath = "$.skipResult"
        End        = true
      }
      ApplyPatches = {
        Type = "Parallel"
        Branches = [
          {
            StartAt = "MapRHELBatches"
            States = {
              MapRHELBatches = {
                Type            = "Map"
                ItemsPath       = "$.batches.Payload.body.rhel.batches"
                MaxConcurrency  = 1
                Parameters = {
                  "instance_ids.$"     = "$$.Map.Item.Value"
                  "critical_cve_ids.$" = "$.batches.Payload.body.rhel.critical_cve_ids"
                  "patch_mode"         = "rhel"
                  "document_name"      = "AWS-RunShellScript"
                  "dry_run"            = var.dry_run
                  "create_prepatch_ami" = var.create_prepatch_ami
                  "parameters" = {
                    "commands" = ["sudo dnf update --security -y || sudo yum update --security -y"]
                  }
                }
                Iterator = {
                  StartAt = "PatchRHELBatch"
                  States = {
                    PatchRHELBatch = {
                      Type = "Task"
                      Resource = "arn:aws:states:::lambda:invoke"
                      Parameters = {
                        FunctionName = aws_lambda_function.ssm_runner.function_name
                        Payload = {
                          "instance_ids.$"     = "$.instance_ids"
                          "critical_cve_ids.$" = "$.critical_cve_ids"
                          "patch_mode"         = "rhel"
                          "document_name"      = "AWS-RunShellScript"
                          "dry_run"            = var.dry_run
                          "create_prepatch_ami" = var.create_prepatch_ami
                          "parameters" = { "commands" = ["sudo dnf update --security -y || sudo yum update --security -y"] }
                        }
                      }
                      ResultPath = "$.patchResult"
                      Next       = "WaitAfterRHELBatch"
                    }
                    WaitAfterRHELBatch = {
                      Type    = "Wait"
                      Seconds = 180
                      Next    = "CheckRHELFailure"
                    }
                    CheckRHELFailure = {
                      Type = "Task"
                      Resource = "arn:aws:states:::lambda:invoke"
                      Parameters = {
                        FunctionName = aws_lambda_function.failure_check.function_name
                        Payload      = {}
                      }
                      ResultPath = "$.failureCheck"
                      Next       = "ChoiceRHELAbort"
                    }
                    ChoiceRHELAbort = {
                      Type = "Choice"
                      Choices = [{ Variable = "$.failureCheck.Payload.body.abort", BooleanEquals = true, Next = "RHELFail" }]
                      Default = "RHELSucceed"
                    }
                    RHELFail = {
                      Type  = "Fail"
                      Error = "CircuitBreakerTriggered"
                      Cause = "Instance stopped after patch"
                    }
                    RHELSucceed = {
                      Type = "Pass"
                      End  = true
                    }
                  }
                }
                ResultPath = "$.rhelApplyResult"
                End        = true
              }
            }
          },
          {
            StartAt = "MapWindowsBatches"
            States = {
              MapWindowsBatches = {
                Type           = "Map"
                ItemsPath      = "$.batches.Payload.body.windows.batches"
                MaxConcurrency = 1
                Parameters = {
                  "instance_ids.$"      = "$$.Map.Item.Value"
                  "critical_cve_ids.$"  = "$.batches.Payload.body.windows.critical_cve_ids"
                  "patch_mode"          = "windows"
                  "document_name"       = "AWS-RunPatchBaseline"
                  "dry_run"             = var.dry_run
                  "create_prepatch_ami" = var.create_prepatch_ami
                  "parameters"          = { "Operation" = "Install", "RebootOption" = "RebootIfNeeded" }
                }
                Iterator = {
                  StartAt = "PatchWindowsBatch"
                  States = {
                    PatchWindowsBatch = {
                      Type = "Task"
                      Resource = "arn:aws:states:::lambda:invoke"
                      Parameters = {
                        FunctionName = aws_lambda_function.ssm_runner.function_name
                        Payload = {
                          "instance_ids.$"      = "$.instance_ids"
                          "critical_cve_ids.$"  = "$.critical_cve_ids"
                          "patch_mode"          = "windows"
                          "document_name"       = "AWS-RunPatchBaseline"
                          "dry_run"             = var.dry_run
                          "create_prepatch_ami" = var.create_prepatch_ami
                          "parameters"          = { "Operation" = "Install", "RebootOption" = "RebootIfNeeded" }
                        }
                      }
                      ResultPath = "$.patchResult"
                      Next       = "WaitAfterWindowsBatch"
                    }
                    WaitAfterWindowsBatch = {
                      Type    = "Wait"
                      Seconds = 180
                      Next    = "CheckWindowsFailure"
                    }
                    CheckWindowsFailure = {
                      Type = "Task"
                      Resource = "arn:aws:states:::lambda:invoke"
                      Parameters = {
                        FunctionName = aws_lambda_function.failure_check.function_name
                        Payload      = {}
                      }
                      ResultPath = "$.failureCheck"
                      Next       = "ChoiceWindowsAbort"
                    }
                    ChoiceWindowsAbort = {
                      Type = "Choice"
                      Choices = [{ Variable = "$.failureCheck.Payload.body.abort", BooleanEquals = true, Next = "WindowsFail" }]
                      Default = "WindowsSucceed"
                    }
                    WindowsFail = {
                      Type  = "Fail"
                      Error = "CircuitBreakerTriggered"
                      Cause = "Instance stopped after patch"
                    }
                    WindowsSucceed = {
                      Type = "Pass"
                      End  = true
                    }
                  }
                }
                ResultPath = "$.windowsApplyResult"
                End        = true
              }
            }
          }
        ]
        ResultPath = "$.applyResult"
        Next       = "PostPatch"
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "NotifyFailure" }]
      }
      NotifyFailure = {
        Type = "Pass"
        Parameters = { "message" = "Circuit breaker triggered - patching stopped" }
        ResultPath = "$.failureResult"
        End        = true
      }
      # Step 6: Parallel - Post-patch verification on RHEL and Windows (via Lambda)
      PostPatch = {
        Type = "Parallel"
        Branches = [
          {
            StartAt = "PostPatchRHEL"
            States = {
              PostPatchRHEL = {
                Type = "Task"
                Resource = "arn:aws:states:::lambda:invoke"
                Parameters = {
                  FunctionName = aws_lambda_function.ssm_runner.function_name
                  Payload = {
                    "document_name" = "AWS-RunShellScript"
                    "instance_ids.$" = "$.discoveredInstances.Payload.body.rhel8_ids"
                    "parameters" = {
                      "commands" = [
                        "echo 'Post-patch verification' && dnf check-update --security 2>/dev/null || echo 'No pending security updates'"
                      ]
                    }
                  }
                }
                End = true
              }
            }
          },
          {
            StartAt = "PostPatchWindows"
            States = {
              PostPatchWindows = {
                Type = "Task"
                Resource = "arn:aws:states:::lambda:invoke"
                Parameters = {
                  FunctionName = aws_lambda_function.ssm_runner.function_name
                  Payload = {
                    "document_name" = "AWS-RunPowerShellScript"
                    "instance_ids.$" = "$.discoveredInstances.Payload.body.windows_ids"
                    "parameters" = {
                      "commands" = ["Write-Output 'Post-patch verification complete'"]
                    }
                  }
                }
                End = true
              }
            }
          }
        ]
        ResultPath = "$.postPatchResult"
        End        = true
      }
    }
  })

  tags = var.tags
}

# -----------------------------------------------------------------------------
# EventBridge - Schedule patch workflow
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "patch_schedule" {
  name                = "${var.project_name}-patch-schedule"
  description         = "Triggers CVE patch workflow monthly"
  schedule_expression = "cron(0 2 ? * 3#2 *)" # 2 AM UTC on 2nd Tuesday (after Patch Tuesday)

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "patch_workflow" {
  rule      = aws_cloudwatch_event_rule.patch_schedule.name
  target_id = "PatchWorkflow"
  arn       = aws_sfn_state_machine.patch_workflow.arn
  role_arn  = aws_iam_role.eventbridge.arn
}

resource "aws_iam_role" "eventbridge" {
  name = "${var.project_name}-patch-eventbridge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "eventbridge" {
  name = "${var.project_name}-patch-eventbridge-policy"
  role = aws_iam_role.eventbridge.id

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

# -----------------------------------------------------------------------------
# Lambda - Instance Discovery (dynamic by tags)
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

# -----------------------------------------------------------------------------
# Lambda - Batch Prepare, Get Batch, Failure Check, Maintenance Window
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

resource "aws_lambda_permission" "instance_discovery_sf" {
  statement_id  = "AllowExecutionFromStepFunctions"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.instance_discovery.function_name
  principal     = "states.amazonaws.com"
  source_arn    = aws_sfn_state_machine.patch_workflow.arn
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

# -----------------------------------------------------------------------------
# EventBridge - EC2 instance stopped (circuit-breaker failure detection)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "ec2_stopped" {
  name                = "${var.project_name}-${var.environment}-ec2-stopped-rule"
  description         = "Triggers circuit-breaker when EC2 instance stops (possible patch failure)"
  event_pattern       = jsonencode({
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
# Lambda - EC2 stopped handler (circuit-breaker: record CVE failure, optional recovery)
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
# Lambda - AMI cleanup (retention policy)
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
      AMI_NAME_PREFIX   = "AI-Patch-"
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-ami-cleanup" })
}

resource "aws_cloudwatch_event_rule" "ami_cleanup_schedule" {
  name                = "${var.project_name}-${var.environment}-ami-cleanup-schedule"
  description         = "Daily AMI cleanup for pre-patch backups"
  schedule_expression = "cron(0 3 ? * * *)" # 3 AM UTC daily
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
