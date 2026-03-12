# =============================================================================
# SNS - Circuit-breaker alerts when CVE is blocked
# =============================================================================

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
