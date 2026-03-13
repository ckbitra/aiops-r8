# =============================================================================
# Step Functions - Patch workflow state machine
# =============================================================================
# Definition is in workflow.asl.json.tftpl for easier editing and review.
# =============================================================================

resource "aws_sfn_state_machine" "patch_workflow" {
  name     = "${var.project_name}-patch-workflow"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/workflow.asl.json.tftpl", {
    instance_discovery_function   = aws_lambda_function.instance_discovery.function_name
    ssm_agent_health_function     = aws_lambda_function.ssm_agent_health.function_name
    inspector_findings_function   = aws_lambda_function.inspector_findings.function_name
    cve_analyzer_function         = aws_lambda_function.cve_analyzer.function_name
    maintenance_window_function   = aws_lambda_function.maintenance_window.function_name
    batch_prepare_function        = aws_lambda_function.batch_prepare.function_name
    patch_notifier_function       = aws_lambda_function.patch_notifier.function_name
    ssm_runner_function          = aws_lambda_function.ssm_runner.function_name
    failure_check_function       = aws_lambda_function.failure_check.function_name
    vpc_id                       = var.vpc_id
    use_dynamic_discovery         = var.use_dynamic_discovery
    rhel8_ids_json               = jsonencode(var.rhel8_ids)
    windows_ids_json             = jsonencode(var.windows_ids)
    batch_size                   = var.batch_size
    canary_batch_size            = var.canary_batch_size
    dry_run                      = var.dry_run
    create_prepatch_ami          = var.create_prepatch_ami
  })

  tags = var.tags
}
