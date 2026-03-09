# =============================================================================
# AIOps R8 - Main Terraform Configuration
# =============================================================================
# This is the root module that orchestrates all infrastructure components
# for the production-safe CVE patching workflow.
# =============================================================================

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Uncomment and configure for remote state
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "aiops-r8/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aiops-r8"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

# =============================================================================
# Data Sources - Fetch latest AMIs and availability zones
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# Amazon Inspector v2 - Enable EC2 vulnerability scanning
# =============================================================================
# Inspector scans EC2 instances for CVEs. Findings are fetched by the patch
# workflow Lambda and sent to Bedrock for analysis.
# =============================================================================

resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2"]

  # Inspector enable/disable can take 15+ min; default 5m often times out
  timeouts {
    create = "30m"
    delete = "30m"
  }
}

# =============================================================================
# VPC Module - Network foundation for EC2 instances
# =============================================================================

module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr

  tags = local.common_tags
}

# =============================================================================
# EC2 Modules - RHEL8 and Windows servers (free tier eligible)
# =============================================================================

module "rhel8_servers" {
  source = "./modules/ec2-rhel8"

  count = 2

  instance_name     = "${var.project_name}-rhel8-${count.index + 1}"
  subnet_id         = module.vpc.private_subnet_ids[count.index % length(module.vpc.private_subnet_ids)]
  vpc_id            = module.vpc.vpc_id
  security_group_id = module.vpc.default_security_group_id

  instance_type = var.rhel8_instance_type
  key_name      = var.key_name

  tags = merge(local.common_tags, {
    OS        = "rhel8"
    Role      = "patch-target"
    ServerNum = tostring(count.index + 1)
  })
}

module "windows_servers" {
  source = "./modules/ec2-windows"

  count = 2

  instance_name     = "${var.project_name}-windows-${count.index + 1}"
  subnet_id         = module.vpc.private_subnet_ids[count.index % length(module.vpc.private_subnet_ids)]
  vpc_id            = module.vpc.vpc_id
  security_group_id = module.vpc.default_security_group_id

  instance_type = var.windows_instance_type
  key_name      = var.key_name

  tags = merge(local.common_tags, {
    OS         = "windows"
    Role       = "patch-target"
    ServerNum  = tostring(count.index + 1)
    PatchGroup = "aiops-r8-windows-cve"
  })
}

# =============================================================================
# Patch Workflow Module - Lambda, EventBridge, Step Functions, SSM, Bedrock
# =============================================================================

module "patch_workflow" {
  source = "./modules/patch-workflow"

  project_name  = var.project_name
  environment   = var.environment
  vpc_id        = module.vpc.vpc_id
  subnet_ids    = module.vpc.private_subnet_ids
  rhel8_ids     = module.rhel8_servers[*].instance_id
  windows_ids   = module.windows_servers[*].instance_id
  bedrock_model = var.bedrock_model

  use_dynamic_discovery    = var.use_dynamic_discovery
  batch_size               = var.batch_size
  dry_run                  = var.dry_run
  create_prepatch_ami      = var.create_prepatch_ami
  check_maintenance_window = var.check_maintenance_window
  alert_email              = var.alert_email

  tags = local.common_tags

  depends_on = [aws_inspector2_enabler.main]
}
