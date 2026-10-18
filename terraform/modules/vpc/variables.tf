# =============================================================================
# VPC Module — Input Variables
# =============================================================================

variable "project_name" {
  description = "Short name used as a prefix for all resources (e.g. 'scalecommerce')"
  type        = string
}

variable "environment" {
  description = "Deployment environment. Controls cost-saving defaults — 'dev' uses single NAT gateway and minimal redundancy; 'prod' uses per-AZ NAT gateways and Multi-AZ RDS."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 gives 65,536 addresses, enough headroom to add subnet tiers later without re-addressing."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets — one per AZ. These host the external ALB, NAT gateways, and bastion. Must be /24 (256 addresses each)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_web_subnet_cidrs" {
  description = "CIDR blocks for private web-tier subnets — one per AZ. These host the web-tier EC2 Auto Scaling Group. No direct internet access; egress via NAT gateway."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private app-tier subnets — one per AZ. These host the application-tier EC2 Auto Scaling Group. Separated from the web tier to limit blast radius if a web instance is compromised."
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "CIDR blocks for private database subnets — one per AZ. RDS requires subnets in at least two AZs even for single-AZ deployments; the second subnet is used for the Multi-AZ standby in production."
  type        = list(string)
  default     = ["10.0.31.0/24", "10.0.32.0/24"]
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway shared across all private subnets. Recommended for dev/lab environments — saves ~$32/month per avoided NAT gateway. Set to false in production for AZ-level fault isolation."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to merge onto all resources. The module always applies Project, Environment, and ManagedBy tags; use this map for any project-specific extras."
  type        = map(string)
  default     = {}
}
