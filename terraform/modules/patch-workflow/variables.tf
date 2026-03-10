# =============================================================================
# Patch Workflow Module - Variables
# =============================================================================

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for Lambda VPC config (if needed)"
  type        = list(string)
}

variable "rhel8_ids" {
  description = "List of RHEL8 EC2 instance IDs"
  type        = list(string)
}

variable "windows_ids" {
  description = "List of Windows EC2 instance IDs"
  type        = list(string)
}

variable "bedrock_model" {
  description = "Bedrock model ID (e.g., us.amazon.nova-2-lite-v1:0 for us-east-2)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "cve_block_ttl_days" {
  description = "Days to block a CVE after a patch caused reboot failure"
  type        = number
  default     = 7
}

variable "patch_correlation_minutes" {
  description = "Window (minutes) to correlate instance stop with recent patch"
  type        = number
  default     = 45
}

variable "ami_retention_days" {
  description = "Days to retain pre-patch AMIs before cleanup"
  type        = number
  default     = 7
}

variable "enable_auto_recovery" {
  description = "Enable automated recovery from AMI when patch causes boot failure"
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email for SNS patch alerts (optional)"
  type        = string
  default     = ""
}

variable "use_dynamic_discovery" {
  description = "Discover instances by tags at runtime (vs static Terraform IDs)"
  type        = bool
  default     = true
}

variable "batch_size" {
  description = "Instance batch size for batched patching (stop within run on failure)"
  type        = number
  default     = 10
}

variable "use_batched_patching" {
  description = "Use batched patching with mid-run failure detection"
  type        = bool
  default     = true
}

variable "dry_run" {
  description = "Dry-run mode: log only, no actual patching"
  type        = bool
  default     = false
}

variable "create_prepatch_ami" {
  description = "Create pre-patch AMIs before patching"
  type        = bool
  default     = true
}

variable "inspector_max_results" {
  description = "Max Inspector findings to fetch"
  type        = number
  default     = 500
}

variable "findings_summary_limit" {
  description = "Max findings to send to Bedrock"
  type        = number
  default     = 100
}

variable "ssm_chunk_size" {
  description = "Max instances per SSM command (AWS limit 50)"
  type        = number
  default     = 50
}

variable "maintenance_start_hour_utc" {
  description = "Maintenance window start hour (UTC)"
  type        = number
  default     = 2
}

variable "maintenance_end_hour_utc" {
  description = "Maintenance window end hour (UTC)"
  type        = number
  default     = 6
}

variable "check_maintenance_window" {
  description = "Skip patching if outside maintenance window"
  type        = bool
  default     = true
}

variable "canary_batch_size" {
  description = "First batch size for canary/phased rollout (0 = disabled)"
  type        = number
  default     = 0
}

variable "check_ssm_agent_health" {
  description = "Filter out instances not in SSM Managed state before patching"
  type        = bool
  default     = true
}
