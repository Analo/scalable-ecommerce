output "alb_external_sg_id" {
  description = "ID of the external ALB security group"
  value       = aws_security_group.alb_external.id
}

output "alb_internal_sg_id" {
  description = "ID of the internal ALB security group"
  value       = aws_security_group.alb_internal.id
}

output "web_tier_sg_id" {
  description = "ID of the web tier security group"
  value       = aws_security_group.web_tier.id
}

output "app_tier_sg_id" {
  description = "ID of the app tier security group"
  value       = aws_security_group.app_tier.id
}

output "database_sg_id" {
  description = "ID of the database security group"
  value       = aws_security_group.database.id
}

output "bastion_sg_id" {
  description = "ID of the bastion host security group"
  value       = aws_security_group.bastion.id
}
