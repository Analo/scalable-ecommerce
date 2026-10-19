# terraform/main.tf — Root module: wires all infrastructure modules together

locals {
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# VPC — network foundation
# Creates the VPC, all subnet tiers, IGW, NAT gateways, and route tables.
# =============================================================================
module "vpc" {
  source = "./modules/vpc"

  project_name             = var.project_name
  environment              = var.environment
  vpc_cidr                 = var.vpc_cidr
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_web_subnet_cidrs = var.private_web_subnet_cidrs
  private_app_subnet_cidrs = var.private_app_subnet_cidrs
  private_db_subnet_cidrs  = var.private_db_subnet_cidrs
  single_nat_gateway       = var.single_nat_gateway
  tags                     = local.tags
}

# =============================================================================
# Security — all security groups and NACLs
# Must come before compute and database so the group IDs exist when referenced.
# =============================================================================
module "security" {
  source = "./modules/security"

  project_name            = var.project_name
  environment             = var.environment
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = module.vpc.vpc_cidr
  public_subnet_ids       = module.vpc.public_subnet_ids
  private_web_subnet_ids  = module.vpc.private_web_subnet_ids
  private_app_subnet_ids  = module.vpc.private_app_subnet_ids
  private_db_subnet_ids   = module.vpc.private_db_subnet_ids
  allowed_ssh_cidr_blocks = var.allowed_ssh_cidr_blocks
  app_port                = var.app_port
  tags                    = local.tags
}

# =============================================================================
# Storage — S3 buckets and CloudFront distribution
# Created before compute so the ALB logs bucket exists when the ALB is created.
# =============================================================================
module "storage" {
  source = "./modules/storage"

  project_name   = var.project_name
  environment    = var.environment
  account_id     = var.account_id
  elb_account_id = var.elb_account_id
  tags           = local.tags
}

# =============================================================================
# Database — RDS MySQL with KMS encryption and Secrets Manager credentials
# Depends on VPC and security so subnet group and security group are ready.
# =============================================================================
module "database" {
  source = "./modules/database"

  project_name             = var.project_name
  environment              = var.environment
  private_db_subnet_ids    = module.vpc.private_db_subnet_ids
  database_sg_id           = module.security.database_sg_id
  db_name                  = var.db_name
  db_username              = var.db_username
  db_instance_class        = var.db_instance_class
  db_allocated_storage     = var.db_allocated_storage
  db_max_allocated_storage = var.db_max_allocated_storage
  tags                     = local.tags

  depends_on = [module.vpc, module.security]
}

# =============================================================================
# Compute — ALBs, launch templates, Auto Scaling Groups, and bastion host
# Depends on all other modules: needs security groups, the DB secret ARN,
# and the ALB logs bucket before it can create load balancers and instances.
# =============================================================================
module "compute" {
  source = "./modules/compute"

  project_name           = var.project_name
  environment            = var.environment
  aws_region             = var.aws_region
  vpc_id                 = module.vpc.vpc_id
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_web_subnet_ids = module.vpc.private_web_subnet_ids
  private_app_subnet_ids = module.vpc.private_app_subnet_ids
  alb_external_sg_id     = module.security.alb_external_sg_id
  alb_internal_sg_id     = module.security.alb_internal_sg_id
  web_tier_sg_id         = module.security.web_tier_sg_id
  app_tier_sg_id         = module.security.app_tier_sg_id
  bastion_sg_id          = module.security.bastion_sg_id
  ami_id                 = var.ami_id
  key_pair_name          = var.key_pair_name
  web_instance_type      = var.web_instance_type
  app_instance_type      = var.app_instance_type
  bastion_instance_type  = var.bastion_instance_type
  web_min_size           = var.web_asg_min_size
  web_max_size           = var.web_asg_max_size
  web_desired_capacity   = var.web_asg_desired_capacity
  app_min_size           = var.app_asg_min_size
  app_max_size           = var.app_asg_max_size
  app_desired_capacity   = var.app_asg_desired_capacity
  app_port               = var.app_port
  health_check_path      = var.health_check_path
  certificate_arn        = var.certificate_arn
  alb_logs_bucket        = module.storage.alb_logs_bucket_name
  db_secret_arn          = module.database.db_secret_arn
  db_kms_key_arn         = module.database.db_kms_key_arn
  s3_assets_bucket       = module.storage.assets_bucket_name
  tags                   = local.tags

  depends_on = [module.vpc, module.security, module.storage, module.database]
}

# =============================================================================
# Monitoring — CloudWatch alarms, dashboard, SNS, and Lambda custom metrics
# Depends on compute so ALB and ASG names are available for alarm dimensions.
# =============================================================================
module "monitoring" {
  source = "./modules/monitoring"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  alert_email  = var.alert_email

  # CloudWatch ALB metrics use the ARN suffix (the portion after "loadbalancer/")
  # e.g. "app/scalecommerce-dev-external-alb/abc123" from the full ARN.
  external_alb_arn_suffix    = split(":loadbalancer/", module.compute.external_alb_arn)[1]
  cloudfront_distribution_id = module.storage.cloudfront_distribution_id

  web_asg_name              = module.compute.web_asg_name
  app_asg_name              = module.compute.app_asg_name
  web_scale_up_policy_arn   = module.compute.web_scale_up_policy_arn
  web_scale_down_policy_arn = module.compute.web_scale_down_policy_arn
  app_scale_up_policy_arn   = module.compute.app_scale_up_policy_arn
  app_scale_down_policy_arn = module.compute.app_scale_down_policy_arn
  tags                      = local.tags

  depends_on = [module.compute, module.database]
}

# =============================================================================
# Outputs — key values printed after apply
# =============================================================================

output "application_url" {
  description = "External ALB endpoint — the entry point for all HTTP traffic"
  value       = "http://${module.compute.external_alb_dns_name}"
}

output "cloudfront_domain" {
  description = "CloudFront domain for static asset delivery"
  value       = module.storage.cloudfront_domain_name
}

output "bastion_ssh_command" {
  description = "SSH command to connect to the bastion host"
  value       = "ssh -i ~/.ssh/${var.key_pair_name} ec2-user@${module.compute.bastion_public_ip}"
}

output "database_endpoint" {
  description = "RDS endpoint (app tier only — no public route exists)"
  value       = module.database.db_endpoint
  sensitive   = true
}

output "monitoring_dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = module.monitoring.dashboard_url
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "assets_bucket" {
  description = "S3 bucket name for static assets"
  value       = module.storage.assets_bucket_name
}
