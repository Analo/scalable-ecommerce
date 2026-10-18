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

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
  default     = ""
}

variable "external_alb_arn_suffix" {
  description = "ARN suffix of the external ALB (used in CloudWatch metric dimensions)"
  type        = string
}

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  type        = string
}

variable "web_asg_name" {
  description = "Name of the web tier Auto Scaling Group"
  type        = string
}

variable "app_asg_name" {
  description = "Name of the app tier Auto Scaling Group"
  type        = string
}

variable "web_scale_up_policy_arn" {
  description = "ARN of the web tier scale-up policy"
  type        = string
}

variable "web_scale_down_policy_arn" {
  description = "ARN of the web tier scale-down policy"
  type        = string
}

variable "app_scale_up_policy_arn" {
  description = "ARN of the app tier scale-up policy"
  type        = string
}

variable "app_scale_down_policy_arn" {
  description = "ARN of the app tier scale-down policy"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
