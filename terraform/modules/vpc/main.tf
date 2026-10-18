# =============================================================================
# VPC Module
#
# Provisions the full network foundation for the ScaleCommerce platform:
#   - VPC with DNS resolution enabled (required for RDS endpoint resolution)
#   - Four subnet tiers across two AZs: public, web, app, database
#   - Internet Gateway for public-facing traffic
#   - NAT Gateway(s) so private instances can reach the internet for updates
#     and AWS API calls without exposing a public IP
#   - Route tables wiring each tier to the correct gateway
#
# Cost note: NAT Gateways are billed per hour (~$0.045/hr each) plus data
# transfer. For dev/lab, set single_nat_gateway = true to run one shared
# gateway instead of one per AZ. In production, per-AZ gateways ensure
# outbound internet access survives an AZ failure.
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })

  # When single_nat_gateway is true, all private route tables use index 0.
  # When false, each AZ gets its own NAT gateway for redundancy.
  nat_gateway_count = var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)
}

# -----------------------------------------------------------------------------
# Availability Zones
# Only include AZs that are fully available and opt-in is not required —
# this filters out Local Zones and Wavelength Zones that can't host standard
# EC2 or RDS instances.
# -----------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# -----------------------------------------------------------------------------
# VPC
# DNS hostnames must be enabled so RDS instances get resolvable hostnames.
# DNS support is required for Route 53 private hosted zones if added later.
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# -----------------------------------------------------------------------------
# Internet Gateway
# Attaches to the VPC and provides the default route for the public subnets.
# Private subnets route outbound traffic through NAT gateways instead.
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# =============================================================================
# Subnets
# Four tiers, each spanning two AZs for redundancy. Keeping tiers in separate
# CIDR ranges makes firewall rules and NACLs easy to reason about — a rule
# matching 10.0.3x.0/24 always means "database tier" regardless of which AZ.
# =============================================================================

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-subnet-${count.index + 1}"
    Type = "Public"
    AZ   = data.aws_availability_zones.available.names[count.index]
  })
}

resource "aws_subnet" "private_web" {
  count = length(var.private_web_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_web_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-web-subnet-${count.index + 1}"
    Type = "Private"
    Tier = "Web"
    AZ   = data.aws_availability_zones.available.names[count.index]
  })
}

resource "aws_subnet" "private_app" {
  count = length(var.private_app_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-subnet-${count.index + 1}"
    Type = "Private"
    Tier = "Application"
    AZ   = data.aws_availability_zones.available.names[count.index]
  })
}

resource "aws_subnet" "private_db" {
  count = length(var.private_db_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-db-subnet-${count.index + 1}"
    Type = "Private"
    Tier = "Database"
    AZ   = data.aws_availability_zones.available.names[count.index]
  })
}

# =============================================================================
# NAT Gateways
#
# NAT gateways sit in the public subnet and translate outbound traffic from
# private instances. Each requires an Elastic IP.
#
# Count is controlled by var.single_nat_gateway:
#   true  → 1 gateway shared by all private subnets (dev/lab cost saving)
#   false → 1 gateway per AZ (production — survives an AZ failure)
# =============================================================================

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  # The IGW must exist before an EIP can be associated with a NAT gateway.
  depends_on = [aws_internet_gateway.main]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  })
}

resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  depends_on = [aws_internet_gateway.main]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  })
}

# =============================================================================
# Route Tables
#
# One shared table for all public subnets (they all route via the same IGW).
# Separate tables per private subnet so each can be pointed at the correct
# NAT gateway — either the single shared one (dev) or the per-AZ one (prod).
#
# Database subnets intentionally have no outbound route to the internet.
# RDS instances should never initiate outbound internet connections; all
# patching is handled by the managed service. Removing the route is a
# defence-in-depth measure — even if a rule were misconfigured to allow
# outbound DB traffic, the route doesn't exist to carry it.
# =============================================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private web-tier route tables — one per subnet, pointing at the appropriate
# NAT gateway. When single_nat_gateway is true, index 0 is always used.
resource "aws_route_table" "private_web" {
  count  = length(aws_subnet.private_web)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-web-rt-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private_web" {
  count          = length(aws_subnet.private_web)
  subnet_id      = aws_subnet.private_web[count.index].id
  route_table_id = aws_route_table.private_web[count.index].id
}

resource "aws_route_table" "private_app" {
  count  = length(aws_subnet.private_app)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-app-rt-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private_app" {
  count          = length(aws_subnet.private_app)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# Database subnets — local VPC traffic only, no outbound internet route.
resource "aws_route_table" "private_db" {
  count  = length(aws_subnet.private_db)
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-db-rt-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private_db" {
  count          = length(aws_subnet.private_db)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db[count.index].id
}
