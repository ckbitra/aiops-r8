# =============================================================================
# AIOps R8 - Local Values
# =============================================================================

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "aiops-cve-patching"
  }
}
