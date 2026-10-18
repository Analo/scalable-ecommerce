# =============================================================================
# Root Module — Input Variables
#
# All variables have sensible defaults for a dev/lab environment to minimise
# cost while still exercising the full architecture. Production-grade values
# are noted in comments where they differ.
#
# Cost-sensitive defaults to be aware of:
#   - single_nat_gateway = true  → saves ~$32/month vs one NAT per AZ
#   - enable_multi_az    = false → saves ~50% on RDS costs in dev
#   - min_size = 1 for ASGs      → avoids idle instance charges during labs
# =============================================================================

# -----------------------------------------------------------------------------
# Project identity
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Short name prefixed onto all resource names (e.g. 'scalecommerce'). Keep it lowercase and alphanumeric."
  type        = string
  default     = "scalecommerce"
}

variable "environment" {
  description = "Deployment environment. Drives cost-saving conditional logic throughout modules — 'dev' uses single NAT, no Multi-AZ RDS, min 1 instance per tier."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "aws_region" {
  description = "AWS region to deploy into. Ensure your chosen AMI ID exists in this region."
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Owner tag value — identifies who is responsible for these resources in the AWS console"
  type        = string
  default     = "Analo"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 provides 65,536 addresses — enough headroom to add subnet tiers later without re-addressing."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the public subnets (one per AZ). Hosts the external ALB, NAT gateways, and bastion host."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_web_subnet_cidrs" {
  description = "CIDRs for the private web-tier subnets (one per AZ). No direct internet access — egress via NAT gateway."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDRs for the private app-tier subnets (one per AZ). Isolated from the web tier to contain the blast radius of a web-tier compromise."
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "CIDRs for the private database subnets (one per AZ). RDS requires subnets in at least two AZs even for single-AZ instances."
  type        = list(string)
  default     = ["10.0.31.0/24", "10.0.32.0/24"]
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway shared across all private subnets. Saves ~$32/month per avoided gateway. Set to false in production for AZ-level outbound redundancy."
  type        = bool
  default     = true
}

variable "allowed_ssh_cidr_blocks" {
  description = "IP ranges permitted to SSH into the bastion host. Replace 0.0.0.0/0 with your own IP before deploying. Find your IP: curl -s ifconfig.me"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# Compute — EC2 and Auto Scaling
# -----------------------------------------------------------------------------

variable "ami_id" {
  description = "Amazon Linux 2023 AMI ID for the target region. Run: aws ec2 describe-images --owners amazon --filters 'Name=name,Values=al2023-ami-2023*-x86_64' --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text"
  type        = string
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair for SSH access. The setup.sh script creates and imports this automatically."
  type        = string
  default     = "scalecommerce-key"
}

variable "web_instance_type" {
  description = "EC2 instance type for the web tier. t3.micro is free-tier eligible. Use t3.small or larger for production load."
  type        = string
  default     = "t3.micro"
}

variable "app_instance_type" {
  description = "EC2 instance type for the app tier. Slightly larger than web tier because it handles business logic and database connections."
  type        = string
  default     = "t3.micro"
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host. t3.micro is sufficient — the bastion only handles SSH forwarding."
  type        = string
  default     = "t3.micro"
}

variable "app_port" {
  description = "TCP port the Node.js application server listens on. Must match the value in the app-tier user-data script."
  type        = number
  default     = 3000
}

variable "web_asg_min_size" {
  description = "Minimum number of web-tier instances. Set to 1 for dev to avoid idle charges; set to 2+ in production for HA."
  type        = number
  default     = 1
}

variable "web_asg_max_size" {
  description = "Maximum number of web-tier instances the ASG will scale out to during peak load."
  type        = number
  default     = 6
}

variable "web_asg_desired_capacity" {
  description = "Starting number of web-tier instances. Must be between min_size and max_size."
  type        = number
  default     = 1
}

variable "app_asg_min_size" {
  description = "Minimum number of app-tier instances. Set to 1 for dev; set to 2+ in production."
  type        = number
  default     = 1
}

variable "app_asg_max_size" {
  description = "Maximum number of app-tier instances the ASG will scale out to."
  type        = number
  default     = 4
}

variable "app_asg_desired_capacity" {
  description = "Starting number of app-tier instances."
  type        = number
  default     = 1
}

variable "health_check_path" {
  description = "HTTP path used by ALB target group health checks. The application must return HTTP 200 at this path."
  type        = string
  default     = "/health"
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS on the external ALB. Leave empty to use HTTP only (acceptable for dev/lab). Required for production."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Database — RDS MySQL
# -----------------------------------------------------------------------------

variable "db_name" {
  description = "Name of the MySQL database created on the RDS instance."
  type        = string
  default     = "scalecommerce"
}

variable "db_username" {
  description = "Master username for RDS. Avoid 'admin', 'root', or 'mysql' — these are reserved by RDS."
  type        = string
  default     = "dbadmin"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro is free-tier eligible (750 hours/month for first 12 months). Use db.t3.small or larger for production."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GB. RDS will autoscale up to db_max_allocated_storage as data grows."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper limit for RDS storage autoscaling in GB. Autoscaling kicks in when free space falls below 10% of allocated storage."
  type        = number
  default     = 100
}

variable "enable_multi_az" {
  description = "Enable RDS Multi-AZ standby. Provides automatic failover but roughly doubles the cost. Disable for dev/lab environments."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Number of days to retain automated RDS backups. Minimum 1 to keep point-in-time recovery available. Set to 7 in production."
  type        = number
  default     = 1
}

variable "backup_window" {
  description = "Daily window for automated backups in UTC (e.g. '02:00-03:00'). Must not overlap with maintenance_window."
  type        = string
  default     = "02:00-03:00"
}

variable "maintenance_window" {
  description = "Weekly window for RDS maintenance (minor version upgrades, patching) in UTC."
  type        = string
  default     = "sun:04:00-sun:05:00"
}

# -----------------------------------------------------------------------------
# Storage and CDN
# -----------------------------------------------------------------------------

variable "account_id" {
  description = "AWS account ID — appended to S3 bucket names to guarantee global uniqueness."
  type        = string
}

variable "elb_account_id" {
  description = "AWS ELB service account ID for the target region. Required for ALB access log delivery to S3. Find yours at: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html"
  type        = string
}

variable "cloudfront_price_class" {
  description = "CloudFront price class controlling which edge locations serve content. PriceClass_100 (US, Europe, Israel) is the cheapest option and covers most portfolio viewers."
  type        = string
  default     = "PriceClass_100"
}

# -----------------------------------------------------------------------------
# Monitoring and alerting
# -----------------------------------------------------------------------------

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications via SNS. Leave empty to skip email subscription."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch log streams. 14 days is sufficient for dev; use 30–90 days in production."
  type        = number
  default     = 14
}
