# =============================================================================
# EC2 Windows Module - Outputs
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.windows.id
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.windows.private_ip
}

output "instance_arn" {
  description = "EC2 instance ARN"
  value       = aws_instance.windows.arn
}
