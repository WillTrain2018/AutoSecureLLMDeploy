# =============================================================================
# TechCorp LLM Infrastructure - Variables
# =============================================================================

variable "project_name" {
  description = "Name of the project for resource naming"
  type        = string
  default     = "techcorp"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
  
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH (restrict in production)"
  type        = list(string)
  default     = ["10.0.0.0/16"]  # VPC only by default
}

# =============================================================================
# Compute Configuration
# =============================================================================

variable "instance_type" {
  description = "EC2 instance type for LLM inference"
  type        = string
  default     = "g5.xlarge"  # 1 GPU, 4 vCPU, 16GB RAM
  
  # Other options:
  # g5.2xlarge  - 1 GPU, 8 vCPU, 32GB RAM
  # g5.4xlarge  - 1 GPU, 16 vCPU, 64GB RAM
  # g5.12xlarge - 4 GPUs, 48 vCPU, 192GB RAM (for large models)
}

variable "gpu_ami_id" {
  description = "AMI ID for GPU instances (Deep Learning AMI recommended)"
  type        = string
  default     = ""  # Set based on region, e.g., Deep Learning AMI
}

variable "min_instances" {
  description = "Minimum number of inference instances"
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of inference instances"
  type        = number
  default     = 4
}

# =============================================================================
# Model Configuration
# =============================================================================

variable "model_bucket" {
  description = "S3 bucket containing model weights"
  type        = string
  default     = "techcorp-llm-models"
}

variable "model_name" {
  description = "Name of the LLM model to deploy"
  type        = string
  default     = "llama-3.1-8b"
}

variable "model_version" {
  description = "Version of the model"
  type        = string
  default     = "v1.0.0"
}

# =============================================================================
# Tags
# =============================================================================

variable "additional_tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
