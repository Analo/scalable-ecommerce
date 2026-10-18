variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "account_id" {
  description = "AWS account ID — appended to bucket names for global uniqueness"
  type        = string
}

variable "elb_account_id" {
  description = "AWS ELB service account ID for the region (required for ALB access logs)"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
