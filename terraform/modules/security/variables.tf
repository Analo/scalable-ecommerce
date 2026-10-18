# =============================================================================
# Security Module — Input Variables
# =============================================================================

variable "project_name" {
  description = "Short name used as a prefix for all security group and NACL names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC in which to create security groups and NACLs"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC — used to scope NACL rules to internal traffic only"
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs of the public subnets — assigned to the public NACL"
  type        = list(string)
}

variable "private_web_subnet_ids" {
  description = "IDs of the private web-tier subnets — assigned to the web NACL"
  type        = list(string)
}

variable "private_app_subnet_ids" {
  description = "IDs of the private app-tier subnets — assigned to the app NACL"
  type        = list(string)
}

variable "private_db_subnet_ids" {
  description = "IDs of the private database subnets — assigned to the DB NACL"
  type        = list(string)
}

variable "allowed_ssh_cidr_blocks" {
  description = "CIDR blocks permitted to SSH into the bastion host. For security, restrict this to your known IP(s) rather than leaving it open to 0.0.0.0/0."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "app_port" {
  description = "TCP port the application tier Node.js server listens on. Must match the port configured in the app-tier user-data script."
  type        = number
  default     = 3000
}

variable "tags" {
  description = "Additional tags merged onto every security group and NACL"
  type        = map(string)
  default     = {}
}
