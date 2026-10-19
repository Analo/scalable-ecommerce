variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the external ALB and bastion"
  type        = list(string)
}

variable "private_web_subnet_ids" {
  description = "List of private web subnet IDs for the web tier ASG"
  type        = list(string)
}

variable "private_app_subnet_ids" {
  description = "List of private app subnet IDs for the app tier ASG"
  type        = list(string)
}

variable "alb_external_sg_id" {
  description = "Security group ID for the external ALB"
  type        = string
}

variable "alb_internal_sg_id" {
  description = "Security group ID for the internal ALB"
  type        = string
}

variable "web_tier_sg_id" {
  description = "Security group ID for web tier instances"
  type        = string
}

variable "app_tier_sg_id" {
  description = "Security group ID for app tier instances"
  type        = string
}

variable "bastion_sg_id" {
  description = "Security group ID for the bastion host"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for EC2 instances (Amazon Linux 2023)"
  type        = string
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair for SSH access"
  type        = string
}

variable "web_instance_type" {
  description = "Instance type for web tier"
  type        = string
  default     = "t3.micro"
}

variable "app_instance_type" {
  description = "Instance type for app tier"
  type        = string
  default     = "t3.small"
}

variable "bastion_instance_type" {
  description = "Instance type for bastion host"
  type        = string
  default     = "t3.micro"
}

variable "web_min_size" {
  description = "Minimum number of web tier instances"
  type        = number
  default     = 2
}

variable "web_max_size" {
  description = "Maximum number of web tier instances"
  type        = number
  default     = 10
}

variable "web_desired_capacity" {
  description = "Desired number of web tier instances"
  type        = number
  default     = 2
}

variable "app_min_size" {
  description = "Minimum number of app tier instances"
  type        = number
  default     = 2
}

variable "app_max_size" {
  description = "Maximum number of app tier instances"
  type        = number
  default     = 10
}

variable "app_desired_capacity" {
  description = "Desired number of app tier instances"
  type        = number
  default     = 2
}

variable "app_port" {
  description = "Port the application tier listens on"
  type        = number
  default     = 3000
}

variable "health_check_path" {
  description = "Path for ALB health checks"
  type        = string
  default     = "/health"
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate for HTTPS (leave empty for HTTP only)"
  type        = string
  default     = ""
}

variable "alb_logs_bucket" {
  description = "S3 bucket name for ALB access logs"
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials"
  type        = string
}

variable "s3_assets_bucket" {
  description = "Name of the S3 bucket for static assets"
  type        = string
}

variable "db_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the RDS secret in Secrets Manager"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
