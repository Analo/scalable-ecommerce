locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ============================================================
# KMS Key for RDS encryption
# ============================================================
resource "aws_kms_key" "rds" {
  description             = "KMS key for ${local.name_prefix} RDS encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rds-kms"
  })
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${local.name_prefix}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# ============================================================
# DB Subnet Group
# ============================================================
resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-db-subnet-group"
  description = "Subnet group for ${local.name_prefix} RDS instance"
  subnet_ids  = var.private_db_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-db-subnet-group"
  })
}

# ============================================================
# DB Parameter Group — MySQL 8.0 tuning
# ============================================================
resource "aws_db_parameter_group" "mysql8" {
  name        = "${local.name_prefix}-mysql8-params"
  family      = "mysql8.0"
  description = "Custom parameters for ${local.name_prefix} MySQL 8.0"

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  parameter {
    name  = "innodb_buffer_pool_size"
    value = "{DBInstanceClassMemory*3/4}"
  }

  parameter {
    name  = "max_connections"
    value = "500"
  }

  tags = var.tags
}

# ============================================================
# Secrets Manager — DB Credentials
# ============================================================
resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${local.name_prefix}/rds/credentials"
  description = "RDS credentials for ${local.name_prefix}"
  kms_key_id  = aws_kms_key.rds.key_id
  # 0 = force-delete immediately on destroy (no recovery window) — required for
  # destroy-redeploy cycles in dev because AWS blocks recreation during the window.
  recovery_window_in_days = var.environment == "prod" ? 30 : 0

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-db-credentials"
  })
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
    engine   = "mysql"
  })

  depends_on = [aws_db_instance.main]
}

# ============================================================
# RDS MySQL Multi-AZ Instance
# ============================================================
resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  multi_az               = var.environment == "prod"
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.database_sg_id]
  parameter_group_name   = aws_db_parameter_group.mysql8.name

  backup_retention_period    = var.environment == "prod" ? 7 : 1
  backup_window              = "02:00-03:00"
  maintenance_window         = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade = true

  deletion_protection       = var.environment == "prod"
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${local.name_prefix}-final-snapshot" : null

  # Performance Insights requires db.t3.small or larger — disabled for dev (t3.micro)
  performance_insights_enabled          = var.environment == "prod"
  performance_insights_kms_key_id       = var.environment == "prod" ? aws_kms_key.rds.arn : null
  performance_insights_retention_period = var.environment == "prod" ? 7 : 0

  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  copy_tags_to_snapshot = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-mysql"
  })
}

# ============================================================
# IAM Role for RDS Enhanced Monitoring
# ============================================================
resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ============================================================
# Read Replica (prod only)
# ============================================================
resource "aws_db_instance" "replica" {
  count = var.environment == "prod" ? 1 : 0

  identifier             = "${local.name_prefix}-mysql-replica"
  replicate_source_db    = aws_db_instance.main.identifier
  instance_class         = var.db_instance_class
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.rds.arn
  vpc_security_group_ids = [var.database_sg_id]

  skip_final_snapshot        = true
  auto_minor_version_upgrade = true

  performance_insights_enabled = var.environment == "prod"
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-mysql-replica"
  })
}
