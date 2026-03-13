# =============================================================================
# SNS - Circuit-breaker alerts when CVE is blocked
# =============================================================================

resource "aws_sns_topic" "patch_alerts" {
  name = "${var.project_name}-${var.environment}-patch-alerts"
  tags = var.tags
}

# IMPORTANT: After terraform apply, AWS sends a confirmation email to alert_email.
# You MUST click the confirmation link in that email before any notifications will be delivered.
resource "aws_sns_topic_subscription" "patch_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.patch_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
