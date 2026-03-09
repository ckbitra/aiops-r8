# =============================================================================
# EC2 RHEL8 Module - Outputs
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.rhel8.id
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.rhel8.private_ip
}

output "instance_arn" {
  description = "EC2 instance ARN"
  value       = aws_instance.rhel8.arn
}
