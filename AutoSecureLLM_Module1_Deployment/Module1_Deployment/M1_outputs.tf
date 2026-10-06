# =============================================================================
# TechCorp LLM Infrastructure - Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = aws_subnet.private[*].id
}

output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.llm_app.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository"
  value       = aws_ecr_repository.llm_app.arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

output "blue_target_group_arn" {
  description = "ARN of the blue target group (for blue-green deployment)"
  value       = aws_lb_target_group.blue.arn
}

output "green_target_group_arn" {
  description = "ARN of the green target group (for blue-green deployment)"
  value       = aws_lb_target_group.green.arn
}

output "llm_security_group_id" {
  description = "ID of the LLM inference security group"
  value       = aws_security_group.llm_inference.id
}

output "instance_role_arn" {
  description = "ARN of the IAM role for LLM instances"
  value       = aws_iam_role.llm_instance.arn
}

output "instance_profile_name" {
  description = "Name of the instance profile for LLM instances"
  value       = aws_iam_instance_profile.llm_instance.name
}

# =============================================================================
# Deployment Information
# =============================================================================

output "deployment_info" {
  description = "Summary of deployment configuration"
  value = {
    environment     = var.environment
    region          = var.aws_region
    instance_type   = var.instance_type
    model_name      = var.model_name
    model_version   = var.model_version
    api_endpoint    = "https://${aws_lb.main.dns_name}/v1/inference"
    health_endpoint = "https://${aws_lb.main.dns_name}/health"
  }
}
