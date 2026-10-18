output "sns_alerts_topic_arn" {
  description = "ARN of the SNS topic for alerts"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_url" {
  description = "URL to the CloudWatch dashboard"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "custom_metrics_lambda_name" {
  description = "Name of the custom metrics Lambda function"
  value       = aws_lambda_function.custom_metrics.function_name
}

output "web_tier_log_group" {
  description = "CloudWatch log group for web tier"
  value       = aws_cloudwatch_log_group.web_tier.name
}

output "app_tier_log_group" {
  description = "CloudWatch log group for app tier"
  value       = aws_cloudwatch_log_group.app_tier.name
}
