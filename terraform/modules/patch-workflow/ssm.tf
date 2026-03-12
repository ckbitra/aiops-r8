# =============================================================================
# SSM Patch Baseline - CVE/Security patches only (Windows)
# =============================================================================

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
  baseline_id  = aws_ssm_patch_baseline.windows_cve.id
  patch_group = "${var.project_name}-windows-cve"
}
