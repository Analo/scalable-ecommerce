# terraform/main.tf — Root module wiring all modules together

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws     = { source = "hashicorp/aws";   version = "~> 5.0" }
    random  = { source = "hashicorp/random"; version = "~> 3.1" }
    archive = { source = "hashicorp/archive"; version = "~> 2.2" }
  }
  backend "s3" {
    bucket         = "scalecommerce-terraform-state-12345678"  # Replace with actual bucket
    key            = "scalecommerce/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "scalecommerce-terraform-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = var.project_name, Environment = var.environment, ManagedBy = "Terraform", Owner = var.owner }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "vpc" {
  source                   = "./modules/vpc"
  project_name             = var.project_name
  environment              = var.environment
  vpc_cidr                 = var.vpc_cidr
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_web_subnet_cidrs = var.private_web_subnet_cidrs
  private_app_subnet_cidrs = var.private_app_subnet_cidrs
  private_db_subnet_cidrs  = var.private_db_subnet_cidrs
}

module "security" {
  source                = "./modules/security"
  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  vpc_cidr              = module.vpc.vpc_cidr
  private_db_subnet_ids = module.vpc.private_db_subnet_ids
  admin_cidr_blocks     = var.admin_cidr_blocks
  app_port              = var.app_port
}

module "storage" {
  source                 = "./modules/storage"
  project_name           = var.project_name
  environment            = var.environment
  enable_cloudfront      = var.enable_cloudfront
  cloudfront_price_class = var.cloudfront_price_class
  upload_sample_content  = var.upload_sample_content
}

module "database" {
  source                     = "./modules/database"
  project_name               = var.project_name
  environment                = var.environment
  private_db_subnet_ids      = module.vpc.private_db_subnet_ids
  database_security_group_id = module.security.database_security_group_id
  db_engine                  = var.db_engine
  db_engine_version          = var.db_engine_version
  db_instance_class          = var.db_instance_class
  db_allocated_storage       = var.db_allocated_storage
  db_max_allocated_storage   = var.db_max_allocated_storage
  db_name                    = var.db_name
  db_username                = var.db_username
  db_password                = var.db_password
  enable_multi_az            = var.enable_multi_az
  backup_retention_period    = var.backup_retention_period
  backup_window              = var.backup_window
  maintenance_window         = var.maintenance_window
  create_read_replica        = var.create_read_replica
  read_replica_instance_class = var.read_replica_instance_class
  deletion_protection        = var.deletion_protection
  depends_on                 = [module.vpc, module.security]
}

module "compute" {
  source                     = "./modules/compute"
  project_name               = var.project_name
  environment                = var.environment
  vpc_id                     = module.vpc.vpc_id
  public_subnet_ids          = module.vpc.public_subnet_ids
  private_web_subnet_ids     = module.vpc.private_web_subnet_ids
  private_app_subnet_ids     = module.vpc.private_app_subnet_ids
  alb_security_group_id      = module.security.alb_security_group_id
  web_tier_security_group_id = module.security.web_tier_security_group_id
  app_tier_security_group_id = module.security.app_tier_security_group_id
  bastion_security_group_id  = module.security.bastion_security_group_id
  s3_bucket_arn              = module.storage.static_content_bucket_arn
  s3_bucket_name             = module.storage.static_content_bucket_name
  db_endpoint                = module.database.db_instance_endpoint
  db_name                    = module.database.db_name
  db_username                = module.database.db_username
  db_password                = module.database.db_password
  public_key                 = var.public_key
  web_instance_type          = var.web_instance_type
  app_instance_type          = var.app_instance_type
  bastion_instance_type      = var.bastion_instance_type
  app_port                   = var.app_port
  web_asg_min_size           = var.web_asg_min_size
  web_asg_max_size           = var.web_asg_max_size
  web_asg_desired_capacity   = var.web_asg_desired_capacity
  app_asg_min_size           = var.app_asg_min_size
  app_asg_max_size           = var.app_asg_max_size
  app_asg_desired_capacity   = var.app_asg_desired_capacity
  depends_on                 = [module.vpc, module.security, module.storage, module.database]
}

module "monitoring" {
  source                    = "./modules/monitoring"
  project_name              = var.project_name
  environment               = var.environment
  web_asg_name              = module.compute.web_asg_name
  app_asg_name              = module.compute.app_asg_name
  db_instance_id            = module.database.db_instance_id
  web_alb_arn_suffix        = split("/", module.compute.web_alb_arn)[1]
  web_scale_up_policy_arn   = module.compute.web_scale_up_policy_arn
  web_scale_down_policy_arn = module.compute.web_scale_down_policy_arn
  app_scale_up_policy_arn   = module.compute.app_scale_up_policy_arn
  app_scale_down_policy_arn = module.compute.app_scale_down_policy_arn
  alert_email_addresses     = var.alert_email_addresses
  enable_custom_metrics     = var.enable_custom_metrics
  depends_on                = [module.compute, module.database]
}

output "application_url"              { value = var.domain_name != "" ? "https://${var.domain_name}" : "http://${module.compute.web_alb_dns_name}" }
output "bastion_ssh_command"          { value = "ssh -i ${var.key_pair_name}.pem ec2-user@${module.compute.bastion_public_ip}" }
output "database_endpoint"            { value = module.database.db_instance_endpoint; sensitive = true }
output "cloudfront_distribution_domain" { value = module.storage.cloudfront_domain_name }
output "monitoring_dashboard_url"     { value = module.monitoring.dashboard_url }
output "s3_static_content_bucket"     { value = module.storage.static_content_bucket_name }
output "vpc_id"                        { value = module.vpc.vpc_id }
