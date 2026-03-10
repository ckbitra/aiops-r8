# =============================================================================
# AIOps R8 - Terraform Variables
# =============================================================================

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "aiops-r8"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "key_name" {
  description = "Name of the EC2 key pair for SSH/RDP access"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# EC2 Instance Configuration (Free Tier)
# -----------------------------------------------------------------------------

variable "rhel8_instance_type" {
  description = "EC2 instance type for RHEL8 servers (t2.micro/t3.micro for free tier)"
  type        = string
  default     = "t2.micro"
}

variable "windows_instance_type" {
  description = "EC2 instance type for Windows servers (t2.micro/t3.micro for free tier)"
  type        = string
  default     = "t2.micro"
}

# -----------------------------------------------------------------------------
# Bedrock Configuration
# -----------------------------------------------------------------------------

variable "bedrock_model" {
  description = "Bedrock model ID for CVE analysis (e.g., us.amazon.nova-2-lite-v1:0 for us-east-2)"
  type        = string
  default     = "us.amazon.nova-2-lite-v1:0"
}

variable "use_dynamic_discovery" {
  description = "Discover instances by tags at runtime"
  type        = bool
  default     = true
}

variable "batch_size" {
  description = "Instance batch size for batched patching"
  type        = number
  default     = 10
}

variable "dry_run" {
  description = "Dry-run mode: log only, no patching"
  type        = bool
  default     = false
}

variable "create_prepatch_ami" {
  description = "Create pre-patch AMIs before patching"
  type        = bool
  default     = true
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

variable "alert_email" {
  description = "Email for SNS patch alerts"
  type        = string
  default     = ""
}
