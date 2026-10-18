# =============================================================================
# VPC Module — Outputs
# All downstream modules (security, compute, database) depend on these IDs.
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC — used by security module to scope NACL rules"
  value       = aws_vpc.main.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets — passed to the external ALB and bastion host"
  value       = aws_subnet.public[*].id
}

output "private_web_subnet_ids" {
  description = "IDs of the private web-tier subnets — passed to the web-tier ASG"
  value       = aws_subnet.private_web[*].id
}

output "private_app_subnet_ids" {
  description = "IDs of the private app-tier subnets — passed to the app-tier ASG"
  value       = aws_subnet.private_app[*].id
}

output "private_db_subnet_ids" {
  description = "IDs of the private database subnets — passed to the RDS subnet group"
  value       = aws_subnet.private_db[*].id
}

output "nat_gateway_ids" {
  description = "IDs of the NAT gateway(s). One gateway when single_nat_gateway = true; one per AZ otherwise."
  value       = aws_nat_gateway.main[*].id
}

output "availability_zones" {
  description = "Availability zones in use, in the order subnets were created. Index 0 = primary AZ."
  value       = data.aws_availability_zones.available.names
}
