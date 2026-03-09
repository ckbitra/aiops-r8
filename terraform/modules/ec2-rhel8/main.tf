# =============================================================================
# EC2 RHEL8 Module - Free tier eligible RHEL8 servers
# =============================================================================
# Creates RHEL8 instances for CVE patching. Uses SSM for management.
# Instance type t2.micro is free tier eligible (750 hrs/month).
# =============================================================================

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Data Source - Fetch latest RHEL 8 AMI (Red Hat owner)
# -----------------------------------------------------------------------------

data "aws_ami" "rhel8" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-8*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# -----------------------------------------------------------------------------
# IAM Instance Profile - For SSM managed instances
# -----------------------------------------------------------------------------

resource "aws_iam_role" "rhel8" {
  name = "${var.instance_name}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rhel8_ssm" {
  role       = aws_iam_role.rhel8.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "rhel8" {
  name = "${var.instance_name}-profile"
  role = aws_iam_role.rhel8.name
}

# -----------------------------------------------------------------------------
# EC2 Instance - RHEL8
# -----------------------------------------------------------------------------

resource "aws_instance" "rhel8" {
  ami                    = data.aws_ami.rhel8.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.rhel8.name
  key_name               = var.key_name != "" ? var.key_name : null

  # RHEL 8 AMIs do NOT include SSM agent pre-installed (unlike Windows/Amazon Linux).
  # Install and enable it at boot so instances register with Systems Manager.
  user_data = <<-EOT
    #!/bin/bash
    set -e
    dnf install -y "https://s3.${data.aws_region.current.name}.amazonaws.com/amazon-ssm-${data.aws_region.current.name}/latest/linux_amd64/amazon-ssm-agent.rpm"
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOT

  root_block_device {
    volume_size           = 10
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
  }

  tags = merge(var.tags, {
    Name = var.instance_name
  })

  lifecycle {
    ignore_changes = [ami]
  }
}
