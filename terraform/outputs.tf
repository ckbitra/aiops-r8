# =============================================================================
# AIOps R8 - Terraform Outputs
# =============================================================================

output "rhel8_instance_ids" {
  description = "List of RHEL8 EC2 instance IDs"
  value       = module.rhel8_servers[*].instance_id
}

output "rhel8_instance_private_ips" {
  description = "Private IP addresses of RHEL8 instances"
  value       = module.rhel8_servers[*].private_ip
}

output "windows_instance_ids" {
  description = "List of Windows EC2 instance IDs"
  value       = module.windows_servers[*].instance_id
}

output "windows_instance_private_ips" {
  description = "Private IP addresses of Windows instances"
  value       = module.windows_servers[*].private_ip
}

output "patch_workflow_state_machine_arn" {
  description = "ARN of the Step Functions state machine for patch workflow"
  value       = module.patch_workflow.state_machine_arn
}

output "patch_schedule_rule_arn" {
  description = "ARN of the EventBridge rule for patch scheduling"
  value       = module.patch_workflow.schedule_rule_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}
