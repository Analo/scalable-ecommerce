# terraform/backend/main.tf
# Creates the S3 bucket and DynamoDB table used to store Terraform remote state.
# Run this ONCE before the first deploy via scripts/setup.sh.

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ScaleCommerce"
      ManagedBy = "Terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# S3 bucket for Terraform state
# Versioning is required — it lets you recover from accidental state corruption.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  bucket = var.bucket_name

  # Prevent accidental deletion when the bucket contains active state files.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# DynamoDB table for state locking
# Prevents two concurrent applies from corrupting each other's state.
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "terraform_state_lock" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to create the backend resources in"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Name for the S3 state bucket. setup.sh sets this to <account_id>-scalecommerce-tfstate for global uniqueness."
  type        = string
}

variable "dynamodb_table_name" {
  description = "Name for the DynamoDB lock table"
  type        = string
  default     = "scalecommerce-tfstate-lock"
}

# -----------------------------------------------------------------------------
# Outputs — printed by setup.sh to confirm the backend is ready
# -----------------------------------------------------------------------------

output "s3_bucket_name" {
  description = "S3 bucket name — pass to terraform init -backend-config"
  value       = aws_s3_bucket.terraform_state.id
}

output "dynamodb_table_name" {
  description = "DynamoDB table name — pass to terraform init -backend-config"
  value       = aws_dynamodb_table.terraform_state_lock.name
}
