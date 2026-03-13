# =============================================================================
# AIOps R8 - Terraform Variables
# =============================================================================

aws_region   = "us-east-2"
environment  = "prod"
project_name = "aiops-r8"

# Instance types (t2.micro for free tier)
rhel8_instance_type   = "t2.micro"
windows_instance_type = "t2.micro"

# Bedrock model for CVE analysis
bedrock_model = "us.amazon.nova-2-lite-v1:0"

# SNS patch alerts - email for circuit-breaker, patching started/completed notifications
# After terraform apply, confirm the subscription via the email AWS sends
alert_email = "cbitra@gmail.com"
