# =============================================================================
# TechCorp LLM Infrastructure - Terraform Configuration
# =============================================================================
# This template provides the basic structure for your LLM deployment.
# Your task is to complete and customize this configuration.
# =============================================================================

terraform {
  required_version = ">= 1.0.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  # TODO: Configure remote backend for team collaboration
  # backend "s3" {
  #   bucket = "techcorp-terraform-state"
  #   key    = "llm-infrastructure/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project     = "TechCorp-LLM"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# =============================================================================
# VPC and Networking
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "${var.project_name}-vpc-${var.environment}"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  
  tags = {
    Name = "${var.project_name}-public-${count.index}-${var.environment}"
    Type = "Public"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]
  
  tags = {
    Name = "${var.project_name}-private-${count.index}-${var.environment}"
    Type = "Private"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "${var.project_name}-igw-${var.environment}"
  }
}

# =============================================================================
# Security Groups
# =============================================================================

resource "aws_security_group" "llm_inference" {
  name        = "${var.project_name}-llm-sg-${var.environment}"
  description = "Security group for LLM inference servers"
  vpc_id      = aws_vpc.main.id
  
  # HTTP for health checks
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "LLM API access from VPC"
  }
  
  # SSH for debugging (restrict in production)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
    description = "SSH access"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
  
  tags = {
    Name = "${var.project_name}-llm-sg-${var.environment}"
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg-${var.environment}"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from anywhere"
  }
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP redirect"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${var.project_name}-alb-sg-${var.environment}"
  }
}

# =============================================================================
# ECR Repository for Container Images
# =============================================================================

resource "aws_ecr_repository" "llm_app" {
  name                 = "${var.project_name}-llm-${var.environment}"
  image_tag_mutability = "MUTABLE"
  
  image_scanning_configuration {
    scan_on_push = true
  }
  
  encryption_configuration {
    encryption_type = "AES256"
  }
  
  tags = {
    Name = "${var.project_name}-llm-ecr-${var.environment}"
  }
}

# Lifecycle policy to clean up old images
resource "aws_ecr_lifecycle_policy" "llm_app" {
  repository = aws_ecr_repository.llm_app.name
  
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# =============================================================================
# EC2 Instance for LLM Inference (GPU)
# =============================================================================

# TODO: Uncomment and configure for actual deployment
# resource "aws_instance" "llm_inference" {
#   ami                    = var.gpu_ami_id
#   instance_type          = var.instance_type  # e.g., "g5.xlarge"
#   subnet_id              = aws_subnet.private[0].id
#   vpc_security_group_ids = [aws_security_group.llm_inference.id]
#   iam_instance_profile   = aws_iam_instance_profile.llm_instance.name
#   
#   root_block_device {
#     volume_size = 100
#     volume_type = "gp3"
#     encrypted   = true
#   }
#   
#   user_data = base64encode(templatefile("${path.module}/userdata.sh", {
#     ecr_repo = aws_ecr_repository.llm_app.repository_url
#     region   = var.aws_region
#   }))
#   
#   tags = {
#     Name = "${var.project_name}-llm-inference-${var.environment}"
#   }
# }

# =============================================================================
# Application Load Balancer
# =============================================================================

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  
  enable_deletion_protection = var.environment == "prod" ? true : false
  
  tags = {
    Name = "${var.project_name}-alb-${var.environment}"
  }
}

resource "aws_lb_target_group" "blue" {
  name        = "${var.project_name}-blue-${var.environment}"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/health"
    port                = "traffic-port"
    matcher             = "200"
  }
  
  tags = {
    Name        = "${var.project_name}-blue-tg-${var.environment}"
    Deployment  = "blue"
  }
}

resource "aws_lb_target_group" "green" {
  name        = "${var.project_name}-green-${var.environment}"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/health"
    port                = "traffic-port"
    matcher             = "200"
  }
  
  tags = {
    Name       = "${var.project_name}-green-tg-${var.environment}"
    Deployment = "green"
  }
}

# =============================================================================
# IAM Roles and Policies
# =============================================================================

resource "aws_iam_role" "llm_instance" {
  name = "${var.project_name}-llm-instance-role-${var.environment}"
  
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
  
  tags = {
    Name = "${var.project_name}-llm-instance-role-${var.environment}"
  }
}

resource "aws_iam_role_policy" "llm_instance" {
  name = "${var.project_name}-llm-instance-policy-${var.environment}"
  role = aws_iam_role.llm_instance.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${var.model_bucket}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "llm_instance" {
  name = "${var.project_name}-llm-instance-profile-${var.environment}"
  role = aws_iam_role.llm_instance.name
}
