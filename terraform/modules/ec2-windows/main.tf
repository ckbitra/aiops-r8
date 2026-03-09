# =============================================================================
# EC2 Windows Module - Free tier eligible Windows Server instances
# =============================================================================
# Creates Windows Server instances for CVE patching. Uses SSM for management.
# Instance type t2.micro is free tier eligible (750 hrs/month for Windows).
# =============================================================================

# -----------------------------------------------------------------------------
# Data Source - Fetch latest Windows Server 2022 AMI (Amazon owner)
# -----------------------------------------------------------------------------

data "aws_ami" "windows" {
  most_recent = true
  owners      = ["801119661308"] # Amazon

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
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

resource "aws_iam_role" "windows" {
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

resource "aws_iam_role_policy_attachment" "windows_ssm" {
  role       = aws_iam_role.windows.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "windows" {
  name = "${var.instance_name}-profile"
  role = aws_iam_role.windows.name
}

# -----------------------------------------------------------------------------
# EC2 Instance - Windows Server
# -----------------------------------------------------------------------------

resource "aws_instance" "windows" {
  ami                    = data.aws_ami.windows.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.windows.name
  key_name               = var.key_name != "" ? var.key_name : null

  root_block_device {
    volume_size           = 30
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
