# =============================================================================
# Patch Workflow Module - Production-safe CVE patching with Bedrock LLM
# =============================================================================
#
# This module is split across multiple files for maintainability:
#
#   dynamodb.tf       - Circuit-breaker tables, patch history
#   sns.tf            - Alert topic and email subscription
#   ssm.tf            - Windows patch baseline
#   iam.tf            - Step Functions and EventBridge roles
#   lambda.tf         - All Lambda functions (CVE analyzer, SSM runner, etc.)
#   step_functions.tf - Patch workflow state machine
#   eventbridge.tf    - Schedules and event triggers
#
# Flow: Amazon Inspector findings -> Bedrock analysis -> Choice -> Parallel apply
#       -> Parallel post-patch. Circuit-breaker blocks CVEs after reboot failure.
# =============================================================================
