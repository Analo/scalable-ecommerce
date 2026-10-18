# =============================================================================
# Security Module
#
# Defines the complete security boundary for the ScaleCommerce platform using
# two complementary controls:
#
#   Security Groups — stateful, applied at the instance/ENI level. They track
#   connection state so return traffic is automatically allowed. Each tier only
#   accepts traffic from the tier immediately above it.
#
#   NACLs — stateless, applied at the subnet level. Because they are stateless,
#   both inbound and outbound rules must be explicitly defined, including the
#   ephemeral port range (1024–65535) for return traffic. NACLs are the last
#   line of defence if a security group rule is accidentally broadened.
#
# Traffic flow enforced by security groups:
#   Internet → External ALB (80/443)
#   External ALB → Web tier (80/443)
#   Web tier → Internal ALB (app port)
#   Internal ALB → App tier (app port)
#   App tier → RDS (3306)
#   Bastion → Web tier, App tier, RDS (SSH + MySQL)
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })
}

# =============================================================================
# Security Groups
# =============================================================================

# -----------------------------------------------------------------------------
# External ALB — internet-facing
# Accepts HTTP and HTTPS from anywhere. The ALB handles TLS termination so
# the web instances only need to process unencrypted HTTP internally.
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb_external" {
  name        = "${local.name_prefix}-alb-external-sg"
  description = "External ALB: accepts HTTP/HTTPS from the public internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP — redirected to HTTPS by the ALB listener rule"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS — primary listener; terminates TLS at the ALB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound so the ALB can forward to web tier and reach health check targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-external-sg"
    Tier = "public"
  })
}

# -----------------------------------------------------------------------------
# Web Tier — EC2 instances in the private web subnets
# Only accepts traffic from the external ALB; SSH is limited to the bastion.
# -----------------------------------------------------------------------------
resource "aws_security_group" "web_tier" {
  name        = "${local.name_prefix}-web-tier-sg"
  description = "Web tier EC2: accepts HTTP/HTTPS from external ALB, SSH from bastion only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from external ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_external.id]
  }

  ingress {
    description     = "HTTPS from external ALB"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_external.id]
  }

  ingress {
    description     = "SSH from bastion — admin access only, not for routine deployments"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    description = "Allow all outbound: app tier, NAT gateway for AWS API calls, package updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-web-tier-sg"
    Tier = "web"
  })
}

# -----------------------------------------------------------------------------
# Internal ALB — routes traffic between the web and app tiers
# Placed in the private web subnets; only the web tier can send requests to it.
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb_internal" {
  name        = "${local.name_prefix}-alb-internal-sg"
  description = "Internal ALB: accepts traffic from web tier EC2 instances only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "App-tier traffic forwarded from web instances"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.web_tier.id]
  }

  egress {
    description = "Forward requests to app tier instances"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-internal-sg"
    Tier = "internal"
  })
}

# -----------------------------------------------------------------------------
# App Tier — EC2 instances running the Node.js API in private app subnets
# -----------------------------------------------------------------------------
resource "aws_security_group" "app_tier" {
  name        = "${local.name_prefix}-app-tier-sg"
  description = "App tier EC2: accepts API traffic from internal ALB, SSH from bastion"
  vpc_id      = var.vpc_id

  ingress {
    description     = "API requests from internal ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_internal.id]
  }

  ingress {
    description     = "SSH from bastion — for debugging only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    description = "Allow all outbound: RDS on 3306, Secrets Manager, CloudWatch, package updates via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-app-tier-sg"
    Tier = "app"
  })
}

# -----------------------------------------------------------------------------
# Database — RDS MySQL in private DB subnets
# MySQL port 3306 is only reachable from the app tier and the bastion.
# The bastion access supports database admin tasks and schema migrations.
# -----------------------------------------------------------------------------
resource "aws_security_group" "database" {
  name        = "${local.name_prefix}-database-sg"
  description = "RDS MySQL: accepts connections from app tier and bastion only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from app tier — primary application access path"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_tier.id]
  }

  ingress {
    description     = "MySQL from bastion — DBA access for migrations and maintenance"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    description = "Outbound for RDS to reach AWS services (e.g. KMS for encryption)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-database-sg"
    Tier = "database"
  })
}

# -----------------------------------------------------------------------------
# Bastion Host — jump server in the public subnet
# SSH access is restricted to a defined list of CIDR blocks (set in tfvars).
# In practice this should be your office or home IP, not 0.0.0.0/0.
# -----------------------------------------------------------------------------
resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-bastion-sg"
  description = "Bastion host: SSH access restricted to known IP ranges defined in tfvars"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from approved source IPs — restrict to known IPs in terraform.tfvars"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidr_blocks
  }

  egress {
    description = "Allow all outbound so the bastion can reach web, app, and DB tiers"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-bastion-sg"
    Tier = "management"
  })
}

# =============================================================================
# Network ACLs
#
# NACLs provide subnet-level traffic filtering on top of security groups.
# Because they are stateless, the ephemeral port range (1024–65535) must be
# explicitly allowed in both directions for TCP connections to complete.
#
# Rule numbering: 100-series for allow, 900-series reserved for explicit deny.
# The implicit default deny handles everything not matched.
# =============================================================================

resource "aws_network_acl" "public" {
  vpc_id     = var.vpc_id
  subnet_ids = var.public_subnet_ids

  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Return traffic from internet-initiated connections (ephemeral ports)
  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # SSH inbound only from within the VPC — the bastion is the internet entry point
  ingress {
    rule_no    = 130
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 22
    to_port    = 22
  }

  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Return traffic for inbound requests (ephemeral ports)
  egress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-nacl"
  })
}

resource "aws_network_acl" "private_web" {
  vpc_id     = var.vpc_id
  subnet_ids = var.private_web_subnet_ids

  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  ingress {
    rule_no    = 130
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 22
    to_port    = 22
  }

  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 65535
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-web-nacl"
  })
}

resource "aws_network_acl" "private_app" {
  vpc_id     = var.vpc_id
  subnet_ids = var.private_app_subnet_ids

  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = var.app_port
    to_port    = var.app_port
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 22
    to_port    = 22
  }

  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 65535
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-nacl"
  })
}

# DB subnets: inbound MySQL from within VPC only; no outbound internet route exists
# at the route table level, but the NACL reinforces that intent explicitly.
resource "aws_network_acl" "private_db" {
  vpc_id     = var.vpc_id
  subnet_ids = var.private_db_subnet_ids

  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 3306
    to_port    = 3306
  }

  # Return traffic from RDS responses back to app tier (ephemeral ports)
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 65535
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-db-nacl"
  })
}
