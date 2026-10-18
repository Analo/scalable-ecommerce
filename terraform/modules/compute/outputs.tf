output "external_alb_dns_name" {
  description = "DNS name of the external Application Load Balancer"
  value       = aws_lb.external.dns_name
}

output "external_alb_arn" {
  description = "ARN of the external Application Load Balancer"
  value       = aws_lb.external.arn
}

output "external_alb_zone_id" {
  description = "Hosted zone ID of the external ALB (for Route 53 alias records)"
  value       = aws_lb.external.zone_id
}

output "internal_alb_dns_name" {
  description = "DNS name of the internal Application Load Balancer"
  value       = aws_lb.internal.dns_name
}

output "web_asg_name" {
  description = "Name of the web tier Auto Scaling Group"
  value       = aws_autoscaling_group.web_tier.name
}

output "app_asg_name" {
  description = "Name of the app tier Auto Scaling Group"
  value       = aws_autoscaling_group.app_tier.name
}

output "web_scale_up_policy_arn" {
  description = "ARN of the web tier scale-up policy"
  value       = aws_autoscaling_policy.web_scale_up.arn
}

output "web_scale_down_policy_arn" {
  description = "ARN of the web tier scale-down policy"
  value       = aws_autoscaling_policy.web_scale_down.arn
}

output "app_scale_up_policy_arn" {
  description = "ARN of the app tier scale-up policy"
  value       = aws_autoscaling_policy.app_scale_up.arn
}

output "app_scale_down_policy_arn" {
  description = "ARN of the app tier scale-down policy"
  value       = aws_autoscaling_policy.app_scale_down.arn
}

output "bastion_public_ip" {
  description = "Public IP address of the bastion host"
  value       = aws_eip.bastion.public_ip
}

output "bastion_instance_id" {
  description = "Instance ID of the bastion host"
  value       = aws_instance.bastion.id
}

output "ec2_instance_profile_name" {
  description = "Name of the EC2 instance profile"
  value       = aws_iam_instance_profile.ec2_profile.name
}
