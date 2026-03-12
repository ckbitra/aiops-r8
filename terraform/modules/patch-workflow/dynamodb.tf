# =============================================================================
# DynamoDB - Circuit-breaker and patch tracking
# =============================================================================

# -----------------------------------------------------------------------------
# Circuit-breaker: CVE failures (blocks future patches for failed CVEs)
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

# -----------------------------------------------------------------------------
# Patch execution tracking (correlates EC2 stops with patch runs)
# -----------------------------------------------------------------------------

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
# Patch history for observability
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
